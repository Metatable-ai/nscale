use std::collections::HashMap;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use nscale_core::error::{NscaleError, Result};
use nscale_core::job::JobRegistration;

use crate::autoscale_policy::MetricSnapshot;
use crate::metrics_provider::MetricsProvider;

#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub struct TraefikCounters {
    pub total: u64,
    pub errors: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct TraefikCounterSample {
    pub total: u64,
    pub errors: u64,
    pub observed_at: Instant,
}

pub struct TraefikMetricsProvider {
    client: reqwest::Client,
    metrics_url: String,
    provider: String,
    last_samples: tokio::sync::Mutex<HashMap<String, TraefikCounterSample>>,
}

impl TraefikMetricsProvider {
    pub fn new(metrics_url: &str, provider: &str) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .expect("failed to build HTTP client for Traefik autoscaling metrics"),
            metrics_url: metrics_url.trim_end_matches('/').to_string(),
            provider: provider.to_string(),
            last_samples: tokio::sync::Mutex::new(HashMap::new()),
        }
    }
}

#[async_trait]
impl MetricsProvider for TraefikMetricsProvider {
    async fn snapshot(
        &self,
        registration: &JobRegistration,
        _window: Duration,
    ) -> Result<MetricSnapshot> {
        let service_label = format!("{}@{}", registration.service_name.0, self.provider);
        let url = format!("{}/metrics", self.metrics_url);

        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| NscaleError::Consul(format!("traefik metrics fetch failed: {e}")))?;

        if !resp.status().is_success() {
            return Err(NscaleError::Consul(format!(
                "traefik metrics returned {}",
                resp.status()
            )));
        }

        let body = resp
            .text()
            .await
            .map_err(|e| NscaleError::Consul(format!("failed to read metrics body: {e}")))?;

        let counters = parse_traefik_request_counters(&body, &service_label);
        let current = TraefikCounterSample {
            total: counters.total,
            errors: counters.errors,
            observed_at: Instant::now(),
        };

        let mut last = self.last_samples.lock().await;
        let previous = last.insert(service_label, current);

        Ok(previous
            .and_then(|sample| calculate_snapshot(sample, current))
            .unwrap_or_default())
    }
}

pub fn parse_traefik_service_counters(body: &str, service_label: &str) -> TraefikCounters {
    let mut counters = TraefikCounters::default();
    let service_needle = format!("service=\"{}\"", service_label);

    for line in body.lines() {
        if line.starts_with('#')
            || !line.starts_with("traefik_service_requests_total{")
            || !line.contains(&service_needle)
        {
            continue;
        }

        let Some(value) = line
            .rsplit_once(' ')
            .and_then(|(_, value)| value.parse::<f64>().ok())
        else {
            continue;
        };

        let count = value as u64;
        counters.total += count;
        if line.contains("code=\"5") {
            counters.errors += count;
        }
    }

    counters
}

pub fn parse_traefik_request_counters(
    body: &str,
    service_or_router_label: &str,
) -> TraefikCounters {
    let mut counters = parse_traefik_service_counters(body, service_or_router_label);
    let router_needle = format!("router=\"{}\"", service_or_router_label);

    for line in body.lines() {
        if line.starts_with('#')
            || !line.starts_with("traefik_router_requests_total{")
            || !line.contains(&router_needle)
        {
            continue;
        }

        let Some(value) = line
            .rsplit_once(' ')
            .and_then(|(_, value)| value.parse::<f64>().ok())
        else {
            continue;
        };

        let count = value as u64;
        counters.total += count;
        if line.contains("code=\"5") {
            counters.errors += count;
        }
    }

    counters
}

