use async_trait::async_trait;
use reqwest::header::{HeaderMap, HeaderValue};
use tracing::{debug, info, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{Endpoint, JobId};
use nscale_core::traits::Orchestrator;

use crate::models::*;

pub struct NomadClient {
    client: reqwest::Client,
    base_url: String,
}

impl NomadClient {
    pub fn new(addr: &str, token: Option<&str>) -> Result<Self> {
        let mut headers = HeaderMap::new();
        if let Some(t) = token {
            headers.insert(
                "X-Nomad-Token",
                HeaderValue::from_str(t).map_err(|e| NscaleError::Nomad(e.to_string()))?,
            );
        }

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .pool_max_idle_per_host(20)
            .build()?;

        Ok(Self {
            client,
            base_url: addr.trim_end_matches('/').to_string(),
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    pub async fn get_job(&self, job_id: &JobId) -> Result<Job> {
        let resp = self
            .client
            .get(self.url(&format!("/v1/job/{}", job_id)))
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(NscaleError::Nomad(format!(
                "GET /v1/job/{} returned {}: {}",
                job_id, status, body
            )));
        }

        Ok(resp.json().await?)
    }

    pub async fn get_allocations(&self, job_id: &JobId) -> Result<Vec<Allocation>> {
        let resp = self
            .client
            .get(self.url(&format!("/v1/job/{}/allocations", job_id)))
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(NscaleError::Nomad(format!(
                "GET /v1/job/{}/allocations returned {}: {}",
                job_id, status, body
            )));
        }

        Ok(resp.json().await?)
    }

    fn extract_endpoint(alloc: &Allocation) -> Option<Endpoint> {
        // Try allocated_resources.shared.ports first (preferred in newer Nomad)
        if let Some(ref allocated) = alloc.allocated_resources {
            if let Some(ref shared) = allocated.shared {
                if let Some(port) = shared.ports.first() {
                    let host = if port.host_ip.is_empty() || port.host_ip == "0.0.0.0" {
                        // Fallback to network IP
                        shared
                            .networks
                            .first()
                            .map(|n| n.ip.clone())
                            .unwrap_or_else(|| "127.0.0.1".to_string())
                    } else {
                        port.host_ip.clone()
                    };
                    return Some(Endpoint::new(host, port.value));
                }
            }
        }

        // Fallback to resources.networks
        if let Some(ref resources) = alloc.resources {
            if let Some(net) = resources.networks.first() {
                let port = net
                    .dynamic_ports
                    .first()
                    .or(net.reserved_ports.first())
                    .map(|p| p.value)?;
                return Some(Endpoint::new(&net.ip, port));
            }
        }

        None
    }
}

#[async_trait]
impl Orchestrator for NomadClient {
    #[instrument(skip(self), fields(job_id = %job_id, group = %group, count = count))]
    async fn scale_up(&self, job_id: &JobId, group: &str, count: u32) -> Result<()> {
        debug!("scaling up job");

        let req = ScaleRequest {
            count: Some(count),
            target: ScaleTarget {
                group: group.to_string(),
            },
            message: Some("nscale: scaling up on demand".to_string()),
        };

        let resp = self
            .client
            .post(self.url(&format!("/v1/job/{}/scale", job_id)))
            .json(&req)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            // Nomad returns 400 when a deployment is already in progress.
            // This means the job is already scaling up — just proceed to
            // wait for the healthy endpoint (matches Go activator behavior).
            if status.as_u16() == 400
                && body.to_lowercase().contains("scaling blocked due to active deployment")
            {
                info!(job_id = %job_id, "scale-up blocked by active deployment, proceeding to wait");
                return Ok(());
            }
            return Err(NscaleError::Nomad(format!(
                "POST /v1/job/{}/scale returned {}: {}",
                job_id, status, body
            )));
        }

        let scale_resp: ScaleResponse = resp.json().await?;
        if !scale_resp.warnings.is_empty() {
            warn!(warnings = %scale_resp.warnings, "scale-up returned warnings");
        }

        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id, group = %group))]
    async fn scale_down(&self, job_id: &JobId, group: &str) -> Result<()> {
        debug!("scaling down job");

        let req = ScaleRequest {
            count: Some(0),
            target: ScaleTarget {
                group: group.to_string(),
            },
            message: Some("nscale: scaling to zero after idle".to_string()),
        };

        let resp = self
            .client
            .post(self.url(&format!("/v1/job/{}/scale", job_id)))
            .json(&req)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(NscaleError::Nomad(format!(
                "POST /v1/job/{}/scale (down) returned {}: {}",
                job_id, status, body
            )));
        }

        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id, group = %group))]
    async fn get_job_count(&self, job_id: &JobId, group: &str) -> Result<u32> {
        let job = self.get_job(job_id).await?;
        let tg = job
            .task_groups
            .iter()
            .find(|g| g.name == group)
            .ok_or_else(|| {
                NscaleError::Nomad(format!(
                    "task group '{}' not found in job '{}'",
                    group, job_id
                ))
            })?;
        Ok(tg.count)
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn get_healthy_endpoint(&self, job_id: &JobId) -> Result<Option<Endpoint>> {
        let allocs = self.get_allocations(job_id).await?;

        let running = allocs.iter().find(|a| a.is_running());

        match running {
            Some(alloc) => Ok(Self::extract_endpoint(alloc)),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn test_scale_up() {
        let mock_server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/v1/job/test-job/scale"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({"Warnings": ""})),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let result = client
            .scale_up(&"test-job".into(), "web", 1)
            .await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_scale_down() {
        let mock_server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/v1/job/test-job/scale"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({"Warnings": ""})),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let result = client.scale_down(&"test-job".into(), "web").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_get_job_count() {
        let mock_server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/v1/job/test-job"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "ID": "test-job",
                "Name": "test-job",
                "Status": "running",
                "TaskGroups": [{"Name": "web", "Count": 2}]
            })))
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let count = client
            .get_job_count(&"test-job".into(), "web")
            .await
            .unwrap();
        assert_eq!(count, 2);
    }

    #[tokio::test]
    async fn test_get_healthy_endpoint_running() {
        let mock_server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/v1/job/test-job/allocations"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "ID": "alloc-1",
                    "JobID": "test-job",
                    "ClientStatus": "running",
                    "DesiredStatus": "run",
                    "TaskGroup": "web",
                    "AllocatedResources": {
                        "Shared": {
                            "Ports": [{"Label": "http", "Value": 28000, "To": 8080, "HostIP": "10.0.0.1"}],
                            "Networks": [{"IP": "10.0.0.1", "DynamicPorts": [], "ReservedPorts": []}]
                        }
                    }
                }
            ])))
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let endpoint = client
            .get_healthy_endpoint(&"test-job".into())
            .await
            .unwrap();
        assert!(endpoint.is_some());
        let ep = endpoint.unwrap();
        assert_eq!(ep.host, "10.0.0.1");
        assert_eq!(ep.port, 28000);
    }

    #[tokio::test]
    async fn test_get_healthy_endpoint_none_running() {
        let mock_server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/v1/job/test-job/allocations"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "ID": "alloc-1",
                    "JobID": "test-job",
                    "ClientStatus": "complete",
                    "DesiredStatus": "stop",
                    "TaskGroup": "web"
                }
            ])))
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let endpoint = client
            .get_healthy_endpoint(&"test-job".into())
            .await
            .unwrap();
        assert!(endpoint.is_none());
    }

    #[tokio::test]
    async fn test_nomad_error_response() {
        let mock_server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/v1/job/missing-job"))
            .respond_with(ResponseTemplate::new(404).set_body_string("job not found"))
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let result = client.get_job(&"missing-job".into()).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_scale_up_active_deployment_succeeds() {
        let mock_server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/v1/job/test-job/scale"))
            .respond_with(
                ResponseTemplate::new(400)
                    .set_body_string("job scaling blocked due to active deployment"),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let result = client.scale_up(&"test-job".into(), "web", 1).await;
        assert!(result.is_ok(), "active deployment should not be treated as error");
    }

    #[tokio::test]
    async fn test_scale_up_other_400_error_fails() {
        let mock_server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/v1/job/test-job/scale"))
            .respond_with(
                ResponseTemplate::new(400)
                    .set_body_string("job not found or invalid group"),
            )
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = NomadClient::new(&mock_server.uri(), None).unwrap();
        let result = client.scale_up(&"test-job".into(), "web", 1).await;
        assert!(result.is_err(), "other 400 errors should still fail");
    }
}
