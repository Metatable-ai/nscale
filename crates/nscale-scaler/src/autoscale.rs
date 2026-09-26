use nscale_core::lease::{Lease, cooldown_key, job_lock_key};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

use nscale_core::error::{NscaleError, Result};
use nscale_core::inflight::InFlightTracker;
use nscale_core::job::{JobAutoscalingPolicy, JobRegistration};
use nscale_core::traits::{ActivityStore, Orchestrator};
use nscale_store::registry::JobRegistry;
use tokio::time;
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, instrument, warn};

use crate::autoscale_policy::{AutoscaleDirection, decide_autoscale};
use crate::metrics_provider::MetricsProvider;

const AUTOSCALE_LOCK_KEY: &str = "nscale:lock:autoscale";
const AUTOSCALE_INTERVAL: Duration = Duration::from_secs(30);
const AUTOSCALE_DECISION_WINDOW: Duration = Duration::from_secs(60);
const AUTOSCALE_COOLDOWN: Duration = Duration::from_secs(120);
const DEPLOYMENT_BACKOFF: Duration = Duration::from_secs(30);
const AUTOSCALE_DECISIONS_METRIC: &str = "nscale_autoscale_decisions_total";
const AUTOSCALE_SKIPS_METRIC: &str = "nscale_autoscale_skips_total";
const AUTOSCALE_CURRENT_COUNT_METRIC: &str = "nscale_autoscale_current_count";
const AUTOSCALE_DESIRED_COUNT_METRIC: &str = "nscale_autoscale_desired_count";

pub struct AutoscaleController {
    orchestrator: Arc<dyn Orchestrator>,
    store: Arc<dyn ActivityStore>,
    registry: Arc<JobRegistry>,
    metrics: Arc<dyn MetricsProvider>,
    in_flight: InFlightTracker,
    cancel: CancellationToken,
}

