use fred::prelude::*;
use tracing::{debug, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{JobId, JobRegistration};

const REGISTRY_KEY: &str = "nscale:jobs";

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
        let value =
            serde_json::to_string(reg).map_err(|e| NscaleError::Store(e.to_string()))?;
        let _: () = self
            .client
            .hset(REGISTRY_KEY, (reg.job_id.0.as_str(), value.as_str()))
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!("registered job");
        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    pub async fn deregister(&self, job_id: &JobId) -> Result<()> {
        let _: i64 = self
            .client
            .hdel(REGISTRY_KEY, job_id.0.as_str())
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!("deregistered job");
        Ok(())
    }

    pub async fn get(&self, job_id: &JobId) -> Result<Option<JobRegistration>> {
        let value: Option<String> = self
            .client
            .hget(REGISTRY_KEY, job_id.0.as_str())
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

    pub async fn list_all(&self) -> Result<Vec<JobRegistration>> {
        let entries: std::collections::HashMap<String, String> = self
            .client
            .hgetall(REGISTRY_KEY)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let mut regs = Vec::with_capacity(entries.len());
        for (_key, value) in entries {
            let reg: JobRegistration = serde_json::from_str(&value)?;
            regs.push(reg);
        }

        Ok(regs)
    }
}
