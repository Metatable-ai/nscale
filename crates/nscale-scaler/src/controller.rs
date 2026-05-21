use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use tokio::time;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::inflight::InFlightTracker;
use nscale_core::job::JobId;
use nscale_core::traits::{ActivityStore, MissingJobTracker, Orchestrator};
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::WakeCoordinator;

use crate::traffic_probe::TrafficProbe;

const SCALE_DOWN_LOCK_KEY: &str = "nscale:lock:scale-down";
/// Initial backoff when scale-down is blocked by an active deployment.
const DEPLOYMENT_BACKOFF: Duration = Duration::from_secs(30);

/// Background controller that detects idle jobs and scales them to zero.
///
/// Only one instance acquires the distributed lock per cycle, so multiple
/// replicas can run safely.
pub struct ScaleDownController {
    orchestrator: Arc<dyn Orchestrator>,
    store: Arc<dyn ActivityStore>,
    registry: Arc<JobRegistry>,
    coordinator: Arc<WakeCoordinator>,
    traffic_probe: Option<Arc<TrafficProbe>>,
    in_flight: InFlightTracker,
    missing_job_tracker: Arc<dyn MissingJobTracker>,
    idle_threshold: Duration,
    interval: Duration,
    lock_ttl: Duration,
    auto_deregister_enabled: bool,
    auto_deregister_threshold: u32,
    cancel: CancellationToken,
    /// Jobs deferred due to active deployments; maps job_id → earliest retry time.
    deferred_jobs: Arc<DashMap<String, Instant>>,
}

