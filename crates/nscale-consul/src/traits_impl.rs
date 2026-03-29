use std::time::Duration;

use async_trait::async_trait;

use nscale_core::error::Result;
use nscale_core::job::{Endpoint, ServiceName};
use nscale_core::traits::ServiceDiscovery;

use crate::client::ConsulClient;

#[async_trait]
impl ServiceDiscovery for ConsulClient {
    async fn register_fallback(
        &self,
        service_name: &ServiceName,
        proxy_endpoint: &Endpoint,
    ) -> Result<()> {
        self.register_fallback_service(service_name, proxy_endpoint)
            .await
    }

    async fn deregister_fallback(&self, service_name: &ServiceName) -> Result<()> {
        self.deregister_fallback_service(service_name).await
    }

    async fn wait_for_healthy(
        &self,
        service_name: &ServiceName,
        timeout: Duration,
    ) -> Result<Endpoint> {
        self.wait_for_healthy_service(service_name, timeout).await
    }
}
