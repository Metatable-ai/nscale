use fred::prelude::*;
use tracing::{debug, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{JobId, JobRegistration};

const REGISTRY_BY_JOB_KEY: &str = "nscale:jobs";
const REGISTRY_BY_SERVICE_KEY: &str = "nscale:jobs:services";

/// Job registry backed by a Redis hash.
pub struct JobRegistry {
    client: Client,
}

impl JobRegistry {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    #[instrument(skip(self), fields(job_id = %reg.job_id))]
    pub async fn register(&self, reg: &JobRegistration) -> Result<()> {
        let value = serde_json::to_string(reg).map_err(|e| NscaleError::Store(e.to_string()))?;
        let _: () = self
            .client
            .hset(REGISTRY_BY_JOB_KEY, (reg.job_id.0.as_str(), value.as_str()))
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        let _: () = self
            .client
            .hset(
                REGISTRY_BY_SERVICE_KEY,
                (reg.service_name.0.as_str(), value.as_str()),
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!("registered job");
        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    pub async fn deregister(&self, job_id: &JobId) -> Result<()> {
        let service_entries: std::collections::HashMap<String, String> = self
            .client
            .hgetall(REGISTRY_BY_SERVICE_KEY)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        for (service_name, value) in service_entries {
            let reg: JobRegistration = serde_json::from_str(&value)?;
            if reg.job_id == *job_id {
                let _: i64 = self
                    .client
                    .hdel(REGISTRY_BY_SERVICE_KEY, service_name.as_str())
                    .await
                    .map_err(|e| NscaleError::Store(e.to_string()))?;
            }
        }

        let _: i64 = self
            .client
            .hdel(REGISTRY_BY_JOB_KEY, job_id.0.as_str())
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!("deregistered job");
        Ok(())
    }

    async fn get_from_hash(&self, hash_key: &str, field: &str) -> Result<Option<JobRegistration>> {
        let value: Option<String> = self
            .client
            .hget(hash_key, field)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        match value {
            Some(v) => {
                let reg: JobRegistration = serde_json::from_str(&v)?;
                Ok(Some(reg))
            }
            None => Ok(None),
        }
    }

    pub async fn get(&self, lookup: &JobId) -> Result<Option<JobRegistration>> {
        match self
            .get_from_hash(REGISTRY_BY_JOB_KEY, lookup.0.as_str())
            .await?
        {
            Some(reg) => Ok(Some(reg)),
            None => {
                self.get_from_hash(REGISTRY_BY_SERVICE_KEY, lookup.0.as_str())
                    .await
            }
        }
    }

    pub async fn list_all(&self) -> Result<Vec<JobRegistration>> {
        let entries: std::collections::HashMap<String, String> = self
            .client
            .hgetall(REGISTRY_BY_SERVICE_KEY)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let entries = if entries.is_empty() {
            self.client
                .hgetall(REGISTRY_BY_JOB_KEY)
                .await
                .map_err(|e| NscaleError::Store(e.to_string()))?
        } else {
            entries
        };

        let mut regs = Vec::with_capacity(entries.len());
        for (_key, value) in entries {
            let reg: JobRegistration = serde_json::from_str(&value)?;
            regs.push(reg);
        }

        Ok(regs)
    }
}