pub fn calculate_snapshot(
    previous: TraefikCounterSample,
    current: TraefikCounterSample,
) -> Option<MetricSnapshot> {
    let elapsed = current.observed_at.duration_since(previous.observed_at);
    if elapsed.is_zero() || current.total < previous.total || current.errors < previous.errors {
        return Some(MetricSnapshot::default());
    }

    let total_delta = current.total - previous.total;
    let error_delta = current.errors - previous.errors;
    Some(MetricSnapshot {
        request_rate_rps: Some(total_delta as f64 / elapsed.as_secs_f64()),
        p95_latency_ms: None,
        error_rate: Some(if total_delta == 0 {
            0.0
        } else {
            error_delta as f64 / total_delta as f64
        }),
        in_flight: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    const BODY: &str = r#"
# HELP traefik_service_requests_total How many HTTP requests processed.
# TYPE traefik_service_requests_total counter
traefik_service_requests_total{code="200",method="GET",protocol="http",service="api@consulcatalog"} 150
traefik_service_requests_total{code="201",method="POST",protocol="http",service="api@consulcatalog"} 30
traefik_service_requests_total{code="500",method="GET",protocol="http",service="api@consulcatalog"} 5
traefik_service_requests_total{code="502",method="GET",protocol="http",service="api@consulcatalog"} 7
traefik_service_requests_total{code="200",method="GET",protocol="http",service="other@consulcatalog"} 999
"#;

    const ROUTER_BODY: &str = r#"
# HELP traefik_router_requests_total How many HTTP requests are handled by routers.
# TYPE traefik_router_requests_total counter
traefik_router_requests_total{code="200",method="GET",protocol="http",router="api@consulcatalog",service="s2z-nscale@file"} 90
traefik_router_requests_total{code="500",method="GET",protocol="http",router="api@consulcatalog",service="s2z-nscale@file"} 10
traefik_router_requests_total{code="200",method="GET",protocol="http",router="other@consulcatalog",service="s2z-nscale@file"} 999
"#;

    #[test]
    fn parses_total_and_error_counters_for_service() {
        let counters = parse_traefik_service_counters(BODY, "api@consulcatalog");

        assert_eq!(counters.total, 192);
        assert_eq!(counters.errors, 12);
    }

    #[test]
    fn parses_total_and_error_counters_for_router() {
        let counters = parse_traefik_request_counters(ROUTER_BODY, "api@consulcatalog");

        assert_eq!(counters.total, 100);
        assert_eq!(counters.errors, 10);
    }

    #[test]
    fn computes_request_rate_and_error_rate_from_counter_deltas() {
        let previous = TraefikCounterSample {
            total: 100,
            errors: 5,
            observed_at: Instant::now(),
        };
        let current = TraefikCounterSample {
            total: 160,
            errors: 11,
            observed_at: previous.observed_at + Duration::from_secs(30),
        };

        let snapshot = calculate_snapshot(previous, current).unwrap();

        assert_eq!(snapshot.request_rate_rps, Some(2.0));
        assert_eq!(snapshot.error_rate, Some(0.1));
        assert_eq!(snapshot.p95_latency_ms, None);
    }

    #[test]
    fn counter_reset_returns_no_rate() {
        let previous = TraefikCounterSample {
            total: 100,
            errors: 5,
            observed_at: Instant::now(),
        };
        let current = TraefikCounterSample {
            total: 10,
            errors: 1,
            observed_at: previous.observed_at + Duration::from_secs(30),
        };

        let snapshot = calculate_snapshot(previous, current).unwrap();

        assert_eq!(snapshot.request_rate_rps, None);
        assert_eq!(snapshot.error_rate, None);
    }

    #[test]
    fn unchanged_counter_reports_zero_request_rate() {
        let previous = TraefikCounterSample {
            total: 100,
            errors: 5,
            observed_at: Instant::now(),
        };
        let current = TraefikCounterSample {
            total: 100,
            errors: 5,
            observed_at: previous.observed_at + Duration::from_secs(30),
        };

        let snapshot = calculate_snapshot(previous, current).unwrap();

        assert_eq!(snapshot.request_rate_rps, Some(0.0));
        assert_eq!(snapshot.error_rate, Some(0.0));
    }
}