impl AutoscaleController {
    pub fn new(
        orchestrator: Arc<dyn Orchestrator>,
        store: Arc<dyn ActivityStore>,
        registry: Arc<JobRegistry>,
        metrics: Arc<dyn MetricsProvider>,
        in_flight: InFlightTracker,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            orchestrator,
            store,
            registry,
            metrics,
            in_flight,
            cancel,
        }
    }

    pub async fn run(self) {
        info!(
            interval_secs = AUTOSCALE_INTERVAL.as_secs(),
            "starting autoscale controller"
        );
        let mut ticker = time::interval(AUTOSCALE_INTERVAL);
        ticker.set_missed_tick_behavior(time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    info!("autoscale controller shutting down");
                    return;
                }
                _ = ticker.tick() => {
                    if let Err(err) = self.tick().await {
                        error!(error = %err, "autoscale tick failed");
                    }
                }
            }
        }
    }

    #[instrument(skip(self))]
    async fn tick(&self) -> Result<()> {
        let Some(lease) = Lease::acquire(self.store.clone(), AUTOSCALE_LOCK_KEY.into()).await?
        else {
            return Ok(());
        };
        lease
            .run(async {
                let registrations =
                    unique_autoscaling_registrations(self.registry.list_all().await?);
                for registration in registrations {
                    if self.cancel.is_cancelled() {
                        break;
                    }
                    self.evaluate_registration(&registration).await;
                }

                Ok(())
            })
            .await
    }

    async fn evaluate_registration(&self, registrations: &[JobRegistration]) {
        let key = job_lock_key(&registrations[0].job_id);
        match Lease::acquire(self.store.clone(), key).await {
            Ok(Some(lease)) => {
                if let Err(error) = lease
                    .run(async {
                        self.evaluate_locked(registrations).await;
                        Ok(())
                    })
                    .await
                {
                    warn!(%error, "autoscale ownership lost");
                }
            }
            Ok(None) => {}
            Err(error) => warn!(%error, "autoscale lock unavailable"),
        }
    }

    async fn evaluate_locked(&self, registrations: &[JobRegistration]) {
        let registration = &registrations[0];
        let Some(policy) = registration.autoscaling.as_ref() else {
            return;
        };
        if !policy.enabled {
            record_skip(registration, "disabled");
            return;
        }
        if let Err(err) = policy.validate() {
            warn!(job_id = %registration.job_id, error = %err, "invalid autoscaling policy, skipping");
            record_skip(registration, "invalid-policy");
            return;
        }

        // Cooldown is stored in the shared activity store (Redis) so that it is
        // honored across all HA replicas, not just the instance that scaled.
        let cooldown_key = cooldown_key(&registration.job_id, &registration.nomad_group);
        match self.store.in_cooldown(&cooldown_key).await {
            Ok(true) => {
                debug!(job_id = %registration.job_id, "autoscaling cooldown active, skipping");
                record_skip(registration, "cooldown");
                return;
            }
            Ok(false) => {}
            Err(err) => {
                warn!(job_id = %registration.job_id, error = %err, "failed to check autoscaling cooldown, skipping");
                record_skip(registration, "cooldown-error");
                return;
            }
        }

        let current_count = match self
            .orchestrator
            .get_job_count(&registration.job_id, &registration.nomad_group)
            .await
        {
            Ok(count) => count,
            Err(err) => {
                warn!(job_id = %registration.job_id, error = %err, "failed to get current job count for autoscaling");
                record_skip(registration, "count-error");
                return;
            }
        };
        metrics::gauge!(
            AUTOSCALE_CURRENT_COUNT_METRIC,
            "job_id" => registration.job_id.0.clone(),
            "service_name" => registration.service_name.0.clone(),
        )
        .set(current_count as f64);

        if current_count == 0 {
            debug!(job_id = %registration.job_id, "job is dormant; autoscaler does not wake from zero");
            record_skip(registration, "dormant");
            return;
        }

        let metrics = match self
            .metrics
            .group_snapshot(registrations, policy_decision_window(policy))
            .await
        {
            Ok(metrics) => metrics,
            Err(err) => {
                warn!(job_id = %registration.job_id, error = %err, "failed to collect autoscaling metrics");
                record_skip(registration, "metrics-error");
                return;
            }
        };

        let downscale_blocked = self
            .in_flight
            .has_in_flight(&registration.scale_unit_key().0)
            || !matches!(
                self.store
                    .active_requests(&registration.scale_unit_key())
                    .await,
                Ok(0)
            );
        let decision = decide_autoscale(policy, current_count, &metrics, downscale_blocked);
        if decision.direction == AutoscaleDirection::None {
            debug!(job_id = %registration.job_id, reason = %decision.reason, "autoscale decision made no change");
            record_skip(registration, decision.reason.as_str());
            return;
        }
        metrics::gauge!(
            AUTOSCALE_DESIRED_COUNT_METRIC,
            "job_id" => registration.job_id.0.clone(),
            "service_name" => registration.service_name.0.clone(),
        )
        .set(decision.desired_count as f64);

        let reason = format!("nscale: autoscale {}", decision.reason);
        match self
            .orchestrator
            .scale_from(
                &registration.job_id,
                &registration.nomad_group,
                current_count,
                decision.desired_count,
                &reason,
            )
            .await
        {
            Ok(()) => {
                let direction = match decision.direction {
                    AutoscaleDirection::Up => "up",
                    AutoscaleDirection::Down => "down",
                    AutoscaleDirection::None => "none",
                };
                metrics::counter!(
                    AUTOSCALE_DECISIONS_METRIC,
                    "job_id" => registration.job_id.0.clone(),
                    "service_name" => registration.service_name.0.clone(),
                    "direction" => direction,
                    "reason" => decision.reason.clone(),
                )
                .increment(1);
                info!(
                    job_id = %registration.job_id,
                    group = %registration.nomad_group,
                    current_count,
                    desired_count = decision.desired_count,
                    reason = %decision.reason,
                    "autoscaled job"
                );
                self.store
                    .set_cooldown(&cooldown_key, policy_cooldown(policy))
                    .await
                    .unwrap_or_else(|err| {
                        warn!(job_id = %registration.job_id, error = %err, "failed to record autoscaling cooldown");
                    });
            }
            Err(NscaleError::DeploymentInProgress { .. }) => {
                info!(job_id = %registration.job_id, "autoscale blocked by active deployment, backing off");
                record_skip(registration, "deployment-in-progress");
                self.store
                    .set_cooldown(&cooldown_key, DEPLOYMENT_BACKOFF)
                    .await
                    .unwrap_or_else(|err| {
                        warn!(job_id = %registration.job_id, error = %err, "failed to record autoscaling deployment backoff");
                    });
            }
            Err(err) => {
                error!(job_id = %registration.job_id, error = %err, "failed to autoscale job");
                record_skip(registration, "scale-error");
            }
        }
    }
}

