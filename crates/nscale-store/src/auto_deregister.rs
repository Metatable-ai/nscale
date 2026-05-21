use fred::prelude::*;
use tracing::{debug, instrument};

use nscale_core::error::{NscaleError, Result};
use nscale_core::job::JobId;
use nscale_core::traits::MissingJobTracker;

const AUTO_DEREGISTER_NOT_FOUND_PREFIX: &str = "nscale:auto-deregister:not-found:";

/// Redis-backed tracker for consecutive Nomad missing-job signals.
pub struct RedisMissingJobTracker {
    client: Client,
}

impl RedisMissingJobTracker {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    fn key(&self, job_id: &JobId) -> String {
        format!("{AUTO_DEREGISTER_NOT_FOUND_PREFIX}{job_id}")
    }
}

#[async_trait::async_trait]
impl MissingJobTracker for RedisMissingJobTracker {
    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn increment_not_found(&self, job_id: &JobId) -> Result<u32> {
        let count: i64 = self
            .client
            .eval(
                "return redis.call('INCR', KEYS[1])",
                vec![self.key(job_id)],
                Vec::<String>::new(),
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        let count = u32::try_from(count).map_err(|_| {
            NscaleError::Store(format!(
                "missing-job counter for {} exceeded u32 range: {}",
                job_id, count
            ))
        })?;

        debug!(count, "incremented missing-job counter");
        Ok(count)
    }

    #[instrument(skip(self), fields(job_id = %job_id))]
    async fn clear_not_found(&self, job_id: &JobId) -> Result<()> {
        let _: i64 = self
            .client
            .eval(
                "return redis.call('DEL', KEYS[1])",
                vec![self.key(job_id)],
                Vec::<String>::new(),
            )
            .await
            .map_err(|e| NscaleError::Store(e.to_string()))?;

        debug!("cleared missing-job counter");
        Ok(())
    }
}