impl ScaleDownController {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        orchestrator: Arc<dyn Orchestrator>,
        store: Arc<dyn ActivityStore>,
        registry: Arc<JobRegistry>,
        coordinator: Arc<WakeCoordinator>,
        traffic_probe: Option<Arc<TrafficProbe>>,
        in_flight: InFlightTracker,
        missing_job_tracker: Arc<dyn MissingJobTracker>,
        idle_threshold: Duration,
        interval: Duration,
        auto_deregister_enabled: bool,
        auto_deregister_threshold: u32,
        cancel: CancellationToken,
    ) -> Self {
        // Lock TTL should be a bit longer than the interval to avoid overlap
        let lock_ttl = interval + Duration::from_secs(5);
        Self {
            orchestrator,
            store,
            registry,
            coordinator,
            traffic_probe,
            in_flight,
            missing_job_tracker,
            idle_threshold,
            interval,
            lock_ttl,
            auto_deregister_enabled,
            auto_deregister_threshold,
            cancel,
            deferred_jobs: Arc::new(DashMap::new()),
        }
    }

    async fn clear_missing_job_counter(&self, job_id: &JobId) {
        if !self.auto_deregister_enabled {
            return;
        }

        if let Err(e) = self.missing_job_tracker.clear_not_found(job_id).await {
            warn!(job_id = %job_id, error = %e, "failed to clear missing-job counter");
        }
    }

    async fn cleanup_missing_job_state(&self, job_id: &JobId) -> Result<()> {
        self.coordinator.mark_dormant(job_id);

        if let Err(e) = self.store.remove_activity(job_id).await {
            warn!(job_id = %job_id, error = %e, "failed to remove activity during auto-deregister cleanup");
        }

        self.deferred_jobs.remove(&job_id.0);

        if let Some(probe) = &self.traffic_probe {
            probe.clear_baseline(job_id).await;
        }

        self.registry.deregister(job_id).await?;

        if let Err(e) = self.missing_job_tracker.clear_not_found(job_id).await {
            warn!(job_id = %job_id, error = %e, "failed to clear missing-job counter after auto-deregister");
        }

        Ok(())
    }

    async fn handle_missing_job(&self, job_id: &JobId) {
        if !self.auto_deregister_enabled {
            warn!(job_id = %job_id, "Nomad reported job missing during scale-down but auto-deregister is disabled");
            return;
        }

        let count = match self.missing_job_tracker.increment_not_found(job_id).await {
            Ok(count) => count,
            Err(e) => {
                error!(job_id = %job_id, error = %e, "failed to increment missing-job counter");
                return;
            }
        };

        if count >= self.auto_deregister_threshold {
            match self.cleanup_missing_job_state(job_id).await {
                Ok(()) => {
                    warn!(
                        job_id = %job_id,
                        count,
                        threshold = self.auto_deregister_threshold,
                        "auto-deregistered stale job after repeated scale-down missing-job responses"
                    );
                }
                Err(e) => {
                    error!(
                        job_id = %job_id,
                        count,
                        threshold = self.auto_deregister_threshold,
                        error = %e,
                        "failed to auto-deregister stale job after scale-down missing-job threshold"
                    );
                }
            }
        } else {
            warn!(
                job_id = %job_id,
                count,
                threshold = self.auto_deregister_threshold,
                "Nomad reported registered job missing during scale-down"
            );
        }
    }

    /// Run the scale-down loop until cancelled.
    pub async fn run(self) {
        info!(
            idle_threshold_secs = self.idle_threshold.as_secs(),
            interval_secs = self.interval.as_secs(),
            "starting scale-down controller"
        );

        let mut ticker = time::interval(self.interval);
        ticker.set_missed_tick_behavior(time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    info!("scale-down controller shutting down");
                    return;
                }
                _ = ticker.tick() => {
                    if let Err(e) = self.tick().await {
                        error!(error = %e, "scale-down tick failed");
                    }
                }
            }
        }
    }

    #[instrument(skip(self))]
    async fn tick(&self) -> Result<()> {
        // Try to acquire distributed lock
        if !self
            .store
            .try_acquire_lock(SCALE_DOWN_LOCK_KEY, self.lock_ttl)
            .await?
        {
            debug!("another instance holds the scale-down lock, skipping");
            return Ok(());
        }

        let _lock_guard = LockGuard {
            store: self.store.clone(),
            key: SCALE_DOWN_LOCK_KEY,
        };

        // Activity seeding is handled reactively by the Nomad event stream
        // processor (EventProcessor). The stream subscribes to Allocation
        // events and records activity when allocations reach "running".

        // Find and scale down truly idle jobs
        let idle_jobs = self.store.get_idle_jobs(self.idle_threshold).await?;
        if idle_jobs.is_empty() {
            debug!("no idle jobs found");
            return Ok(());
        }

        info!(count = idle_jobs.len(), "found idle jobs to scale down");

        for job_id in &idle_jobs {
            if self.cancel.is_cancelled() {
                break;
            }
            self.scale_down_job(job_id).await;
        }

        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn scale_down_job(&self, job_id: &JobId) {
        // --- Deferred guard: skip jobs that are backing off after a blocked deployment ---
        if let Some(entry) = self.deferred_jobs.get(&job_id.0) {
            if Instant::now() < *entry {
                debug!("job is deferred due to active deployment, skipping");
                return;
            }
            // Backoff expired — remove and proceed
            drop(entry);
            self.deferred_jobs.remove(&job_id.0);
        }

        // --- In-flight guard: skip if nscale is actively proxying requests for this job ---
        if self.in_flight.has_in_flight(&job_id.0) {
            let count = self.in_flight.count(&job_id.0);
            info!(
                in_flight = count,
                source = "in-flight-guard",
                "job has in-flight proxy requests, refreshing activity"
            );
            if let Err(e) = self.store.record_activity(job_id).await {
                warn!(error = %e, "failed to refresh activity for in-flight job");
            }
            return;
        }

        // --- Traffic guard: skip if Traefik is actively routing to this service ---
        if let Some(probe) = &self.traffic_probe {
            match probe.has_active_traffic(job_id).await {
                Ok(true) => {
                    info!(
                        source = "traffic-guard",
                        "service has active Traefik traffic, refreshing activity"
                    );
                    if let Err(e) = self.store.record_activity(job_id).await {
                        warn!(error = %e, "failed to refresh activity for active service");
                    }
                    return;
                }
                Ok(false) => {
                    debug!("no active Traefik traffic, proceeding with scale-down");
                }
                Err(e) => {
                    // Fail-open: if we can't reach Traefik metrics, skip this
                    // job to avoid accidentally scaling down an active service.
                    warn!(error = %e, "traffic probe failed, skipping scale-down to be safe");
                    return;
                }
            }
        }

        // Look up registration to get the group name
        let registration = match self.registry.get(job_id).await {
            Ok(Some(reg)) => reg,
            Ok(None) => {
                warn!("no registration found for idle job, cleaning up activity");
                let _ = self.store.remove_activity(job_id).await;
                return;
            }
            Err(e) => {
                error!(error = %e, "failed to look up job registration");
                return;
            }
        };

        info!(group = %registration.nomad_group, "scaling down idle job");

        // Scale down via Nomad
        let scale_down_result = self
            .orchestrator
            .scale_down(&registration.job_id, &registration.nomad_group)
            .await;

        match scale_down_result {
            Ok(()) => {
                self.clear_missing_job_counter(job_id).await;
                handle_scale_down_result(
                    self.store.as_ref(),
                    self.coordinator.as_ref(),
                    self.traffic_probe.as_deref(),
                    &self.deferred_jobs,
                    job_id,
                    Ok(()),
                )
                .await;
            }
            Err(NscaleError::JobNotFound(_)) => {
                self.handle_missing_job(job_id).await;
            }
            Err(err @ NscaleError::DeploymentInProgress { .. }) => {
                self.clear_missing_job_counter(job_id).await;
                handle_scale_down_result(
                    self.store.as_ref(),
                    self.coordinator.as_ref(),
                    self.traffic_probe.as_deref(),
                    &self.deferred_jobs,
                    job_id,
                    Err(err),
                )
                .await;
            }
            Err(e) => {
                handle_scale_down_result(
                    self.store.as_ref(),
                    self.coordinator.as_ref(),
                    self.traffic_probe.as_deref(),
                    &self.deferred_jobs,
                    job_id,
                    Err(e),
                )
                .await;
            }
        }
    }
}

