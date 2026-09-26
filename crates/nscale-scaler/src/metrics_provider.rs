use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use nscale_core::error::Result;
use nscale_core::job::JobRegistration;
use tracing::warn;

use crate::autoscale_policy::MetricSnapshot;

#[async_trait]
pub trait MetricsProvider: Send + Sync {
    async fn snapshot(
        &self,
        registration: &JobRegistration,
        window: Duration,
    ) -> Result<MetricSnapshot>;

    /// Combine known observations and separately track gaps. Partial rates are
    /// lower bounds; latency/error use the worst known service signal.
    async fn group_snapshot(
        &self,
        registrations: &[JobRegistration],
        window: Duration,
    ) -> Result<MetricSnapshot> {
        let mut combined = MetricSnapshot::default();
        for reg in registrations {
            let sample = match self.snapshot(reg, window).await {
                Ok(sample) => sample,
                Err(error) => {
                    warn!(service = %reg.service_name, %error, "group service metrics unavailable");
                    MetricSnapshot::default()
                }
            };
            combined.incomplete.request_rate |=
                sample.request_rate_rps.is_none() || sample.incomplete.request_rate;
            combined.incomplete.latency |=
                sample.p95_latency_ms.is_none() || sample.incomplete.latency;
            combined.incomplete.error_rate |=
                sample.error_rate.is_none() || sample.incomplete.error_rate;
            if let Some(rate) = sample.request_rate_rps {
                combined.request_rate_rps = Some(combined.request_rate_rps.unwrap_or(0.0) + rate);
            }
            if let Some(value) = sample.p95_latency_ms {
                combined.p95_latency_ms = Some(combined.p95_latency_ms.unwrap_or(0.0).max(value));
            }
            if let Some(value) = sample.error_rate {
                combined.error_rate = Some(combined.error_rate.unwrap_or(0.0).max(value));
            }
            combined.in_flight = match (combined.in_flight, sample.in_flight) {
                (Some(a), Some(b)) => Some(a + b),
                (a, b) => a.or(b),
            };
        }
        Ok(combined)
    }

    /// Stable identifier used for diagnostics and provider-ordering tests.
    fn name(&self) -> &'static str;
}

pub struct CompositeMetricsProvider {
    providers: Vec<Arc<dyn MetricsProvider>>,
}

impl CompositeMetricsProvider {
    pub fn new(providers: Vec<Arc<dyn MetricsProvider>>) -> Self {
        Self { providers }
    }
}

