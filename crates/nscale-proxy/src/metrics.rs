use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use nscale_core::job::{JobId, ServiceName};

/// Hard age bound for retained samples. Kept in lockstep with the maximum
/// allowed autoscale decision window so a long-window job's p95/counts are never
/// silently computed over a truncated buffer.
const MAX_SAMPLE_AGE: Duration = Duration::from_secs(nscale_core::job::MAX_DECISION_WINDOW_SECS);
/// Hard per-job sample cap. Bounds memory under extreme request rates (p95 over
/// a large recent sample is still statistically valid).
// ponytail: fixed count cap; make it window/rate-derived only if p95 accuracy at
// very high RPS ever matters.
const MAX_SAMPLES_PER_JOB: usize = 100_000;
/// Minimum spacing between whole-map key-reclamation sweeps so `snapshot()`
/// (called per autoscaled job each tick) doesn't rescan the map under lock N times.
const SWEEP_MIN_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProxyMetricSnapshot {
    pub p95_latency_ms: Option<f64>,
    pub request_count: u64,
    pub error_count: u64,
}

#[derive(Clone, Default)]
pub struct ProxyMetrics {
    // ponytail: one global lock guarding all jobs; shard by job_id only if this
    // becomes a measured contention point.
    requests: Arc<Mutex<HashMap<String, VecDeque<RequestSample>>>>,
    last_sweep: Arc<Mutex<Option<Instant>>>,
}

#[derive(Debug, Clone)]
struct RequestSample {
    status: u16,
    duration: Duration,
    observed_at: Instant,
}

impl ProxyMetrics {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<String, VecDeque<RequestSample>>> {
        // Recover from a poisoned lock instead of cascading panics: a panic in
        // one request thread must not take down all metric recording.
        self.requests.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    fn tracked_jobs(&self) -> usize {
        self.lock().len()
    }

    /// Whether a whole-map key-reclamation sweep is due, recording `now` as the
    /// last sweep time when it returns true.
    fn sweep_due(&self, now: Instant) -> bool {
        let mut last = self.last_sweep.lock().unwrap_or_else(|e| e.into_inner());
        let due = last.is_none_or(|previous| now.duration_since(previous) >= SWEEP_MIN_INTERVAL);
        if due {
            *last = Some(now);
        }
        due
    }

    pub fn record_request(
        &self,
        job_id: &JobId,
        service_name: &ServiceName,
        status: u16,
        duration: Duration,
    ) {
        self.record_request_at(job_id, service_name, status, duration, Instant::now());
    }

    pub fn record_wake(
        &self,
        job_id: &JobId,
        service_name: &ServiceName,
        outcome: &str,
        duration: Duration,
    ) {
        metrics::histogram!(
            "nscale_wake_duration_seconds",
            "job_id" => job_id.0.clone(),
            "service_name" => service_name.0.clone(),
            "outcome" => outcome.to_string(),
        )
        .record(duration.as_secs_f64());
    }

    pub(crate) fn record_request_at(
        &self,
        job_id: &JobId,
        service_name: &ServiceName,
        status: u16,
        duration: Duration,
        observed_at: Instant,
    ) {
        let status_class = status_class(status);
        metrics::counter!(
            "nscale_proxy_requests_total",
            "job_id" => job_id.0.clone(),
            "service_name" => service_name.0.clone(),
            "status_class" => status_class,
        )
        .increment(1);
        metrics::histogram!(
            "nscale_proxy_request_duration_seconds",
            "job_id" => job_id.0.clone(),
            "service_name" => service_name.0.clone(),
        )
        .record(duration.as_secs_f64());

        let mut requests = self.lock();
        let samples = requests.entry(job_id.0.clone()).or_default();
        samples.push_back(RequestSample {
            status,
            duration,
            observed_at,
        });
        prune_samples(samples, observed_at);
    }

