use std::collections::HashMap;

use tracing::{debug, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::JobId;

/// Scrapes Traefik Prometheus metrics to determine per-service request counts.
///
/// When Traefik routes traffic directly via ConsulCatalog (healthy service),
/// nscale's proxy never sees those requests.  This probe bridges the gap —
/// before scaling a job down, the controller checks whether Traefik is still
/// actively routing traffic to the service.
pub struct TrafficProbe {
    client: reqwest::Client,
    metrics_url: String,
    provider: String,
    /// Snapshot of the last-seen cumulative request counts per service.
    /// `None` means we haven't observed this service yet.
    last_counts: tokio::sync::Mutex<HashMap<String, Option<u64>>>,
}

impl TrafficProbe {
    pub fn new(metrics_url: &str, provider: &str) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .expect("failed to build HTTP client for traffic probe"),
            metrics_url: metrics_url.trim_end_matches('/').to_string(),
            provider: provider.to_string(),
            last_counts: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    /// Returns `true` if Traefik has routed new requests to the given service
    /// since the last time we checked.
    #[instrument(skip(self), fields(job_id = %job_id))]
    pub async fn has_active_traffic(&self, job_id: &JobId) -> Result<bool> {
        let service_label = format!("{}@{}", job_id.0, self.provider);
        let current_total = self.scrape_request_count(&service_label).await?;

        let mut last = self.last_counts.lock().await;
        let prev = last.get(&service_label).copied().flatten();

        debug!(
            service = %service_label,
            current_total,
            prev_total = ?prev,
            "traffic probe check"
        );

        // Update snapshot
        last.insert(service_label, Some(current_total));

        match prev {
            // First observation — no baseline yet.  Assume traffic IS present
            // (fail-open) so we don't accidentally scale down an active service.
            None => Ok(true),
            // Subsequent observations — compare with previous count.
            Some(p) => Ok(current_total > p),
        }
    }

    /// Scrape Traefik Prometheus metrics and extract
    /// `traefik_service_requests_total{service="<label>"}`.
    async fn scrape_request_count(&self, service_label: &str) -> Result<u64> {
        let url = format!("{}/metrics", self.metrics_url);

        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| NscaleError::Consul(format!("traefik metrics fetch failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            warn!(status = %status, "traefik metrics endpoint returned non-200");
            return Err(NscaleError::Consul(format!(
                "traefik metrics returned {status}"
            )));
        }

        let body = resp
            .text()
            .await
            .map_err(|e| NscaleError::Consul(format!("failed to read metrics body: {e}")))?;

        Ok(parse_service_requests_total(&body, service_label))
    }
}

/// Parse Prometheus text format for `traefik_service_requests_total` matching
/// a specific `service` label.  Sums across all code/method/protocol dimensions.
fn parse_service_requests_total(body: &str, service_label: &str) -> u64 {
    let mut total: u64 = 0;
    let needle = format!("service=\"{}\"", service_label);

    for line in body.lines() {
        // Skip comments and empty lines
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        // Match lines like:
        //   traefik_service_requests_total{code="200",method="GET",...,service="echo-s2z@consulcatalog"} 42
        if line.starts_with("traefik_service_requests_total{") && line.contains(&needle) {
            if let Some(value_str) = line.rsplit_once(' ').map(|(_, v)| v) {
                if let Ok(v) = value_str.parse::<f64>() {
                    total += v as u64;
                }
            }
        }
    }

    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_service_requests_total() {
        let body = r#"
# HELP traefik_service_requests_total How many HTTP requests processed, partitioned by status code, protocol, and method.
# TYPE traefik_service_requests_total counter
traefik_service_requests_total{code="200",method="GET",protocol="http",service="echo-s2z@consulcatalog"} 150
traefik_service_requests_total{code="200",method="POST",protocol="http",service="echo-s2z@consulcatalog"} 30
traefik_service_requests_total{code="500",method="GET",protocol="http",service="echo-s2z@consulcatalog"} 2
traefik_service_requests_total{code="200",method="GET",protocol="http",service="other-svc@consulcatalog"} 999
"#;

        assert_eq!(
            parse_service_requests_total(body, "echo-s2z@consulcatalog"),
            182
        );
        assert_eq!(
            parse_service_requests_total(body, "other-svc@consulcatalog"),
            999
        );
        assert_eq!(
            parse_service_requests_total(body, "missing@consulcatalog"),
            0
        );
    }

    #[test]
    fn test_parse_empty_body() {
        assert_eq!(parse_service_requests_total("", "foo@consulcatalog"), 0);
    }
}
