use serde::Serialize;
use tracing::{debug, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{Endpoint, ServiceName};

use crate::client::ConsulClient;

/// Registration payload for PUT /v1/agent/service/register.
#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct ServiceRegistration {
    #[serde(rename = "ID")]
    id: String,
    name: String,
    address: String,
    port: u16,
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weights: Option<ServiceWeights>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
struct ServiceWeights {
    passing: u32,
    warning: u32,
}

impl ConsulClient {
    /// Register the nscale proxy as a low-priority fallback service in Consul.
    /// Uses a low passing weight so real services take priority.
    #[instrument(skip(self), fields(service = %service_name, endpoint = %proxy_endpoint))]
    pub async fn register_fallback_service(
        &self,
        service_name: &ServiceName,
        proxy_endpoint: &Endpoint,
    ) -> Result<()> {
        let service_id = format!("nscale-fallback-{}", service_name);

        let registration = ServiceRegistration {
            id: service_id.clone(),
            name: service_name.0.clone(),
            address: proxy_endpoint.host.clone(),
            port: proxy_endpoint.port,
            tags: vec!["nscale-fallback".to_string()],
            weights: Some(ServiceWeights {
                passing: 1,
                warning: 0,
            }),
        };

        debug!(service_id = %service_id, "registering fallback service");

        let resp = self
            .client
            .put(self.url("/v1/agent/service/register"))
            .json(&registration)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(NscaleError::Consul(format!(
                "register fallback returned {}: {}",
                status, body
            )));
        }

        Ok(())
    }

    /// Deregister the fallback service for a given service name.
    #[instrument(skip(self), fields(service = %service_name))]
    pub async fn deregister_fallback_service(
        &self,
        service_name: &ServiceName,
    ) -> Result<()> {
        let service_id = format!("nscale-fallback-{}", service_name);

        debug!(service_id = %service_id, "deregistering fallback service");

        let resp = self
            .client
            .put(self.url(&format!("/v1/agent/service/deregister/{}", service_id)))
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(NscaleError::Consul(format!(
                "deregister fallback returned {}: {}",
                status, body
            )));
        }

        Ok(())
    }
}
