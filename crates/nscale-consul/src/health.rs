use std::time::Duration;

use serde::Deserialize;
use tracing::{debug, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{Endpoint, ServiceName};

use crate::client::ConsulClient;

/// A service health entry from Consul's /v1/health/service/:name endpoint.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct HealthEntry {
    service: ServiceInfo,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ServiceInfo {
    #[serde(rename = "ID")]
    id: String,
    address: String,
    port: u16,
    #[serde(default)]
    tags: Vec<String>,
}

impl ConsulClient {
    pub async fn healthy_service_endpoints(&self, service: &ServiceName) -> Result<Vec<Endpoint>> {
        let entries: Vec<HealthEntry> = self
            .client
            .get(self.url(&format!("/v1/health/service/{}", service)))
            .query(&[("passing", "true")])
            .timeout(Duration::from_secs(5))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(entries
            .into_iter()
            .filter(|entry| {
                !entry
                    .service
                    .tags
                    .iter()
                    .any(|tag| tag == "nscale-fallback")
            })
            .map(|entry| Endpoint::new(entry.service.address, entry.service.port))
            .collect())
    }

    /// Wait for a healthy non-fallback instance of the service to appear.
    /// Uses Consul blocking queries (long-polling) to avoid tight polling loops.
    #[instrument(skip(self), fields(service = %service_name, timeout = ?timeout))]
    pub async fn wait_for_healthy_service(
        &self,
        service_name: &ServiceName,
        timeout: Duration,
    ) -> Result<Endpoint> {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut consul_index: u64 = 0;
        // Consul blocking query wait time (per request, not total)
        let block_wait = Duration::from_secs(10).min(timeout);

        loop {
            if tokio::time::Instant::now() >= deadline {
                return Err(NscaleError::WakeTimeout {
                    job_id: service_name.0.clone(),
                    elapsed_secs: timeout.as_secs_f64(),
                });
            }

            let remaining = deadline - tokio::time::Instant::now();
            let wait = block_wait.min(remaining);

            let url = format!(
                "/v1/health/service/{}?passing=true&index={}&wait={}s",
                service_name,
                consul_index,
                wait.as_secs().max(1),
            );

            debug!(url = %url, "polling consul for healthy service");

            let resp = self.client.get(self.url(&url)).send().await?;

            // Extract X-Consul-Index for next blocking query
            if let Some(idx) = resp.headers().get("X-Consul-Index")
                && let Ok(s) = idx.to_str()
                && let Ok(i) = s.parse::<u64>()
            {
                consul_index = i;
            }

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                warn!(status = %status, "consul health check failed: {}", body);
                tokio::time::sleep(Duration::from_millis(500)).await;
                continue;
            }

            let entries: Vec<HealthEntry> = resp.json().await?;

            // Find a non-fallback healthy service
            if let Some(entry) = entries
                .iter()
                .find(|e| !e.service.tags.contains(&"nscale-fallback".to_string()))
            {
                let endpoint = Endpoint::new(&entry.service.address, entry.service.port);
                debug!(endpoint = %endpoint, service_id = %entry.service.id, "found healthy service");
                return Ok(endpoint);
            }

            // Only fallback services found, keep waiting
            debug!("no non-fallback healthy instances, continuing blocking query");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path_regex};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn test_wait_for_healthy_immediate() {
        let mock_server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path_regex(r"/v1/health/service/my-svc.*"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("X-Consul-Index", "42")
                    .set_body_json(serde_json::json!([
                        {
                            "Service": {
                                "ID": "my-svc-1",
                                "Address": "10.0.0.5",
                                "Port": 9090,
                                "Tags": []
                            }
                        }
                    ])),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = ConsulClient::new(&mock_server.uri(), None).unwrap();
        let ep = client
            .wait_for_healthy_service(&"my-svc".into(), Duration::from_secs(5))
            .await
            .unwrap();

        assert_eq!(ep.host, "10.0.0.5");
        assert_eq!(ep.port, 9090);
    }

    #[tokio::test]
    async fn test_wait_for_healthy_skips_fallback() {
        let mock_server = MockServer::start().await;

        // First call: only fallback, second call: real service
        Mock::given(method("GET"))
            .and(path_regex(r"/v1/health/service/my-svc.*"))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("X-Consul-Index", "100")
                    .set_body_json(serde_json::json!([
                        {
                            "Service": {
                                "ID": "nscale-fallback-my-svc",
                                "Address": "10.0.0.1",
                                "Port": 8080,
                                "Tags": ["nscale-fallback"]
                            }
                        },
                        {
                            "Service": {
                                "ID": "my-svc-real",
                                "Address": "10.0.0.10",
                                "Port": 3000,
                                "Tags": ["http"]
                            }
                        }
                    ])),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = ConsulClient::new(&mock_server.uri(), None).unwrap();
        let ep = client
            .wait_for_healthy_service(&"my-svc".into(), Duration::from_secs(5))
            .await
            .unwrap();

        assert_eq!(ep.host, "10.0.0.10");
        assert_eq!(ep.port, 3000);
    }

    #[tokio::test]
    async fn snapshot_returns_all_healthy_service_ports_without_fallback() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;
        Mock::given(method("GET")).and(path_regex("/v1/health/service/api"))
            .and(query_param("passing", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"Service":{"ID":"one","Address":"10.0.0.1","Port":8001,"Tags":[]}},
                {"Service":{"ID":"two","Address":"10.0.0.2","Port":8002,"Tags":[]}},
                {"Service":{"ID":"fallback","Address":"proxy","Port":8080,"Tags":["nscale-fallback"]}}
            ]))).mount(&server).await;
        let endpoints = ConsulClient::new(&server.uri(), None)
            .unwrap()
            .healthy_service_endpoints(&"api".into())
            .await
            .unwrap();
        assert_eq!(endpoints.len(), 2);
        assert_eq!(endpoints[0].port, 8001);
        assert_eq!(endpoints[1].port, 8002);
    }
}
