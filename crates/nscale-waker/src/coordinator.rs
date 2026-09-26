use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use tracing::{debug, error, info, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{Endpoint, JobRegistration, ScaleUnit};
use nscale_core::lease::{Lease, job_lock_key};
use nscale_core::traits::{ActivityStore, Orchestrator, ServiceDiscovery};

use crate::state::{STATE_DORMANT, STATE_READY, STATE_WAKING, WakeResult, WakeState};

/// Coordinates wake-ups with request coalescing.
/// Multiple concurrent requests for the same dormant job result in a single scale-up call.
pub struct WakeCoordinator {
    jobs: Arc<DashMap<String, Arc<WakeState>>>,
    orchestrator: Arc<dyn Orchestrator>,
    discovery: Arc<dyn ServiceDiscovery>,
    wake_semaphore: Arc<tokio::sync::Semaphore>,
    wake_timeout: Duration,
    activity_store: Option<Arc<dyn ActivityStore>>,
    /// Cache of endpoint for ready jobs.
    endpoints: Arc<DashMap<String, Endpoint>>,
    service_endpoints: DashMap<(String, String), EndpointPool>,
    endpoint_refresh: Duration,
    refresh_locks: DashMap<(String, String), Arc<tokio::sync::Mutex<()>>>,
}

struct EndpointPool {
    endpoints: Vec<Endpoint>,
    next: usize,
    refreshed: tokio::time::Instant,
}

impl EndpointPool {
    fn refresh(&mut self, endpoints: Vec<Endpoint>) {
        // Keep the next endpoint's identity when Consul reorders its response.
        // If it disappeared, keep the cursor position within the new pool.
        let next = self.endpoints.get(self.next % self.endpoints.len().max(1));
        self.next = next
            .and_then(|next| {
                endpoints
                    .iter()
                    .position(|endpoint| endpoint.host == next.host && endpoint.port == next.port)
            })
            .unwrap_or(self.next % endpoints.len().max(1));
        self.endpoints = endpoints;
        self.refreshed = tokio::time::Instant::now();
    }

    fn select(&mut self) -> Option<Endpoint> {
        if self.endpoints.is_empty() {
            return None;
        }
        let endpoint = self.endpoints[self.next % self.endpoints.len()].clone();
        self.next = self.next.wrapping_add(1);
        Some(endpoint)
    }
}

#[derive(Debug, Clone)]
pub enum EndpointRefresh {
    Confirmed(Endpoint),
    Updated(Endpoint),
    Missing,
}

impl WakeCoordinator {
    pub fn new(
        orchestrator: Arc<dyn Orchestrator>,
        discovery: Arc<dyn ServiceDiscovery>,
        nomad_concurrency: usize,
        wake_timeout: Duration,
    ) -> Self {
        Self {
            jobs: Arc::new(DashMap::new()),
            orchestrator,
            discovery,
            wake_semaphore: Arc::new(tokio::sync::Semaphore::new(nomad_concurrency)),
            wake_timeout,
            activity_store: None,
            endpoints: Arc::new(DashMap::new()),
            service_endpoints: DashMap::new(),
            endpoint_refresh: Duration::from_secs(2),
            refresh_locks: DashMap::new(),
        }
    }

    pub fn with_activity_store(mut self, store: Arc<dyn ActivityStore>) -> Self {
        self.activity_store = Some(store);
        self
    }

    pub fn with_endpoint_refresh(mut self, interval: Duration) -> Self {
        self.endpoint_refresh = interval;
        self
    }

    /// Wake is coalesced per group; routing is selected per service/port.
    pub async fn ensure_running(&self, reg: &JobRegistration) -> Result<Endpoint> {
        let key = (reg.scale_unit_key().0, reg.service_name.0.clone());
        if let Some(mut pool) = self.service_endpoints.get_mut(&key)
            && pool.refreshed.elapsed() < self.endpoint_refresh
            && let Some(endpoint) = pool.select()
        {
            return Ok(endpoint);
        }
        let lock = self
            .refresh_locks
            .entry(key.clone())
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone();
        let _guard = lock.lock().await;
        if let Some(mut pool) = self.service_endpoints.get_mut(&key)
            && pool.refreshed.elapsed() < self.endpoint_refresh
            && let Some(endpoint) = pool.select()
        {
            return Ok(endpoint);
        }

        // Even after process restart, a running group must not be scaled back to one.
        self.ensure_group_running(reg).await?;
        let mut endpoints = self.discovery.healthy_endpoints(&reg.service_name).await?;
        if endpoints.is_empty() {
            self.mark_dormant(&reg.scale_unit_key());
            self.ensure_group_running(reg).await?;
            endpoints = self.discovery.healthy_endpoints(&reg.service_name).await?;
        }
        self.refresh_pool(key, endpoints)
            .ok_or_else(|| NscaleError::JobNotReady(reg.service_name.0.clone()))
    }

    fn refresh_pool(&self, key: (String, String), endpoints: Vec<Endpoint>) -> Option<Endpoint> {
        let mut pool = self
            .service_endpoints
            .entry(key)
            .or_insert_with(|| EndpointPool {
                endpoints: Vec::new(),
                next: 0,
                refreshed: tokio::time::Instant::now(),
            });
        pool.refresh(endpoints);
        pool.select()
    }

    /// Ensure a job is running and return its endpoint.
    /// If dormant, triggers a scale-up and coalesces concurrent requests.
    /// If already waking, subscribes to the existing wake-up broadcast.
    /// If ready, returns the cached endpoint immediately.
    #[instrument(skip(self, reg), fields(job_id = %reg.job_id))]
    async fn ensure_group_running(&self, reg: &JobRegistration) -> Result<Endpoint> {
        let job_key = reg.scale_unit_key().0;

        // Fast path: already ready with cached endpoint
        if let Some(ep) = self.endpoints.get(&job_key) {
            debug!("job already ready, returning cached endpoint");
            return Ok(ep.clone());
        }

        // Check or create wake state
        loop {
            // Scope the DashMap access so the shard lock is released
            // before any .await — holding it across awaits deadlocks.
            let state = {
                let entry = self.jobs.entry(job_key.clone());
                let state_ref = entry.or_insert_with(|| {
                    Arc::new(WakeState {
                        status: std::sync::atomic::AtomicU8::new(STATE_DORMANT),
                        notify: tokio::sync::broadcast::channel(16).0,
                    })
                });
                Arc::clone(&*state_ref)
            }; // <-- DashMap shard lock dropped here

            let mut rx = state.notify.subscribe();
            let current = state.status.load(std::sync::atomic::Ordering::Acquire);

            match current {
                STATE_READY => {
                    // Check endpointcache
                    if let Some(ep) = self.endpoints.get(&job_key) {
                        return Ok(ep.clone());
                    }
                    // Endpoint cache miss but state is ready — fetch from orchestrator
                    let ep = self
                        .orchestrator
                        .get_healthy_endpoint(&reg.job_id, &reg.nomad_group)
                        .await?
                        .ok_or_else(|| {
                            NscaleError::JobNotReady(format!(
                                "job {} marked ready but no healthy endpoint",
                                reg.job_id
                            ))
                        })?;
                    self.endpoints.insert(job_key.clone(), ep.clone());
                    return Ok(ep);
                }
                STATE_WAKING => {
                    // Subscribe to existing wake-up
                    debug!("job is waking, subscribing to broadcast");

                    return match tokio::time::timeout(self.wake_timeout, rx.recv()).await {
                        Ok(Ok(WakeResult::Ready(ep))) => Ok(ep),
                        Ok(Ok(WakeResult::Cancelled)) => Err(NscaleError::WakeAbandoned {
                            job_id: reg.job_id.0.clone(),
                        }),
                        Ok(Ok(WakeResult::JobNotFound(job_id))) => {
                            Err(NscaleError::JobNotFound(job_id))
                        }
                        Ok(Ok(WakeResult::Failed(msg))) => {
                            Err(NscaleError::Nomad(format!("wake failed: {}", msg)))
                        }
                        Ok(Err(_)) => Err(NscaleError::Nomad(
                            "wake broadcast channel closed".to_string(),
                        )),
                        Err(_) => Err(NscaleError::WakeTimeout {
                            job_id: reg.job_id.0.clone(),
                            elapsed_secs: self.wake_timeout.as_secs_f64(),
                        }),
                    };
                }
                STATE_DORMANT => {
                    // Try to become the waker
                    if state.try_start_wake() {
                        debug!("won wake race, starting wake task");

                        // Spawn the actual wake task
                        let orchestrator = self.orchestrator.clone();
                        let discovery = self.discovery.clone();
                        let semaphore = self.wake_semaphore.clone();
                        let timeout = self.wake_timeout;
                        let store = self.activity_store.clone();
                        let reg_clone = reg.clone();
                        let endpoints = self.endpoints.clone();
                        let jobs = self.jobs.clone();
                        let notify = state.notify.clone();
                        let state_clone = state.clone();

                        tokio::spawn(async move {
                            let result = run_wake_task(
                                orchestrator.as_ref(),
                                discovery.as_ref(),
                                &semaphore,
                                &reg_clone,
                                timeout,
                                &notify,
                                store,
                            )
                            .await;

                            match result {
                                Ok(endpoint) => {
                                    info!(
                                        job_id = %reg_clone.job_id,
                                        endpoint = %endpoint,
                                        "job woke up successfully"
                                    );
                                    endpoints
                                        .insert(reg_clone.scale_unit_key().0, endpoint.clone());
                                    state_clone.set_ready();
                                    let _ = notify.send(WakeResult::Ready(endpoint));
                                }
                                Err(NscaleError::WakeAbandoned { .. }) => {
                                    info!(
                                        job_id = %reg_clone.job_id,
                                        "wake abandoned: all request handlers disconnected"
                                    );
                                    state_clone.set_dormant();
                                    let _ = notify.send(WakeResult::Cancelled);
                                    jobs.remove(&reg_clone.scale_unit_key().0);
                                }
                                Err(NscaleError::JobNotFound(job_id)) => {
                                    warn!(
                                        job_id = %reg_clone.job_id,
                                        missing_job = %job_id,
                                        "wake task could not find job in Nomad"
                                    );
                                    state_clone.set_dormant();
                                    let _ = notify.send(WakeResult::JobNotFound(job_id));
                                    jobs.remove(&reg_clone.scale_unit_key().0);
                                }
                                Err(e) => {
                                    error!(
                                        job_id = %reg_clone.job_id,
                                        error = %e,
                                        "wake task failed"
                                    );
                                    state_clone.set_dormant();
                                    let _ = notify.send(WakeResult::Failed(e.to_string()));
                                    // Remove entry so next request tries again
                                    jobs.remove(&reg_clone.scale_unit_key().0);
                                }
                            }
                        });

                        // Wait for the result
                        return match tokio::time::timeout(self.wake_timeout, rx.recv()).await {
                            Ok(Ok(WakeResult::Ready(ep))) => Ok(ep),
                            Ok(Ok(WakeResult::Cancelled)) => Err(NscaleError::WakeAbandoned {
                                job_id: reg.job_id.0.clone(),
                            }),
                            Ok(Ok(WakeResult::JobNotFound(job_id))) => {
                                Err(NscaleError::JobNotFound(job_id))
                            }
                            Ok(Ok(WakeResult::Failed(msg))) => {
                                Err(NscaleError::Nomad(format!("wake failed: {}", msg)))
                            }
                            Ok(Err(_)) => Err(NscaleError::Nomad(
                                "wake broadcast channel closed".to_string(),
                            )),
                            Err(_) => Err(NscaleError::WakeTimeout {
                                job_id: reg.job_id.0.clone(),
                                elapsed_secs: self.wake_timeout.as_secs_f64(),
                            }),
                        };
                    }
                    // Lost the race — loop and it'll be WAKING next iteration
                    continue;
                }
                _ => {
                    warn!(status = current, "unexpected wake state");
                    return Err(NscaleError::JobNotReady(format!(
                        "unexpected state {} for job {}",
                        current, reg.job_id
                    )));
                }
            }
        }
    }

    /// An allocation change invalidates discovery, not the group's desired count.
    pub fn invalidate_service_endpoints(&self, unit: &ScaleUnit) {
        self.service_endpoints.retain(|(key, _), _| key != &unit.0);
    }

    /// Mark a scale-to-zero unit as dormant (called after scale-down).
    pub fn mark_dormant(&self, unit: &ScaleUnit) {
        self.service_endpoints.retain(|(key, _), _| key != &unit.0);
        self.endpoints.remove(&unit.0);
        if let Some(state) = self.jobs.get(&unit.0) {
            state.set_dormant();
        }
        self.jobs.remove(&unit.0);
    }

    /// Invalidate the cached endpoint for a unit, forcing the next
    /// `ensure_running` call to re-discover (and re-wake if needed).
    /// Called when the proxy detects a backend connection failure.
    pub fn invalidate(&self, unit: &ScaleUnit) {
        self.service_endpoints.retain(|(key, _), _| key != &unit.0);
        self.endpoints.remove(&unit.0);
        if let Some(state) = self.jobs.get(&unit.0) {
            state.set_dormant();
        }
        self.jobs.remove(&unit.0);
        info!(unit = %unit, "invalidated stale endpoint cache");
    }

    /// Re-check the running endpoint for a job without forcing a scale-up.
    /// This is used after transient proxy transport failures to avoid
    /// invalidating a healthy cached endpoint unless Consul disagrees.
    #[instrument(skip(self, reg, current), fields(job_id = %reg.job_id, endpoint = %current))]
    pub async fn refresh_endpoint(
        &self,
        reg: &JobRegistration,
        current: &Endpoint,
    ) -> Result<EndpointRefresh> {
        let key = (reg.scale_unit_key().0, reg.service_name.0.clone());
        let endpoints = self.discovery.healthy_endpoints(&reg.service_name).await?;
        match self.refresh_pool(key, endpoints) {
            Some(endpoint) => {
                if endpoint.host == current.host && endpoint.port == current.port {
                    Ok(EndpointRefresh::Confirmed(endpoint))
                } else {
                    Ok(EndpointRefresh::Updated(endpoint))
                }
            }
            None => {
                self.mark_dormant(&reg.scale_unit_key());
                Ok(EndpointRefresh::Missing)
            }
        }
    }

    /// Check if a unit is currently in the Ready state.
    pub fn is_ready(&self, unit: &ScaleUnit) -> bool {
        self.endpoints.contains_key(&unit.0)
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_wake_task(
    orchestrator: &dyn Orchestrator,
    discovery: &dyn ServiceDiscovery,
    semaphore: &tokio::sync::Semaphore,
    reg: &JobRegistration,
    timeout: Duration,
    notify: &tokio::sync::broadcast::Sender<WakeResult>,
    store: Option<Arc<dyn ActivityStore>>,
) -> Result<Endpoint> {
    // Phase 1: Acquire semaphore to bound concurrent Nomad API calls.
    // The permit is held only during scale_up (fast ~5ms), NOT during
    // the entire wake (which includes 1-60s of Consul health polling).
    let permit = semaphore
        .acquire()
        .await
        .map_err(|_| NscaleError::Nomad("wake semaphore closed".to_string()))?;

    debug!(job_id = %reg.job_id, group = %reg.nomad_group, "scaling up job");
    let scale = async {
        if orchestrator
            .get_job_count(&reg.job_id, &reg.nomad_group)
            .await?
            == 0
        {
            let count = reg
                .autoscaling
                .as_ref()
                .filter(|p| p.enabled)
                .map_or(1, |p| p.min_count.max(1));
            orchestrator
                .scale_up(&reg.job_id, &reg.nomad_group, count)
                .await?;
        }

        Ok(())
    };
    if let Some(store) = store {
        tokio::time::timeout(timeout, async {
            loop {
                if let Some(lease) =
                    Lease::acquire(store.clone(), job_lock_key(&reg.job_id)).await?
                {
                    break lease.run(scale).await;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .map_err(|_| NscaleError::WakeTimeout {
            job_id: reg.job_id.0.clone(),
            elapsed_secs: timeout.as_secs_f64(),
        })??;
    } else {
        scale.await?;
    }

    // Release semaphore early — other scale_up calls can proceed while
    // this task waits for the service to become healthy.
    drop(permit);

    // Phase 2: Wait for healthy endpoint, but cancel if all subscribers
    // have disconnected (i.e. every request handler was dropped).
    debug!(job_id = %reg.job_id, "waiting for healthy endpoint");
    tokio::select! {
        result = discovery.wait_for_healthy(&reg.service_name, timeout) => result,
        _ = wait_until_abandoned(notify) => {
            Err(NscaleError::WakeAbandoned { job_id: reg.job_id.0.clone() })
        }
    }
}

/// Resolves when all broadcast subscribers have disconnected, indicating that
/// no request handler is still waiting for the wake result.
///
/// Uses a polling approach with a brief grace period to avoid racing with new
/// subscribers that arrive between checks.
async fn wait_until_abandoned(notify: &tokio::sync::broadcast::Sender<WakeResult>) {
    // Initial grace period: let subscribers settle after spawn.
    tokio::time::sleep(Duration::from_secs(1)).await;
    loop {
        if notify.receiver_count() == 0 {
            // Double-check after a short pause to avoid a race with an
            // incoming request that is about to subscribe.
            tokio::time::sleep(Duration::from_millis(250)).await;
            if notify.receiver_count() == 0 {
                return;
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::{JobId, ServiceName};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, AtomicU32};

    /// Mock orchestrator that counts calls.
    struct MockOrchestrator {
        scale_up_calls: AtomicU32,
        current_count: AtomicU32,
        requested_count: AtomicU32,
        job_not_found_on_scale_up: AtomicBool,
        healthy_endpoint: Mutex<Option<Endpoint>>,
    }

    impl MockOrchestrator {
        fn new() -> Self {
            Self {
                scale_up_calls: AtomicU32::new(0),
                current_count: AtomicU32::new(0),
                requested_count: AtomicU32::new(0),
                job_not_found_on_scale_up: AtomicBool::new(false),
                healthy_endpoint: Mutex::new(Some(Endpoint::new("10.0.0.1", 8080))),
            }
        }

        fn set_job_not_found_on_scale_up(&self, enabled: bool) {
            self.job_not_found_on_scale_up
                .store(enabled, std::sync::atomic::Ordering::Relaxed);
        }
    }

    #[async_trait::async_trait]
    impl Orchestrator for MockOrchestrator {
        async fn scale_up(&self, _job_id: &JobId, _group: &str, count: u32) -> Result<()> {
            self.requested_count
                .store(count, std::sync::atomic::Ordering::Relaxed);
            self.scale_up_calls
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if self
                .job_not_found_on_scale_up
                .load(std::sync::atomic::Ordering::Relaxed)
            {
                return Err(NscaleError::JobNotFound("test-job".into()));
            }
            tokio::task::yield_now().await;
            Ok(())
        }
        async fn scale_down(&self, _job_id: &JobId, _group: &str) -> Result<()> {
            Ok(())
        }
        async fn scale_to(
            &self,
            _job_id: &JobId,
            _group: &str,
            _count: u32,
            _reason: &str,
        ) -> Result<()> {
            Ok(())
        }
        async fn get_job_count(&self, _job_id: &JobId, _group: &str) -> Result<u32> {
            Ok(self
                .current_count
                .load(std::sync::atomic::Ordering::Relaxed))
        }
        async fn get_healthy_endpoint(
            &self,
            _job_id: &JobId,
            _group: &str,
        ) -> Result<Option<Endpoint>> {
            Ok(self
                .healthy_endpoint
                .lock()
                .expect("healthy endpoint lock should succeed")
                .clone())
        }
    }

    /// Mock discovery that returns an endpoint immediately.
    struct MockDiscovery;
    struct MutableDiscovery(std::sync::Mutex<Vec<Endpoint>>);
    #[async_trait::async_trait]
    impl ServiceDiscovery for MutableDiscovery {
        async fn healthy_endpoints(&self, _: &ServiceName) -> Result<Vec<Endpoint>> {
            Ok(self.0.lock().unwrap().clone())
        }
        async fn register_fallback(&self, _: &ServiceName, _: &Endpoint) -> Result<()> {
            Ok(())
        }
        async fn deregister_fallback(&self, _: &ServiceName) -> Result<()> {
            Ok(())
        }
        async fn wait_for_healthy(&self, _: &ServiceName, _: Duration) -> Result<Endpoint> {
            Ok(self.0.lock().unwrap()[0].clone())
        }
    }

    #[async_trait::async_trait]
    impl ServiceDiscovery for MockDiscovery {
        async fn healthy_endpoints(&self, _: &ServiceName) -> Result<Vec<Endpoint>> {
            Ok(vec![Endpoint::new("10.0.0.1", 8080)])
        }

        async fn register_fallback(&self, _name: &ServiceName, _ep: &Endpoint) -> Result<()> {
            Ok(())
        }
        async fn deregister_fallback(&self, _name: &ServiceName) -> Result<()> {
            Ok(())
        }
        async fn wait_for_healthy(
            &self,
            _name: &ServiceName,
            _timeout: Duration,
        ) -> Result<Endpoint> {
            tokio::task::yield_now().await;
            Ok(Endpoint::new("10.0.0.1", 8080))
        }
    }

    fn test_registration() -> JobRegistration {
        JobRegistration {
            job_id: JobId("test-job".into()),
            service_name: ServiceName("test-svc".into()),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: None,
            traefik_routers: Vec::new(),
        }
    }

    fn multi_group_registration(job: &str, group: &str) -> JobRegistration {
        JobRegistration {
            job_id: JobId(job.into()),
            service_name: ServiceName(format!("{job}-{group}")),
            nomad_group: group.into(),
            scale_unit: Some(format!("{job}/{group}")),
            autoscaling: None,
            traefik_routers: Vec::new(),
        }
    }

    #[tokio::test]
    async fn two_groups_of_same_job_wake_independently() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch, disc, 10, Duration::from_secs(2));

        let alpha = multi_group_registration("api", "alpha");
        let beta = multi_group_registration("api", "beta");

        // Waking alpha must not mark beta ready — they are distinct scale units.
        coord.ensure_running(&alpha).await.unwrap();
        tokio::task::yield_now().await;
        assert!(coord.is_ready(&alpha.scale_unit_key()));
        assert!(!coord.is_ready(&beta.scale_unit_key()));

        // Marking alpha dormant leaves beta untouched (still not ready, no panic).
        coord.mark_dormant(&alpha.scale_unit_key());
        assert!(!coord.is_ready(&alpha.scale_unit_key()));
        assert!(!coord.is_ready(&beta.scale_unit_key()));
    }

    #[tokio::test]
    async fn test_single_wake_up() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch.clone(), disc, 10, Duration::from_secs(2));

        let reg = test_registration();
        let ep = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep.host, "10.0.0.1");
        assert_eq!(ep.port, 8080);
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
    }

    #[tokio::test]
    async fn test_coalescing_multiple_requests() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = Arc::new(WakeCoordinator::new(
            orch.clone(),
            disc,
            10,
            Duration::from_secs(2),
        ));

        let reg = test_registration();

        // Spawn 20 concurrent requests for the same job
        let mut handles = Vec::new();
        for _ in 0..20 {
            let coord = coord.clone();
            let reg = reg.clone();
            handles.push(tokio::spawn(
                async move { coord.ensure_running(&reg).await },
            ));
        }

        for handle in handles {
            let result = handle.await.unwrap();
            assert!(result.is_ok());
        }

        // Should have made exactly 1 scale-up call despite 20 requests
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
    }

    #[tokio::test]
    async fn test_ready_returns_cached() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch.clone(), disc, 10, Duration::from_secs(2));

        let reg = test_registration();

        // First call wakes up
        let _ = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );

        // Second call should hit cache
        let ep = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep.host, "10.0.0.1");
        // Still only 1 scale-up call
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
    }

    #[tokio::test]
    async fn test_mark_dormant_resets_state() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch.clone(), disc, 10, Duration::from_secs(2));

        let reg = test_registration();
        let ep = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep.host, "10.0.0.1");
        // Give the spawned wake task a chance to insert into the endpoint cache
        tokio::task::yield_now().await;
        assert!(coord.is_ready(&reg.scale_unit_key()));

        coord.mark_dormant(&reg.scale_unit_key());
        assert!(!coord.is_ready(&reg.scale_unit_key()));
    }

    #[tokio::test]
    async fn test_invalidate_clears_cache_triggers_rewake() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch.clone(), disc, 10, Duration::from_secs(2));

        let reg = test_registration();

        // First call wakes the job
        let ep = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep.host, "10.0.0.1");
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
        assert!(coord.is_ready(&reg.scale_unit_key()));

        // Invalidate clears the cache and resets state to dormant
        coord.invalidate(&reg.scale_unit_key());
        assert!(!coord.is_ready(&reg.scale_unit_key()));

        // Next ensure_running must trigger a fresh scale-up
        let ep2 = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep2.host, "10.0.0.1");
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            2
        );
    }

    #[tokio::test]
    async fn test_refresh_endpoint_updates_cached_endpoint() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MutableDiscovery(std::sync::Mutex::new(vec![
            Endpoint::new("10.0.0.1", 8080),
        ])));
        let coord = WakeCoordinator::new(orch.clone(), disc.clone(), 10, Duration::from_secs(2));

        let reg = test_registration();
        let current = coord.ensure_running(&reg).await.unwrap();

        *disc.0.lock().unwrap() = vec![Endpoint::new("10.0.0.2", 9090)];

        let refreshed = coord.refresh_endpoint(&reg, &current).await.unwrap();
        match refreshed {
            EndpointRefresh::Updated(endpoint) => {
                assert_eq!(endpoint.host, "10.0.0.2");
                assert_eq!(endpoint.port, 9090);
            }
            other => panic!("expected updated endpoint, got {other:?}"),
        }

        let cached = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(cached.host, "10.0.0.2");
        assert_eq!(cached.port, 9090);
    }

    #[tokio::test]
    async fn test_refresh_endpoint_missing_clears_cache() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MutableDiscovery(std::sync::Mutex::new(vec![
            Endpoint::new("10.0.0.1", 8080),
        ])));
        let coord = WakeCoordinator::new(orch.clone(), disc.clone(), 10, Duration::from_secs(2));

        let reg = test_registration();
        let current = coord.ensure_running(&reg).await.unwrap();

        disc.0.lock().unwrap().clear();

        let refreshed = coord.refresh_endpoint(&reg, &current).await.unwrap();
        assert!(matches!(refreshed, EndpointRefresh::Missing));
        assert!(!coord.is_ready(&reg.scale_unit_key()));
    }

    #[tokio::test]
    async fn test_job_not_found_propagates_through_wake_coordinator() {
        let orch = Arc::new(MockOrchestrator::new());
        orch.set_job_not_found_on_scale_up(true);
        let disc = Arc::new(MockDiscovery);
        let coord = WakeCoordinator::new(orch, disc, 10, Duration::from_secs(2));

        let reg = test_registration();
        let result = coord.ensure_running(&reg).await;

        assert!(matches!(result, Err(NscaleError::JobNotFound(job_id)) if job_id == "test-job"));
    }

    /// Mock discovery that delays health check to simulate slow container startup.
    struct SlowDiscovery {
        delay: Duration,
    }

    #[async_trait::async_trait]
    impl ServiceDiscovery for SlowDiscovery {
        async fn healthy_endpoints(&self, _: &ServiceName) -> Result<Vec<Endpoint>> {
            Ok(vec![Endpoint::new("10.0.0.1", 8080)])
        }

        async fn register_fallback(&self, _: &ServiceName, _: &Endpoint) -> Result<()> {
            Ok(())
        }
        async fn deregister_fallback(&self, _: &ServiceName) -> Result<()> {
            Ok(())
        }
        async fn wait_for_healthy(
            &self,
            _name: &ServiceName,
            _timeout: Duration,
        ) -> Result<Endpoint> {
            tokio::time::sleep(self.delay).await;
            Ok(Endpoint::new("10.0.0.1", 8080))
        }
    }

    #[tokio::test]
    async fn test_wake_abandoned_when_all_subscribers_disconnect() {
        let orch = Arc::new(MockOrchestrator::new());
        // Discovery takes 10s — long enough for us to drop all subscribers
        let disc = Arc::new(SlowDiscovery {
            delay: Duration::from_secs(10),
        });
        let coord = Arc::new(WakeCoordinator::new(
            orch.clone(),
            disc,
            10,
            Duration::from_secs(15),
        ));

        let reg = test_registration();

        // Spawn a subscriber that will be dropped after 200ms
        let coord_clone = coord.clone();
        let reg_clone = reg.clone();
        let handle = tokio::spawn(async move {
            // This will start the wake task, then we time out quickly
            tokio::time::timeout(
                Duration::from_millis(200),
                coord_clone.ensure_running(&reg_clone),
            )
            .await
        });

        // Let the wake task start and the first subscriber time out
        let result = handle.await.unwrap();
        assert!(result.is_err(), "subscriber should have timed out");

        // The wake task is now running with 0 subscribers.
        // Give it time to detect abandonment (1s grace + 250ms double-check)
        tokio::time::sleep(Duration::from_secs(2)).await;

        // State should be reverted to dormant (entry removed)
        assert!(
            !coord.is_ready(&reg.scale_unit_key()),
            "abandoned wake should revert to dormant"
        );

        // scale_up should have been called (we don't cancel the scale_up)
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
    }

    #[tokio::test]
    async fn test_semaphore_released_after_scale_up_not_after_health() {
        let orch = Arc::new(MockOrchestrator::new());
        // Discovery takes 2s
        let disc = Arc::new(SlowDiscovery {
            delay: Duration::from_millis(500),
        });
        let coord = Arc::new(WakeCoordinator::new(
            orch.clone(),
            disc,
            // Only 1 permit to prove it's released early
            1,
            Duration::from_secs(5),
        ));

        let reg1 = JobRegistration {
            job_id: JobId("job-1".into()),
            service_name: ServiceName("svc-1".into()),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: None,
            traefik_routers: Vec::new(),
        };
        let reg2 = JobRegistration {
            job_id: JobId("job-2".into()),
            service_name: ServiceName("svc-2".into()),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: None,
            traefik_routers: Vec::new(),
        };

        // Start both wakes concurrently with only 1 semaphore permit.
        // If the semaphore is held during wait_for_healthy, the second
        // wake would be blocked for the full first wake duration.
        let c1 = coord.clone();
        let r1 = reg1.clone();
        let h1 = tokio::spawn(async move { c1.ensure_running(&r1).await });

        let c2 = coord.clone();
        let r2 = reg2.clone();
        let h2 = tokio::spawn(async move { c2.ensure_running(&r2).await });

        // Both should complete within ~1s (overlapping health waits),
        // NOT 2× sequential = 2s.
        let deadline = Duration::from_millis(1500);
        let (r1, r2) =
            tokio::time::timeout(deadline, async { (h1.await.unwrap(), h2.await.unwrap()) })
                .await
                .expect(
                    "both wakes should complete within the deadline (semaphore released early)",
                );

        assert!(r1.is_ok());
        assert!(r2.is_ok());
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            2
        );
    }
    #[tokio::test]
    async fn restart_and_replica_stop_preserve_running_count() {
        let orch = Arc::new(MockOrchestrator::new());
        orch.current_count
            .store(3, std::sync::atomic::Ordering::Relaxed);
        let coord = WakeCoordinator::new(
            orch.clone(),
            Arc::new(MockDiscovery),
            10,
            Duration::from_secs(2),
        );
        let reg = test_registration();
        coord.ensure_running(&reg).await.unwrap();
        coord.mark_dormant(&reg.scale_unit_key());
        coord.ensure_running(&reg).await.unwrap();
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            0
        );
    }

    #[tokio::test]
    async fn cold_wake_uses_policy_minimum() {
        let orch = Arc::new(MockOrchestrator::new());
        let coord = WakeCoordinator::new(
            orch.clone(),
            Arc::new(MockDiscovery),
            10,
            Duration::from_secs(2),
        );
        let mut reg = test_registration();
        reg.autoscaling = Some(
            serde_json::from_str(
                r#"{"min_count":3,"max_count":5,"target_requests_per_second_per_instance":10}"#,
            )
            .unwrap(),
        );
        coord.ensure_running(&reg).await.unwrap();
        assert_eq!(
            orch.requested_count
                .load(std::sync::atomic::Ordering::Relaxed),
            3
        );
    }

    #[tokio::test]
    async fn round_robin_refreshes_after_scale_up_and_removal() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MutableDiscovery(std::sync::Mutex::new(vec![
            Endpoint::new("a", 80),
            Endpoint::new("b", 80),
        ])));
        let coord = WakeCoordinator::new(orch, disc.clone(), 10, Duration::from_secs(2));
        let reg = test_registration();
        for expected in ["a", "b", "a", "b"] {
            assert_eq!(coord.ensure_running(&reg).await.unwrap().host, expected);
        }
        *disc.0.lock().unwrap() = vec![Endpoint::new("c", 80), Endpoint::new("d", 80)];
        // Expire the pool deterministically without sleeping.
        coord
            .service_endpoints
            .get_mut(&(reg.scale_unit_key().0, reg.service_name.0.clone()))
            .unwrap()
            .refreshed -= Duration::from_secs(3);
        for expected in ["c", "d", "c", "d"] {
            assert_eq!(coord.ensure_running(&reg).await.unwrap().host, expected);
        }
    }

    #[tokio::test]
    async fn services_in_one_group_keep_separate_ports() {
        let orch = Arc::new(MockOrchestrator::new());
        let disc = Arc::new(MutableDiscovery(std::sync::Mutex::new(vec![
            Endpoint::new("a", 80),
        ])));
        let coord = WakeCoordinator::new(orch.clone(), disc.clone(), 10, Duration::from_secs(2));
        let first = test_registration();
        let mut second = first.clone();
        second.service_name = ServiceName("second".into());
        assert_eq!(coord.ensure_running(&first).await.unwrap().port, 80);
        *disc.0.lock().unwrap() = vec![Endpoint::new("a", 90)];
        assert_eq!(coord.ensure_running(&second).await.unwrap().port, 90);
        assert_eq!(coord.ensure_running(&first).await.unwrap().port, 80);
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            1
        );
    }

    #[test]
    fn refreshed_pool_handles_reordering_additions_and_removal() {
        let mut pool = EndpointPool {
            endpoints: vec![Endpoint::new("a", 80), Endpoint::new("b", 80)],
            next: 0,
            refreshed: tokio::time::Instant::now(),
        };
        assert_eq!(pool.select().unwrap().host, "a");
        pool.refresh(vec![
            Endpoint::new("c", 80),
            Endpoint::new("b", 80),
            Endpoint::new("a", 80),
        ]);
        assert_eq!(
            pool.select().unwrap().host,
            "b",
            "preserve next backend despite reordered discovery"
        );
        pool.refresh(vec![Endpoint::new("c", 80), Endpoint::new("d", 80)]);
        assert_eq!(
            pool.select().unwrap().host,
            "c",
            "removed next backend must be skipped"
        );
        assert_eq!(pool.select().unwrap().host, "d");
        pool.refresh(vec![]);
        assert!(pool.select().is_none());
    }
    #[tokio::test]
    async fn refresh_preserves_round_robin_for_sparse_requests() {
        let disc = Arc::new(MutableDiscovery(std::sync::Mutex::new(vec![
            Endpoint::new("a", 80),
            Endpoint::new("b", 80),
            Endpoint::new("c", 80),
        ])));
        let coord = WakeCoordinator::new(
            Arc::new(MockOrchestrator::new()),
            disc,
            10,
            Duration::from_secs(2),
        );
        let reg = test_registration();
        let mut chosen = std::collections::BTreeSet::new();
        for _ in 0..6 {
            chosen.insert(coord.ensure_running(&reg).await.unwrap().host);
            coord
                .service_endpoints
                .get_mut(&(reg.scale_unit_key().0, reg.service_name.0.clone()))
                .unwrap()
                .refreshed -= Duration::from_secs(3);
        }
        assert_eq!(
            chosen.len(),
            3,
            "requests spanning pool refreshes must use all three healthy backends; got {chosen:?}"
        );
    }
}