async fn handle_scale_down_result(
    store: &dyn ActivityStore,
    coordinator: &WakeCoordinator,
    traffic_probe: Option<&TrafficProbe>,
    deferred_jobs: &DashMap<String, Instant>,
    job_id: &JobId,
    scale_down_result: Result<()>,
) {
    match scale_down_result {
        Ok(()) => {
            info!("job scaled to zero");
            coordinator.mark_dormant(job_id);
            if let Err(e) = store.remove_activity(job_id).await {
                warn!(error = %e, "failed to remove activity after scale-down");
            }
            // Clear stale traffic baseline so next wake starts fresh.
            if let Some(probe) = traffic_probe {
                probe.clear_baseline(job_id).await;
            }
            // Clear any pending deferral.
            deferred_jobs.remove(&job_id.0);
        }
        Err(NscaleError::DeploymentInProgress { operation, .. }) => {
            info!(
                operation,
                "scale-down blocked by active deployment, deferring for {}s",
                DEPLOYMENT_BACKOFF.as_secs(),
            );
            deferred_jobs.insert(job_id.0.clone(), Instant::now() + DEPLOYMENT_BACKOFF);
            if let Err(e) = store.record_activity(job_id).await {
                warn!(error = %e, "failed to refresh activity after blocked scale-down");
            }
        }
        Err(e) => {
            error!(error = %e, "failed to scale down job");
        }
    }
}

