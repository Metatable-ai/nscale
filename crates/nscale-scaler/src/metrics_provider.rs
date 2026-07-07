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
                    combined.request_rate_rps =
                        combined.request_rate_rps.or(snapshot.request_rate_rps);
                    combined.p95_latency_ms = combined.p95_latency_ms.or(snapshot.p95_latency_ms);
                    combined.error_rate = combined.error_rate.or(snapshot.error_rate);
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