#[async_trait]
impl MetricsProvider for CompositeMetricsProvider {
    fn name(&self) -> &'static str {
        "composite"
    }

    async fn snapshot(
        &self,
        registration: &JobRegistration,
        window: Duration,
    ) -> Result<MetricSnapshot> {
        let mut combined = MetricSnapshot::default();
        let mut saw_success = false;
        let mut last_error = None;

        for provider in &self.providers {
            match provider.snapshot(registration, window).await {
                Ok(snapshot) => {
                    saw_success = true;
                    if combined.request_rate_rps.is_none() {
                        combined.request_rate_rps = snapshot.request_rate_rps;
                        combined.incomplete.request_rate = snapshot.incomplete.request_rate;
                    }
                    if combined.p95_latency_ms.is_none() {
                        combined.p95_latency_ms = snapshot.p95_latency_ms;
                        combined.incomplete.latency = snapshot.incomplete.latency;
                    }
                    if combined.error_rate.is_none() {
                        combined.error_rate = snapshot.error_rate;
                        combined.incomplete.error_rate = snapshot.incomplete.error_rate;
                    }
                    combined.in_flight = combined.in_flight.or(snapshot.in_flight);
                }
                Err(err) => {
                    warn!(job_id = %registration.job_id, error = %err, "autoscaling metrics provider failed");
                    last_error = Some(err);
                }
            }
        }

        if saw_success {
            Ok(combined)
        } else if let Some(err) = last_error {
            Err(err)
        } else {
            Ok(combined)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Samples;
    #[async_trait]
    impl MetricsProvider for Samples {
        fn name(&self) -> &'static str {
            "samples"
        }
        async fn snapshot(&self, reg: &JobRegistration, _: Duration) -> Result<MetricSnapshot> {
            if reg.service_name.0 == "failed" {
                return Err(nscale_core::error::NscaleError::Consul(
                    "metrics unavailable".into(),
                ));
            }
            Ok(match reg.service_name.0.as_str() {
                "a" => MetricSnapshot {
                    request_rate_rps: Some(10.0),
                    p95_latency_ms: Some(10.0),
                    error_rate: Some(0.0),
                    in_flight: None,
                    ..Default::default()
                },
                "b" => MetricSnapshot {
                    request_rate_rps: Some(30.0),
                    p95_latency_ms: Some(100.0),
                    error_rate: Some(0.2),
                    in_flight: None,
                    ..Default::default()
                },
                _ => MetricSnapshot::default(),
            })
        }
    }
    fn registration(service: &str) -> JobRegistration {
        JobRegistration {
            job_id: "api".into(),
            service_name: service.into(),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: None,
            traefik_routers: vec![],
        }
    }
    #[tokio::test]
    async fn group_sums_all_service_rates_and_preserves_worst_signal() {
        let sample = Samples
            .group_snapshot(
                &[registration("a"), registration("b")],
                Duration::from_secs(60),
            )
            .await
            .unwrap();
        assert_eq!(sample.request_rate_rps, Some(40.0));
        assert_eq!(sample.p95_latency_ms, Some(100.0));
        assert_eq!(sample.error_rate, Some(0.2));
    }
    #[tokio::test]
    async fn missing_service_cannot_look_like_low_group_load() {
        let sample = Samples
            .group_snapshot(
                &[registration("a"), registration("missing")],
                Duration::from_secs(60),
            )
            .await
            .unwrap();
        assert_eq!(sample.request_rate_rps, Some(10.0));
        assert_eq!(sample.p95_latency_ms, Some(10.0));
        assert!(sample.incomplete.request_rate);
        assert!(sample.incomplete.latency);
        for target in [
            r#""target_requests_per_second_per_instance":10"#,
            r#""target_p95_latency_ms":50"#,
            r#""max_error_rate":0.1"#,
        ] {
            let policy =
                serde_json::from_str(&format!("{{\"min_count\":1,\"max_count\":5,{target}}}"))
                    .unwrap();
            let decision = crate::autoscale_policy::decide_autoscale(&policy, 4, &sample, false);
            assert_eq!(
                decision.desired_count, 4,
                "partial low load for {target} must not reduce capacity"
            );
        }
    }

    #[tokio::test]
    async fn known_overload_scales_up_despite_missing_or_failed_siblings() {
        for sibling in ["missing", "failed"] {
            let sample = Samples
                .group_snapshot(
                    &[registration("b"), registration(sibling)],
                    Duration::from_secs(60),
                )
                .await
                .unwrap();
            for target in [
                r#""target_requests_per_second_per_instance":10"#,
                r#""target_p95_latency_ms":50"#,
                r#""max_error_rate":0.1"#,
            ] {
                let policy =
                    serde_json::from_str(&format!("{{\"min_count\":1,\"max_count\":5,{target}}}"))
                        .unwrap();
                let decision =
                    crate::autoscale_policy::decide_autoscale(&policy, 1, &sample, false);
                assert_eq!(
                    decision.direction,
                    crate::autoscale_policy::AutoscaleDirection::Up,
                    "known overload for {target} with {sibling} sibling"
                );
            }
        }
    }

    #[tokio::test]
    async fn complete_low_load_still_scales_down() {
        let mut sample = Samples
            .group_snapshot(
                &[registration("a"), registration("b")],
                Duration::from_secs(60),
            )
            .await
            .unwrap();
        let policy = serde_json::from_str(
            r#"{"min_count":1,"max_count":5,"target_requests_per_second_per_instance":10}"#,
        )
        .unwrap();
        let decision = crate::autoscale_policy::decide_autoscale(&policy, 5, &sample, false);
        assert_eq!(decision.desired_count, 4);
        sample.incomplete.latency = true;
        sample.incomplete.error_rate = true;
        assert_eq!(
            crate::autoscale_policy::decide_autoscale(&policy, 5, &sample, false).desired_count,
            4,
            "gaps in unconfigured signals must not block reduction"
        );
    }
    #[tokio::test]
    async fn missing_primary_metric_uses_fallback_but_zero_does_not() {
        struct Missing;
        #[async_trait]
        impl MetricsProvider for Missing {
            fn name(&self) -> &'static str {
                "missing"
            }
            async fn snapshot(&self, _: &JobRegistration, _: Duration) -> Result<MetricSnapshot> {
                Ok(MetricSnapshot::default())
            }
        }
        struct Zero;
        #[async_trait]
        impl MetricsProvider for Zero {
            fn name(&self) -> &'static str {
                "zero"
            }
            async fn snapshot(&self, _: &JobRegistration, _: Duration) -> Result<MetricSnapshot> {
                Ok(MetricSnapshot {
                    request_rate_rps: Some(0.0),
                    ..Default::default()
                })
            }
        }
        let zero = CompositeMetricsProvider::new(vec![Arc::new(Zero), Arc::new(Samples)]);
        assert_eq!(
            zero.snapshot(&registration("a"), Duration::from_secs(60))
                .await
                .unwrap()
                .request_rate_rps,
            Some(0.0)
        );
        let provider = CompositeMetricsProvider::new(vec![Arc::new(Missing), Arc::new(Samples)]);
        assert_eq!(
            provider
                .snapshot(&registration("a"), Duration::from_secs(60))
                .await
                .unwrap()
                .request_rate_rps,
            Some(10.0)
        );
    }
}
