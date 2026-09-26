use std::sync::Arc;

use fred::prelude::*;
use tracing::{debug, error, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::{JobId, JobRegistration, ServiceName};
use nscale_core::traits::DurableRegistry;

const REGISTRY_BY_JOB_KEY: &str = "nscale:jobs";
const REGISTRY_BY_SERVICE_KEY: &str = "nscale:jobs:services";

/// Job registry backed by a Redis hash.
pub struct JobRegistry {
    client: Client,
    durable: Option<Arc<dyn DurableRegistry>>,
}

impl JobRegistry {
    pub fn new(client: Client) -> Self {
        Self {
            client,
            durable: None,
        }
    }

    pub fn with_durable(client: Client, durable: Arc<dyn DurableRegistry>) -> Self {
        Self {
            client,
            durable: Some(durable),
        }
    }

    fn encode_registration(reg: &JobRegistration) -> Result<String> {
        serde_json::to_string(reg).map_err(|e| NscaleError::Store(e.to_string()))
    }

    async fn cache_registration(&self, reg: &JobRegistration) -> Result<()> {
        let value = Self::encode_registration(reg)?;
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

        Ok(())
    }

    async fn remove_cached_registration(&self, job_id: &JobId) -> Result<()> {
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

        Ok(())
    }

    pub async fn sync_from_durable(&self) -> Result<usize> {
        let Some(durable) = &self.durable else {
            return Ok(0);
        };

        let regs = durable.list_all().await?;
        for reg in &regs {
            self.cache_registration(reg).await?;
        }

        Ok(regs.len())
    }

    #[instrument(skip(self), fields(job_id = %reg.job_id))]
    pub async fn register(&self, reg: &JobRegistration) -> Result<()> {
        if let Some(durable) = &self.durable {
            durable.store_registration(reg).await?;
        }

        self.cache_registration(reg).await?;
        debug!("registered job");
        Ok(())
    }

    /// Replace a submitted job's complete service set, preserving other jobs.
    /// The caller must hold the job mutation lease until both stores are updated.
    /// Returns the old cached registrations so local readiness can be invalidated.
    pub async fn replace_job_registrations(
        &self,
        job_id: &JobId,
        registrations: &[JobRegistration],
    ) -> Result<Vec<JobRegistration>> {
        let mut services = std::collections::HashSet::new();
        if registrations.is_empty()
            || registrations
                .iter()
                .any(|reg| reg.job_id != *job_id || !services.insert(&reg.service_name))
        {
            return Err(NscaleError::Config(
                "replacement requires unique services belonging to one job".into(),
            ));
        }
        let mut args = vec![job_id.0.clone()];
        for reg in registrations {
            args.push(reg.service_name.0.clone());
            args.push(Self::encode_registration(reg)?);
        }
        if let Some(durable) = &self.durable {
            durable
                .replace_job_registrations(job_id, registrations)
                .await?;
        }
        // Decode before mutating: Lua errors do not roll back earlier commands.
        // Both indexes change in one Redis operation, so readers never see a
        // mixture of the previous and replacement policies.
        let script = r#"
            local entries = redis.call('hgetall', KEYS[2])
            local old = {}
            local removed = {}
            for i = 1, #entries, 2 do
                local reg = cjson.decode(entries[i + 1])
                if reg.job_id == ARGV[1] then
                    table.insert(removed, entries[i])
                    table.insert(old, entries[i + 1])
                end
            end
            for _, service in ipairs(removed) do
                redis.call('hdel', KEYS[2], service)
            end
            for i = 2, #ARGV, 2 do
                redis.call('hset', KEYS[2], ARGV[i], ARGV[i + 1])
            end
            redis.call('hset', KEYS[1], ARGV[1], ARGV[#ARGV])
            return old
        "#;
        let old: Vec<String> = self
            .client
            .eval(
                script,
                vec![REGISTRY_BY_JOB_KEY, REGISTRY_BY_SERVICE_KEY],
                args,
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        old.into_iter()
            .map(|value| serde_json::from_str(&value).map_err(NscaleError::from))
            .collect()
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    pub async fn deregister(&self, job_id: &JobId) -> Result<()> {
        let existing = self.get(job_id).await?;

        if let Some(durable) = &self.durable {
            durable.remove_registration(job_id).await?;

            if let Err(err) = self.remove_cached_registration(job_id).await {
                if let Some(reg) = existing.as_ref()
                    && let Err(restore_err) = durable.store_registration(reg).await
                {
                    error!(
                        job_id = %job_id,
                        error = %restore_err,
                        "failed to restore durable registration after Redis cache eviction error"
                    );
                }

                return Err(err);
            }
        } else {
            self.remove_cached_registration(job_id).await?;
        }
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

    /// Resolve a proxy Host by service identity, without consulting job aliases.
    pub async fn get_by_service_name(
        &self,
        service: &ServiceName,
    ) -> Result<Option<JobRegistration>> {
        if let Some(reg) = self
            .get_from_hash(REGISTRY_BY_SERVICE_KEY, &service.0)
            .await?
        {
            return Ok(Some(reg));
        }
        if let Some(durable) = &self.durable
            && let Some(reg) = durable.get_by_service_name(service).await?
        {
            self.cache_registration(&reg).await?;
            return Ok(Some(reg));
        }
        // Older caches may only have the job hash. Accept an exact service
        // identity there, never a different service stored under the same job ID.
        Ok(self
            .get_from_hash(REGISTRY_BY_JOB_KEY, &service.0)
            .await?
            .filter(|reg| reg.service_name == *service))
    }

    pub async fn get(&self, lookup: &JobId) -> Result<Option<JobRegistration>> {
        match self
            .get_from_hash(REGISTRY_BY_JOB_KEY, lookup.0.as_str())
            .await?
        {
            Some(reg) => Ok(Some(reg)),
            None => match self
                .get_from_hash(REGISTRY_BY_SERVICE_KEY, lookup.0.as_str())
                .await?
            {
                Some(reg) => Ok(Some(reg)),
                None => {
                    let Some(durable) = &self.durable else {
                        return Ok(None);
                    };

                    let durable_hit = match durable.get_by_job_id(lookup).await? {
                        Some(reg) => Some(reg),
                        None => {
                            durable
                                .get_by_service_name(&ServiceName(lookup.0.clone()))
                                .await?
                        }
                    };

                    if let Some(reg) = durable_hit {
                        self.cache_registration(&reg).await?;
                        Ok(Some(reg))
                    } else {
                        Ok(None)
                    }
                }
            },
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

        if entries.is_empty() {
            let Some(durable) = &self.durable else {
                return Ok(Vec::new());
            };

            let regs = durable.list_all().await?;
            for reg in &regs {
                self.cache_registration(reg).await?;
            }
            return Ok(regs);
        }

        let mut regs = Vec::with_capacity(entries.len());
        for (_key, value) in entries {
            let reg: JobRegistration = serde_json::from_str(&value)?;
            regs.push(reg);
        }

        Ok(regs)
    }
}
