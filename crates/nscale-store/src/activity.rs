use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use fred::prelude::*;
use fred::types::{Expiration, SetOptions};
use tracing::{debug, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::JobId;
use nscale_core::traits::ActivityStore;

const ACTIVITY_KEY: &str = "nscale:activity";

fn lock_key(key: &str) -> String {
    format!("nscale:lock:{}", key)
}

fn now_epoch_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

/// Redis-backed activity store using sorted sets and distributed locks.
pub struct RedisActivityStore {
    client: Client,
    instance_id: String,
}

impl RedisActivityStore {
    pub async fn new(redis_url: &str) -> Result<Self> {
        let config =
            Config::from_url(redis_url).map_err(|e| NscaleError::Store(e.to_string()))?;
        let client = Builder::from_config(config)
            .build()
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        client
            .init()
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let instance_id = format!("nscale-{}", uuid_v4_simple());

        Ok(Self {
            client,
            instance_id,
        })
    }

    pub fn client(&self) -> &Client {
        &self.client
    }
}

#[async_trait]
impl ActivityStore for RedisActivityStore {
    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn record_activity(&self, job_id: &JobId) -> Result<()> {
        let score = now_epoch_secs();
        let _: () = self
            .client
            .zadd(
                ACTIVITY_KEY,
                None,
                None,
                false,
                false,
                (score, job_id.0.clone()),
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!(score, "recorded activity");
        Ok(())
    }

    #[instrument(skip(self), fields(threshold = ?idle_threshold))]
    async fn get_idle_jobs(&self, idle_threshold: Duration) -> Result<Vec<JobId>> {
        let cutoff = now_epoch_secs() - idle_threshold.as_secs_f64();
        let members: Vec<String> = self
            .client
            .zrangebyscore(ACTIVITY_KEY, f64::NEG_INFINITY, cutoff, false, None)
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        debug!(count = members.len(), cutoff, "found idle jobs");
        Ok(members.into_iter().map(JobId).collect())
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn has_activity(&self, job_id: &JobId) -> Result<bool> {
        let score: Option<f64> = self
            .client
            .zscore(ACTIVITY_KEY, job_id.0.as_str())
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        Ok(score.is_some())
    }

    #[instrument(skip(self), fields(key = key, ttl = ?ttl))]
    async fn try_acquire_lock(&self, key: &str, ttl: Duration) -> Result<bool> {
        let lock = lock_key(key);
        let ttl_ms = ttl.as_millis() as i64;

        // SET key value NX PX ttl
        let result: Option<String> = self
            .client
            .set(
                &lock,
                self.instance_id.as_str(),
                Some(Expiration::PX(ttl_ms)),
                Some(SetOptions::NX),
                false,
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let acquired = result.is_some();
        debug!(acquired, "lock acquisition attempt");
        Ok(acquired)
    }

    #[instrument(skip(self), fields(key = key))]
    async fn release_lock(&self, key: &str) -> Result<()> {
        let lock = lock_key(key);

        // Only release if we own it (compare-and-delete via Lua script)
        let script = r#"
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("del", KEYS[1])
            else
                return 0
            end
        "#;

        let _: i64 = self
            .client
            .eval(script, vec![lock], vec![self.instance_id.clone()])
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        Ok(())
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn remove_activity(&self, job_id: &JobId) -> Result<()> {
        let _: i64 = self
            .client
            .zrem(ACTIVITY_KEY, job_id.0.as_str())
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;
        debug!("removed activity");
        Ok(())
    }
}

/// Simple pseudo-UUID v4 for instance identification (no external dep needed).
fn uuid_v4_simple() -> String {
    use std::time::SystemTime;
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let pid = std::process::id();
    format!("{:x}-{:x}", t, pid)
}