fn record_skip(registration: &JobRegistration, reason: &str) {
    metrics::counter!(
        AUTOSCALE_SKIPS_METRIC,
        "job_id" => registration.job_id.0.clone(),
        "service_name" => registration.service_name.0.clone(),
        "reason" => reason.to_string(),
    )
    .increment(1);
}

fn unique_autoscaling_registrations(
    mut registrations: Vec<JobRegistration>,
) -> Vec<Vec<JobRegistration>> {
    registrations.sort_by(|a, b| {
        (&a.job_id.0, &a.nomad_group, &a.service_name.0).cmp(&(
            &b.job_id.0,
            &b.nomad_group,
            &b.service_name.0,
        ))
    });
    // Key by (job_id, nomad_group): a job may legitimately have several task
    // groups, each scaled independently. Only a genuinely divergent policy for
    // the *same* (job, group) is treated as a conflict.
    let mut by_group: BTreeMap<(String, String), Vec<JobRegistration>> = BTreeMap::new();
    let mut conflicts = BTreeSet::new();

    for registration in registrations {
        let key = (
            registration.job_id.0.clone(),
            registration.nomad_group.clone(),
        );
        if let Some(existing) = by_group.get_mut(&key) {
            if existing[0].autoscaling != registration.autoscaling {
                conflicts.insert(key);
            }
            if !existing
                .iter()
                .any(|r| r.service_name == registration.service_name)
            {
                existing.push(registration);
            }
        } else {
            by_group.insert(key, vec![registration]);
        }
    }

    by_group
        .into_iter()
        .filter_map(|(key, registration)| {
            if conflicts.contains(&key) {
                warn!(
                    job_id = key.0,
                    group = key.1,
                    "conflicting autoscaling policies for job group, skipping autoscale evaluation"
                );
                None
            } else if registration[0].autoscaling.is_some() {
                Some(registration)
            } else {
                None
            }
        })
        .collect()
}

fn policy_decision_window(policy: &JobAutoscalingPolicy) -> Duration {
    policy.decision_window(AUTOSCALE_DECISION_WINDOW)
}

