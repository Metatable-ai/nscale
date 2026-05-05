use std::pin::Pin;

use async_trait::async_trait;
use etcd_client::{Client, GetOptions, Txn, TxnOp};
use futures_core::Stream;
use futures_util::stream;
use tokio::sync::Mutex;
use tracing::instrument;

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{JobId, JobRegistration, ServiceName};
use nscale_core::traits::{DurableRegistry, RegistrationEvent};

pub struct EtcdClient {
    client: Mutex<Client>,
    key_prefix: String,
}

impl EtcdClient {
    pub async fn new(endpoints: Vec<String>, key_prefix: impl Into<String>) -> Result<Self> {
        let client = Client::connect(endpoints, None)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        Ok(Self {
            client: Mutex::new(client),
            key_prefix: normalize_prefix(key_prefix.into()),
        })
    }

    fn jobs_prefix(&self) -> String {
        format!("{}/jobs/", self.key_prefix)
    }

    fn services_prefix(&self) -> String {
        format!("{}/services/", self.key_prefix)
    }

    fn job_key(&self, job_id: &JobId) -> String {
        format!("{}{job_id}", self.jobs_prefix())
    }

    fn service_key(&self, service_name: &ServiceName) -> String {
        format!("{}{service_name}", self.services_prefix())
    }

    fn encode_registration(reg: &JobRegistration) -> Result<Vec<u8>> {
        serde_json::to_vec(reg).map_err(|e| NscaleError::Store(e.to_string()))
    }

    fn decode_registration(bytes: &[u8]) -> Result<JobRegistration> {
        serde_json::from_slice(bytes).map_err(|e| NscaleError::Store(e.to_string()))
    }

    async fn apply_txn(&self, operations: Vec<TxnOp>) -> Result<()> {
        let mut client = self.client.lock().await;
        client
            .txn(Txn::new().and_then(operations))
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        Ok(())
    }

    async fn get_by_key(&self, key: String) -> Result<Option<JobRegistration>> {
        let mut client = self.client.lock().await;
        let response = client
            .get(key, None)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        response
            .kvs()
            .first()
            .map(|kv| Self::decode_registration(kv.value()))
            .transpose()
    }

    async fn list_by_prefix(&self, prefix: String) -> Result<Vec<JobRegistration>> {
        let mut client = self.client.lock().await;
        let response = client
            .get(prefix, Some(GetOptions::new().with_prefix()))
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        response
            .kvs()
            .iter()
            .map(|kv| Self::decode_registration(kv.value()))
            .collect()
    }

    async fn service_keys_for_job(&self, job_id: &JobId) -> Result<Vec<String>> {
        let mut client = self.client.lock().await;
        let response = client
            .get(
                self.services_prefix(),
                Some(GetOptions::new().with_prefix()),
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let mut keys = Vec::new();
        for kv in response.kvs() {
            let reg = Self::decode_registration(kv.value())?;
            if reg.job_id == *job_id {
                keys.push(String::from_utf8_lossy(kv.key()).into_owned());
            }
        }

        Ok(keys)
    }
}

#[async_trait]
impl DurableRegistry for EtcdClient {
    #[instrument(skip(self), fields(job_id = %reg.job_id, service_name = %reg.service_name))]
    async fn store_registration(&self, reg: &JobRegistration) -> Result<()> {
        let encoded = Self::encode_registration(reg)?;
        let job_key = self.job_key(&reg.job_id);
        let service_key = self.service_key(&reg.service_name);

        self.apply_txn(vec![
            TxnOp::put(job_key, encoded.clone(), None),
            TxnOp::put(service_key, encoded, None),
        ])
        .await
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn remove_registration(&self, job_id: &JobId) -> Result<()> {
        let mut operations = self
            .service_keys_for_job(job_id)
            .await?
            .into_iter()
            .map(|key| TxnOp::delete(key, None))
            .collect::<Vec<_>>();
        operations.push(TxnOp::delete(self.job_key(job_id), None));

        self.apply_txn(operations).await
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn get_by_job_id(&self, job_id: &JobId) -> Result<Option<JobRegistration>> {
        self.get_by_key(self.job_key(job_id)).await
    }

    #[instrument(skip(self), fields(service_name = %service_name))]
    async fn get_by_service_name(
        &self,
        service_name: &ServiceName,
    ) -> Result<Option<JobRegistration>> {
        self.get_by_key(self.service_key(service_name)).await
    }

    #[instrument(skip(self))]
    async fn list_all(&self) -> Result<Vec<JobRegistration>> {
        let service_regs = self.list_by_prefix(self.services_prefix()).await?;
        if !service_regs.is_empty() {
            return Ok(service_regs);
        }

        self.list_by_prefix(self.jobs_prefix()).await
    }

    async fn watch_registrations(
        &self,
    ) -> Result<Pin<Box<dyn Stream<Item = RegistrationEvent> + Send>>> {
        Ok(Box::pin(stream::empty()))
    }
}

fn normalize_prefix(prefix: String) -> String {
    let trimmed = prefix.trim();
    let trimmed = trimmed.trim_end_matches('/');

    if trimmed.is_empty() {
        "/nscale/registrations".to_string()
    } else if trimmed.starts_with('/') {
        trimmed.to_string()
    } else {
        format!("/{trimmed}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_prefix() {
        assert_eq!(
            normalize_prefix("/nscale/registrations/".to_string()),
            "/nscale/registrations"
        );
        assert_eq!(
            normalize_prefix("nscale/registrations".to_string()),
            "/nscale/registrations"
        );
        assert_eq!(normalize_prefix("   ".to_string()), "/nscale/registrations");
    }

    #[test]
    fn registration_round_trip_codec() {
        let reg = JobRegistration {
            job_id: JobId("job-a".to_string()),
            service_name: ServiceName("svc-a".to_string()),
            nomad_group: "main".to_string(),
        };

        let encoded = EtcdClient::encode_registration(&reg).expect("encode registration");
        let decoded = EtcdClient::decode_registration(&encoded).expect("decode registration");

        assert_eq!(decoded.job_id.0, "job-a");
        assert_eq!(decoded.service_name.0, "svc-a");
        assert_eq!(decoded.nomad_group, "main");
    }
}
