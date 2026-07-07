use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nscale_core::job::{JobId, ServiceName};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProxyMetricSnapshot {
    pub p95_latency_ms: Option<f64>,
    pub request_count: u64,
    pub error_count: u64,
}

#[derive(Clone, Default)]
pub struct ProxyMetrics {
    requests: Arc<Mutex<HashMap<String, Vec<RequestSample>>>>,
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

        let mut requests = self
            .requests
            .lock()
            .expect("proxy metrics lock should not be poisoned");
        requests
            .entry(job_id.0.clone())
            .or_default()
            .push(RequestSample {
                status,
                duration,
                observed_at,
            });
    }

    pub fn snapshot(&self, job_id: &JobId, window: Duration) -> ProxyMetricSnapshot {
        let cutoff = Instant::now() - window;
        let mut requests = self
            .requests
            .lock()
            .expect("proxy metrics lock should not be poisoned");
        let Some(samples) = requests.get_mut(&job_id.0) else {
            return ProxyMetricSnapshot::default();
        };

        samples.retain(|sample| sample.observed_at >= cutoff);
        let mut durations_ms: Vec<f64> = samples
            .iter()
            .map(|sample| sample.duration.as_secs_f64() * 1000.0)
            .collect();
        durations_ms.sort_by(f64::total_cmp);

        let p95_latency_ms = if durations_ms.is_empty() {
            None
        } else {
            let index = ((durations_ms.len() as f64 * 0.95).ceil() as usize).saturating_sub(1);
            durations_ms.get(index).copied()
        };

        ProxyMetricSnapshot {
            p95_latency_ms,
            request_count: samples.len() as u64,
            error_count: samples.iter().filter(|sample| sample.status >= 500).count() as u64,
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
}