fn policy_cooldown(policy: &JobAutoscalingPolicy) -> Duration {
    policy.cooldown(AUTOSCALE_COOLDOWN)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nscale_core::job::JobAutoscalingPolicy;

    fn policy() -> JobAutoscalingPolicy {
        JobAutoscalingPolicy {
            enabled: true,
            min_count: 1,
            max_count: 3,
            scale_to_zero: true,
            scale_up_step: 1,
            scale_down_step: 1,
            target_requests_per_second_per_instance: Some(1.0),
            target_p95_latency_ms: None,
            max_error_rate: None,
            cooldown_secs: None,
            decision_window_secs: None,
        }
    }

    #[test]
    fn policy_decision_window_uses_default_without_override() {
        assert_eq!(policy_decision_window(&policy()), Duration::from_secs(60));
    }

    #[test]
    fn policy_decision_window_uses_per_job_override() {
        let mut policy = policy();
        policy.decision_window_secs = Some(30);

        assert_eq!(policy_decision_window(&policy), Duration::from_secs(30));
    }

    #[test]
    fn policy_cooldown_uses_per_job_override() {
        let mut policy = policy();
        policy.cooldown_secs = Some(20);

        assert_eq!(policy_cooldown(&policy), Duration::from_secs(20));
    }

    #[test]
    fn autoscale_metric_names_are_stable() {
        assert_eq!(
            AUTOSCALE_DECISIONS_METRIC,
            "nscale_autoscale_decisions_total"
        );
        assert_eq!(AUTOSCALE_SKIPS_METRIC, "nscale_autoscale_skips_total");
        assert_eq!(
            AUTOSCALE_CURRENT_COUNT_METRIC,
            "nscale_autoscale_current_count"
        );
        assert_eq!(
            AUTOSCALE_DESIRED_COUNT_METRIC,
            "nscale_autoscale_desired_count"
        );
    }

    #[test]
    fn unique_autoscaling_registrations_rejects_conflicting_policies_for_same_job() {
        use nscale_core::job::{JobId, ServiceName};

        let mut first = JobRegistration {
            job_id: JobId("api".into()),
            service_name: ServiceName("api-a".into()),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: Some(policy()),
            traefik_routers: Vec::new(),
        };
        let mut second = first.clone();
        second.service_name = ServiceName("api-b".into());
        second.autoscaling.as_mut().unwrap().max_count = 9;

        let unique = unique_autoscaling_registrations(vec![first.clone(), second]);
        assert!(unique.is_empty());

        let mut unconfigured_sibling = first.clone();
        unconfigured_sibling.service_name = ServiceName("api-unconfigured".into());
        unconfigured_sibling.autoscaling = None;
        assert!(
            unique_autoscaling_registrations(vec![first.clone(), unconfigured_sibling]).is_empty()
        );

        first.service_name = ServiceName("api-c".into());
        let unique = unique_autoscaling_registrations(vec![first.clone(), first]);
        assert_eq!(unique.len(), 1);
    }

    #[test]
    fn unique_autoscaling_registrations_keeps_distinct_groups_for_same_job() {
        use nscale_core::job::{JobId, ServiceName};

        let web = JobRegistration {
            job_id: JobId("api".into()),
            service_name: ServiceName("api-web".into()),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: Some(policy()),
            traefik_routers: Vec::new(),
        };
        let mut worker = web.clone();
        worker.service_name = ServiceName("api-worker".into());
        worker.nomad_group = "worker".into();

        let unique = unique_autoscaling_registrations(vec![web, worker]);
        assert_eq!(unique.len(), 2);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires isolated Redis"]
    async fn sibling_groups_are_all_evaluated() {
        use nscale_core::job::{Endpoint, JobId};
        struct Counts(std::sync::Mutex<Vec<String>>);
        #[async_trait::async_trait]
        impl Orchestrator for Counts {
            async fn scale_up(&self, _: &JobId, _: &str, _: u32) -> Result<()> {
                Ok(())
            }
            async fn scale_down(&self, _: &JobId, _: &str) -> Result<()> {
                Ok(())
            }
            async fn scale_to(&self, _: &JobId, _: &str, _: u32, _: &str) -> Result<()> {
                Ok(())
            }
            async fn get_job_count(&self, _: &JobId, group: &str) -> Result<u32> {
                self.0.lock().unwrap().push(group.into());
                Ok(1)
            }
            async fn get_healthy_endpoint(&self, _: &JobId, _: &str) -> Result<Option<Endpoint>> {
                Ok(None)
            }
        }
        struct Idle;
        #[async_trait::async_trait]
        impl MetricsProvider for Idle {
            fn name(&self) -> &'static str {
                "idle"
            }
            async fn snapshot(
                &self,
                _: &JobRegistration,
                _: Duration,
            ) -> Result<crate::autoscale_policy::MetricSnapshot> {
                Ok(crate::autoscale_policy::MetricSnapshot {
                    request_rate_rps: Some(0.0),
                    ..Default::default()
                })
            }
        }
        let store = Arc::new(
            nscale_store::activity::RedisActivityStore::new(
                &std::env::var("NSCALE_TEST_REDIS_URL").unwrap(),
            )
            .await
            .unwrap(),
        );
        let registry = Arc::new(JobRegistry::new(store.client().clone()));
        let job = nscale_core::lease::unique_token();
        for group in ["alpha", "beta"] {
            registry
                .register(&JobRegistration {
                    job_id: job.clone().into(),
                    service_name: format!("{job}-{group}").into(),
                    nomad_group: group.into(),
                    scale_unit: Some(format!("{job}/{group}")),
                    autoscaling: Some(policy()),
                    traefik_routers: vec![],
                })
                .await
                .unwrap();
        }
        let counts = Arc::new(Counts(std::sync::Mutex::new(vec![])));
        let controller = AutoscaleController::new(
            counts.clone(),
            store,
            registry.clone(),
            Arc::new(Idle),
            InFlightTracker::new(),
            CancellationToken::new(),
        );
        for _ in 0..20 {
            controller.tick().await.unwrap();
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        registry.deregister(&job.into()).await.unwrap();
        let seen = counts.0.lock().unwrap();
        let alpha = seen.iter().filter(|g| g.as_str() == "alpha").count();
        let beta = seen.iter().filter(|g| g.as_str() == "beta").count();
        assert_eq!(alpha, 20);
        assert_eq!(
            beta, alpha,
            "every group must be evaluated; alpha={alpha}, beta={beta}"
        );
    }
}