    pub fn snapshot(&self, job_id: &JobId, window: Duration) -> ProxyMetricSnapshot {
        let now = Instant::now();
        // On underflow (window reaches before process start) keep every sample,
        // matching how pruning treats the same case.
        let window_start = now.checked_sub(window);
        let in_window =
            |sample: &RequestSample| window_start.is_none_or(|start| sample.observed_at >= start);
        let do_sweep = self.sweep_due(now);
        let mut requests = self.lock();

        // Sweep the whole map: drop samples older than the hard retention and
        // evict now-empty job entries. This bounds the key set even for jobs
        // that stopped being autoscaled or were deregistered.
        if do_sweep {
            let age_cutoff = now.checked_sub(MAX_SAMPLE_AGE);
            requests.retain(|_, samples| {
                if let Some(age_cutoff) = age_cutoff {
                    while samples.front().is_some_and(|s| s.observed_at < age_cutoff) {
                        samples.pop_front();
                    }
                }
                !samples.is_empty()
            });
        }

        let Some(samples) = requests.get(&job_id.0) else {
            return ProxyMetricSnapshot::default();
        };

        let mut durations_ms: Vec<f64> = samples
            .iter()
            .filter(|sample| in_window(sample))
            .map(|sample| sample.duration.as_secs_f64() * 1000.0)
            .collect();
        durations_ms.sort_by(f64::total_cmp);

        let request_count = durations_ms.len() as u64;
        let error_count = samples
            .iter()
            .filter(|sample| in_window(sample) && sample.status >= 500)
            .count() as u64;

        let p95_latency_ms = if durations_ms.is_empty() {
            None
        } else {
            let index = ((durations_ms.len() as f64 * 0.95).ceil() as usize).saturating_sub(1);
            durations_ms.get(index).copied()
        };

        ProxyMetricSnapshot {
            p95_latency_ms,
            request_count,
            error_count,
        }
    }
}

/// Bound a per-job sample buffer by count and age. Samples are appended in
/// (approximately) increasing `observed_at` order, so the oldest sit at the
/// front and can be dropped cheaply.
fn prune_samples(samples: &mut VecDeque<RequestSample>, now: Instant) {
    while samples.len() > MAX_SAMPLES_PER_JOB {
        samples.pop_front();
    }
    if let Some(cutoff) = now.checked_sub(MAX_SAMPLE_AGE) {
        while samples
            .front()
            .is_some_and(|sample| sample.observed_at < cutoff)
        {
            samples.pop_front();
        }
    }
}

fn status_class(status: u16) -> String {
    format!("{}xx", status / 100)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::{JobId, ServiceName};
    use std::time::Duration;

    #[test]
    fn snapshot_reports_p95_latency_for_recent_requests() {
        let metrics = ProxyMetrics::new();
        let job_id = JobId("api".into());
        let service_name = ServiceName("api".into());

        for millis in [100, 200, 300, 400, 500] {
            metrics.record_request(&job_id, &service_name, 200, Duration::from_millis(millis));
        }

        let snapshot = metrics.snapshot(&job_id, Duration::from_secs(60));

        assert_eq!(snapshot.p95_latency_ms, Some(500.0));
        assert_eq!(snapshot.request_count, 5);
        assert_eq!(snapshot.error_count, 0);
    }

    #[test]
    fn snapshot_ignores_requests_outside_window() {
        let metrics = ProxyMetrics::new();
        let job_id = JobId("api".into());
        let service_name = ServiceName("api".into());

        metrics.record_request_at(
            &job_id,
            &service_name,
            200,
            Duration::from_millis(1000),
            std::time::Instant::now() - Duration::from_secs(120),
        );
        metrics.record_request(&job_id, &service_name, 500, Duration::from_millis(250));

        let snapshot = metrics.snapshot(&job_id, Duration::from_secs(60));

        assert_eq!(snapshot.p95_latency_ms, Some(250.0));
        assert_eq!(snapshot.request_count, 1);
        assert_eq!(snapshot.error_count, 1);
    }

    #[test]
    fn record_prunes_samples_older_than_max_age() {
        let metrics = ProxyMetrics::new();
        let job_id = JobId("api".into());
        let service_name = ServiceName("api".into());
        let now = std::time::Instant::now();

        // Older than MAX_SAMPLE_AGE relative to the next sample → dropped on insert.
        metrics.record_request_at(
            &job_id,
            &service_name,
            200,
            Duration::from_millis(10),
            now - Duration::from_secs(2000),
        );
        metrics.record_request_at(&job_id, &service_name, 200, Duration::from_millis(20), now);

        let snapshot = metrics.snapshot(&job_id, Duration::from_secs(3600));
        assert_eq!(snapshot.request_count, 1);
    }

    #[test]
    fn snapshot_evicts_stale_job_keys() {
        let metrics = ProxyMetrics::new();
        let stale = JobId("stale".into());
        let service_name = ServiceName("stale".into());

        metrics.record_request_at(
            &stale,
            &service_name,
            200,
            Duration::from_millis(10),
            std::time::Instant::now() - Duration::from_secs(2000),
        );
        assert_eq!(metrics.tracked_jobs(), 1);

        // Any snapshot sweeps whole-map stale entries, bounding the key set.
        let _ = metrics.snapshot(&JobId("other".into()), Duration::from_secs(60));
        assert_eq!(metrics.tracked_jobs(), 0);
    }
}
