use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
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
const AUTOSCALE_LOCK_TTL: Duration = Duration::from_secs(35);
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
    cooldown_until: DashMap<String, Instant>,
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
            cooldown_until: DashMap::new(),
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
        if !self
            .store
            .try_acquire_lock(AUTOSCALE_LOCK_KEY, AUTOSCALE_LOCK_TTL)
            .await?
        {
            debug!("another instance holds the autoscale lock, skipping");
            return Ok(());
        }

        let _lock_guard = LockGuard {
            store: self.store.clone(),
            key: AUTOSCALE_LOCK_KEY,
        };

        let registrations = unique_autoscaling_registrations(self.registry.list_all().await?);
        for registration in registrations {
            if self.cancel.is_cancelled() {
                break;
            }
            self.evaluate_registration(&registration).await;
        }

        Ok(())
    }

    async fn evaluate_registration(&self, registration: &JobRegistration) {
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

        if let Some(entry) = self.cooldown_until.get(&registration.job_id.0) {
            if Instant::now() < *entry {
                debug!(job_id = %registration.job_id, "autoscaling cooldown active, skipping");
                record_skip(registration, "cooldown");
                return;
            }
            drop(entry);
            self.cooldown_until.remove(&registration.job_id.0);
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
            .snapshot(registration, policy_decision_window(policy))
            .await
        {
            Ok(metrics) => metrics,
            Err(err) => {
                warn!(job_id = %registration.job_id, error = %err, "failed to collect autoscaling metrics");
                record_skip(registration, "metrics-error");
                return;
            }
        };

        let downscale_blocked = self.in_flight.has_in_flight(&registration.job_id.0);
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
            .scale_to(
                &registration.job_id,
                &registration.nomad_group,
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
                self.cooldown_until.insert(
                    registration.job_id.0.clone(),
                    Instant::now() + policy_cooldown(policy),
                );
            }
            Err(NscaleError::DeploymentInProgress { .. }) => {
                info!(job_id = %registration.job_id, "autoscale blocked by active deployment, backing off");
                record_skip(registration, "deployment-in-progress");
                self.cooldown_until.insert(
                    registration.job_id.0.clone(),
                    Instant::now() + DEPLOYMENT_BACKOFF,
                );
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

fn unique_autoscaling_registrations(registrations: Vec<JobRegistration>) -> Vec<JobRegistration> {
    let mut by_job: BTreeMap<String, JobRegistration> = BTreeMap::new();
    let mut conflicts = BTreeSet::new();

    for registration in registrations {
        if registration.autoscaling.is_none() {
            continue;
        }

        let key = registration.job_id.0.clone();
        if let Some(existing) = by_job.get(&key) {
            if existing.autoscaling != registration.autoscaling
                || existing.nomad_group != registration.nomad_group
            {
                conflicts.insert(key);
            }
        } else {
            by_job.insert(key, registration);
        }
    }

    by_job
        .into_iter()
        .filter_map(|(job_id, registration)| {
            if conflicts.contains(&job_id) {
                warn!(
                    job_id,
                    "conflicting autoscaling policies for job, skipping autoscale evaluation"
                );
                None
            } else {
                Some(registration)
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

struct LockGuard {
    store: Arc<dyn ActivityStore>,
    key: &'static str,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let store = self.store.clone();
        let key = self.key;
        tokio::spawn(async move {
            if let Err(err) = store.release_lock(key).await {
                warn!(error = %err, "failed to release autoscale lock");
            }
        });
    }
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
            autoscaling: Some(policy()),
            traefik_routers: Vec::new(),
        };
        let mut second = first.clone();
        second.service_name = ServiceName("api-b".into());
        second.autoscaling.as_mut().unwrap().max_count = 9;

        let unique = unique_autoscaling_registrations(vec![first.clone(), second]);
        assert!(unique.is_empty());

        first.service_name = ServiceName("api-c".into());
        let unique = unique_autoscaling_registrations(vec![first.clone(), first]);
        assert_eq!(unique.len(), 1);
    }
}