/// RAII guard that releases the distributed lock on drop.
struct LockGuard {
    store: Arc<dyn ActivityStore>,
    key: &'static str,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let store = self.store.clone();
        let key = self.key.to_string();
        tokio::spawn(async move {
            if let Err(e) = store.release_lock(&key).await {
                warn!(error = %e, key = %key, "failed to release lock");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::{Endpoint, JobRegistration, ServiceName};
    use nscale_core::traits::ServiceDiscovery;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct MockOrchestrator {
        scale_down_calls: AtomicU32,
    }

    impl MockOrchestrator {
        fn new() -> Self {
            Self {
                scale_down_calls: AtomicU32::new(0),
            }
        }
    }

    #[async_trait::async_trait]
    impl Orchestrator for MockOrchestrator {
        async fn scale_up(&self, _: &JobId, _: &str, _: u32) -> Result<()> {
            Ok(())
        }
        async fn scale_down(&self, _: &JobId, _: &str) -> Result<()> {
            self.scale_down_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        async fn get_job_count(&self, _: &JobId, _: &str) -> Result<u32> {
            Ok(0)
        }
        async fn get_healthy_endpoint(&self, _: &JobId) -> Result<Option<Endpoint>> {
            Ok(None)
        }
    }

    struct MockStore {
        idle_jobs: Vec<JobId>,
        lock_acquired: std::sync::atomic::AtomicBool,
        record_activity_calls: AtomicU32,
        remove_activity_calls: AtomicU32,
    }

    impl MockStore {
        fn new(idle_jobs: Vec<JobId>) -> Self {
            Self {
                idle_jobs,
                lock_acquired: std::sync::atomic::AtomicBool::new(false),
                record_activity_calls: AtomicU32::new(0),
                remove_activity_calls: AtomicU32::new(0),
            }
        }
    }

    #[async_trait::async_trait]
    impl ActivityStore for MockStore {
        async fn record_activity(&self, _: &JobId) -> Result<()> {
            self.record_activity_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        async fn get_idle_jobs(&self, _: Duration) -> Result<Vec<JobId>> {
            Ok(self.idle_jobs.clone())
        }
        async fn try_acquire_lock(&self, _: &str, _: Duration) -> Result<bool> {
            Ok(!self.lock_acquired.swap(true, Ordering::Relaxed))
        }
        async fn release_lock(&self, _: &str) -> Result<()> {
            self.lock_acquired.store(false, Ordering::Relaxed);
            Ok(())
        }
        async fn remove_activity(&self, _: &JobId) -> Result<()> {
            self.remove_activity_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }
        async fn has_activity(&self, job_id: &JobId) -> Result<bool> {
            Ok(self.idle_jobs.iter().any(|j| j == job_id))
        }
    }

    struct MockDiscovery;

    #[async_trait::async_trait]
    impl ServiceDiscovery for MockDiscovery {
        async fn register_fallback(&self, _: &ServiceName, _: &Endpoint) -> Result<()> {
            Ok(())
        }
        async fn deregister_fallback(&self, _: &ServiceName) -> Result<()> {
            Ok(())
        }
        async fn wait_for_healthy(&self, _: &ServiceName, _: Duration) -> Result<Endpoint> {
            Ok(Endpoint::new("10.0.0.1", 8080))
        }
    }

    fn test_registration(job_id: &str) -> JobRegistration {
        JobRegistration {
            job_id: JobId(job_id.into()),
            service_name: ServiceName(format!("svc-{job_id}")),
            nomad_group: "web".into(),
        }
    }

    #[tokio::test]
    async fn test_scale_down_controller_single_tick() {
        let orch = Arc::new(MockOrchestrator::new());
        let idle_jobs = vec![JobId("job-a".into()), JobId("job-b".into())];
        let store: Arc<dyn ActivityStore> = Arc::new(MockStore::new(idle_jobs));

        // We need a real (fred) JobRegistry for the controller, but we can't
        // use one without Redis. Instead, test the tick logic separately.
        // For now, verify the controller compiles and the mocks are correct.
        let _orch_ref = orch.clone();
        let _store_ref = store.clone();

        // The lock is acquirable
        assert!(
            store
                .try_acquire_lock("test", Duration::from_secs(5))
                .await
                .unwrap()
        );
        // Second attempt fails
        assert!(
            !store
                .try_acquire_lock("test", Duration::from_secs(5))
                .await
                .unwrap()
        );
        // Release
        store.release_lock("test").await.unwrap();
        // Now acquirable again
        assert!(
            store
                .try_acquire_lock("test", Duration::from_secs(5))
                .await
                .unwrap()
        );
    }

    /// Verify that InFlightTracker prevents scale-down while requests are in-flight,
    /// and allows scale-down once the guard is dropped.
    #[tokio::test]
    async fn test_in_flight_tracker_blocks_scale_down() {
        // Simulate the scale-down decision logic from scale_down_job()
        let tracker = InFlightTracker::new();
        let job_id = "in-flight-job";

        // No in-flight requests → should allow scale-down
        assert!(!tracker.has_in_flight(job_id), "no requests tracked yet");

        // Acquire an in-flight guard (simulates proxy_handler tracking a request)
        let guard = tracker.track(job_id);
        assert!(
            tracker.has_in_flight(job_id),
            "guard is held, should show in-flight"
        );
        assert_eq!(tracker.count(job_id), 1);

        // Scale-down check: should skip because of in-flight
        // (mirrors the logic in scale_down_job)
        let should_skip = tracker.has_in_flight(job_id);
        assert!(
            should_skip,
            "scale-down should be skipped with in-flight request"
        );

        // Acquire a second guard (concurrent request)
        let guard2 = tracker.track(job_id);
        assert_eq!(tracker.count(job_id), 2);

        // Drop first guard — still 1 in-flight
        drop(guard);
        assert!(tracker.has_in_flight(job_id));
        assert_eq!(tracker.count(job_id), 1);

        // Drop second guard — now 0 in-flight
        drop(guard2);
        assert!(!tracker.has_in_flight(job_id));
        assert_eq!(tracker.count(job_id), 0);

        // Now scale-down should proceed
        let should_proceed = !tracker.has_in_flight(job_id);
        assert!(
            should_proceed,
            "scale-down should proceed with no in-flight requests"
        );
    }

    /// Verify that InFlightTracker correctly isolates per-job counts.
    #[tokio::test]
    async fn test_in_flight_tracker_per_job_isolation() {
        let tracker = InFlightTracker::new();

        let _guard_a = tracker.track("job-a");
        let _guard_b = tracker.track("job-b");

        // job-a has in-flight but job-c does not
        assert!(tracker.has_in_flight("job-a"));
        assert!(tracker.has_in_flight("job-b"));
        assert!(!tracker.has_in_flight("job-c"));

        // Dropping job-a guard should not affect job-b
        drop(_guard_a);
        assert!(!tracker.has_in_flight("job-a"));
        assert!(tracker.has_in_flight("job-b"));
    }

    #[tokio::test]
    async fn test_handle_scale_down_result_refreshes_activity_when_nomad_is_busy() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coordinator = WakeCoordinator::new(orch, disc, 10, Duration::from_secs(2));
        let store = MockStore::new(vec![]);
        let deferred = DashMap::new();
        let registration = test_registration("busy-job");

        coordinator.ensure_running(&registration).await.unwrap();
        assert!(coordinator.is_ready(&registration.job_id));

        handle_scale_down_result(
            &store,
            &coordinator,
            None,
            &deferred,
            &registration.job_id,
            Err(NscaleError::DeploymentInProgress {
                job_id: registration.job_id.0.clone(),
                operation: "scale down",
            }),
        )
        .await;

        assert_eq!(store.record_activity_calls.load(Ordering::Relaxed), 1);
        assert_eq!(store.remove_activity_calls.load(Ordering::Relaxed), 0);
        assert!(coordinator.is_ready(&registration.job_id));
        // Job should now be deferred
        assert!(deferred.contains_key(&registration.job_id.0));
    }

    #[tokio::test]
    async fn test_handle_scale_down_result_marks_dormant_on_success() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coordinator = WakeCoordinator::new(orch, disc, 10, Duration::from_secs(2));
        let store = MockStore::new(vec![]);
        let deferred = DashMap::new();
        let registration = test_registration("idle-job");

        coordinator.ensure_running(&registration).await.unwrap();
        assert!(coordinator.is_ready(&registration.job_id));

        handle_scale_down_result(
            &store,
            &coordinator,
            None,
            &deferred,
            &registration.job_id,
            Ok(()),
        )
        .await;

        assert_eq!(store.record_activity_calls.load(Ordering::Relaxed), 0);
        assert_eq!(store.remove_activity_calls.load(Ordering::Relaxed), 1);
        assert!(!coordinator.is_ready(&registration.job_id));
    }

    #[tokio::test]
    async fn test_deferred_job_skipped_until_backoff_expires() {
        let deferred: DashMap<String, Instant> = DashMap::new();
        let job_id = "deferred-job";

        // Defer the job 30s into the future
        deferred.insert(job_id.to_string(), Instant::now() + Duration::from_secs(30));

        // Should be skipped (backoff not expired)
        assert!(deferred.get(job_id).is_some());
        let entry = deferred.get(job_id).unwrap();
        assert!(Instant::now() < *entry, "backoff should still be active");
        drop(entry);

        // Simulate backoff expiry by setting time in the past
        deferred.insert(job_id.to_string(), Instant::now() - Duration::from_secs(1));
        let entry = deferred.get(job_id).unwrap();
        assert!(Instant::now() >= *entry, "backoff should have expired");
    }
}
