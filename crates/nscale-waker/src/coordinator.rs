use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use tracing::{debug, error, info, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{Endpoint, JobId, JobRegistration};
use nscale_core::traits::{Orchestrator, ServiceDiscovery};

use crate::state::{STATE_DORMANT, STATE_READY, STATE_WAKING, WakeResult, WakeState};

/// Coordinates wake-ups with request coalescing.
/// Multiple concurrent requests for the same dormant job result in a single scale-up call.
pub struct WakeCoordinator {
    jobs: Arc<DashMap<String, Arc<WakeState>>>,
    orchestrator: Arc<dyn Orchestrator>,
    discovery: Arc<dyn ServiceDiscovery>,
    wake_semaphore: Arc<tokio::sync::Semaphore>,
    wake_timeout: Duration,
    /// Cache of endpoint for ready jobs.
    endpoints: Arc<DashMap<String, Endpoint>>,
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
            endpoints: Arc::new(DashMap::new()),
        }
    }

    /// Ensure a job is running and return its endpoint.
    /// If dormant, triggers a scale-up and coalesces concurrent requests.
    /// If already waking, subscribes to the existing wake-up broadcast.
    /// If ready, returns the cached endpoint immediately.
    #[instrument(skip(self, reg), fields(job_id = %reg.job_id))]
    pub async fn ensure_running(&self, reg: &JobRegistration) -> Result<Endpoint> {
        let job_key = reg.job_id.0.clone();

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
                        .get_healthy_endpoint(&reg.job_id)
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
                    let mut rx = state.notify.subscribe();

                    return match tokio::time::timeout(self.wake_timeout, rx.recv()).await {
                        Ok(Ok(WakeResult::Ready(ep))) => Ok(ep),
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
                        let mut rx = state.notify.subscribe();

                        // Spawn the actual wake task
                        let orchestrator = self.orchestrator.clone();
                        let discovery = self.discovery.clone();
                        let semaphore = self.wake_semaphore.clone();
                        let timeout = self.wake_timeout;
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
                            )
                            .await;

                            match result {
                                Ok(endpoint) => {
                                    info!(
                                        job_id = %reg_clone.job_id,
                                        endpoint = %endpoint,
                                        "job woke up successfully"
                                    );
                                    endpoints.insert(reg_clone.job_id.0.clone(), endpoint.clone());
                                    state_clone.set_ready();
                                    let _ = notify.send(WakeResult::Ready(endpoint));
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
                                    jobs.remove(&reg_clone.job_id.0);
                                }
                            }
                        });

                        // Wait for the result
                        return match tokio::time::timeout(self.wake_timeout, rx.recv()).await {
                            Ok(Ok(WakeResult::Ready(ep))) => Ok(ep),
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

    /// Mark a job as dormant (called after scale-down).
    pub fn mark_dormant(&self, job_id: &JobId) {
        self.endpoints.remove(&job_id.0);
        if let Some(state) = self.jobs.get(&job_id.0) {
            state.set_dormant();
        }
        self.jobs.remove(&job_id.0);
    }

    /// Invalidate the cached endpoint for a job, forcing the next
    /// `ensure_running` call to re-discover (and re-wake if needed).
    /// Called when the proxy detects a backend connection failure.
    pub fn invalidate(&self, job_id: &JobId) {
        self.endpoints.remove(&job_id.0);
        if let Some(state) = self.jobs.get(&job_id.0) {
            state.set_dormant();
        }
        self.jobs.remove(&job_id.0);
        info!(job_id = %job_id, "invalidated stale endpoint cache");
    }

    /// Check if a job is currently in the Ready state.
    pub fn is_ready(&self, job_id: &JobId) -> bool {
        self.endpoints.contains_key(&job_id.0)
    }
}

async fn run_wake_task(
    orchestrator: &dyn Orchestrator,
    discovery: &dyn ServiceDiscovery,
    semaphore: &tokio::sync::Semaphore,
    reg: &JobRegistration,
    timeout: Duration,
) -> Result<Endpoint> {
    // Acquire semaphore to bound concurrent Nomad API calls
    let _permit = semaphore
        .acquire()
        .await
        .map_err(|_| NscaleError::Nomad("wake semaphore closed".to_string()))?;

    debug!(job_id = %reg.job_id, group = %reg.nomad_group, "scaling up job");
    orchestrator
        .scale_up(&reg.job_id, &reg.nomad_group, 1)
        .await?;

    debug!(job_id = %reg.job_id, "waiting for healthy endpoint");
    let endpoint = discovery
        .wait_for_healthy(&reg.service_name, timeout)
        .await?;

    Ok(endpoint)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::ServiceName;
    use std::sync::atomic::AtomicU32;

    /// Mock orchestrator that counts calls.
    struct MockOrchestrator {
        scale_up_calls: AtomicU32,
    }

    impl MockOrchestrator {
        fn new() -> Self {
            Self {
                scale_up_calls: AtomicU32::new(0),
            }
        }
    }

    #[async_trait::async_trait]
    impl Orchestrator for MockOrchestrator {
        async fn scale_up(&self, _job_id: &JobId, _group: &str, _count: u32) -> Result<()> {
            self.scale_up_calls
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            tokio::task::yield_now().await;
            Ok(())
        }
        async fn scale_down(&self, _job_id: &JobId, _group: &str) -> Result<()> {
            Ok(())
        }
        async fn get_job_count(&self, _job_id: &JobId, _group: &str) -> Result<u32> {
            Ok(1)
        }
        async fn get_healthy_endpoint(&self, _job_id: &JobId) -> Result<Option<Endpoint>> {
            Ok(Some(Endpoint::new("10.0.0.1", 8080)))
        }
    }

    /// Mock discovery that returns an endpoint immediately.
    struct MockDiscovery;

    #[async_trait::async_trait]
    impl ServiceDiscovery for MockDiscovery {
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
        }
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
        assert!(coord.is_ready(&reg.job_id));

        coord.mark_dormant(&reg.job_id);
        assert!(!coord.is_ready(&reg.job_id));
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
        assert!(coord.is_ready(&reg.job_id));

        // Invalidate clears the cache and resets state to dormant
        coord.invalidate(&reg.job_id);
        assert!(!coord.is_ready(&reg.job_id));

        // Next ensure_running must trigger a fresh scale-up
        let ep2 = coord.ensure_running(&reg).await.unwrap();
        assert_eq!(ep2.host, "10.0.0.1");
        assert_eq!(
            orch.scale_up_calls
                .load(std::sync::atomic::Ordering::Relaxed),
            2
        );
    }
}
