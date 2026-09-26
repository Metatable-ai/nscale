//! Renewable leases shared by wake and scaling controllers. Nomad CAS rejects
//! writes based on a stale job index; it does not fence Redis lease ownership.
use crate::{
    error::{NscaleError, Result},
    job::JobId,
    traits::ActivityStore,
};
use std::{
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

pub const LEASE_TTL: Duration = Duration::from_secs(30);
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(0);

pub fn unique_token() -> String {
    format!(
        "{}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        NEXT_TOKEN.fetch_add(1, Ordering::Relaxed)
    )
}

pub fn job_lock_key(job: &JobId) -> String {
    format!("mutation:{}", job.0)
}
pub fn cooldown_key(job: &JobId, group: &str) -> String {
    format!("autoscale:{}:{}", job.0, group)
}

pub struct Lease {
    store: Arc<dyn ActivityStore>,
    key: String,
    token: String,
    released: bool,
}
impl Lease {
    pub async fn acquire(store: Arc<dyn ActivityStore>, key: String) -> Result<Option<Self>> {
        let token = unique_token();
        let acquired = tokio::time::timeout(
            Duration::from_secs(5),
            store.acquire_lease(&key, &token, LEASE_TTL),
        )
        .await
        .map_err(|_| NscaleError::Store("lease acquisition timed out".into()))??;
        Ok(acquired.then_some(Self {
            store,
            key,
            token,
            released: false,
        }))
    }

    /// Complete ownership-checked cleanup before allowing the next group to run.
    /// Drop remains the fallback if this future is cancelled or cleanup fails.
    pub async fn run<T>(mut self, work: impl Future<Output = Result<T>>) -> Result<T> {
        let result = self.run_owned(work).await;
        match tokio::time::timeout(
            Duration::from_secs(5),
            self.store.release_lease(&self.key, &self.token),
        )
        .await
        {
            Ok(Ok(_)) => self.released = true,
            Ok(Err(error)) => tracing::warn!(%error, key = %self.key, "lease release failed"),
            Err(_) => tracing::warn!(key = %self.key, "lease release timed out"),
        }
        result
    }

    async fn run_owned<T>(&self, work: impl Future<Output = Result<T>>) -> Result<T> {
        tokio::pin!(work);
        let mut renewal = tokio::time::interval(LEASE_TTL / 3);
        renewal.tick().await;
        loop {
            tokio::select! {
                biased;
                _ = renewal.tick() => {
                    let owned = tokio::time::timeout(Duration::from_secs(5), self.store.renew_lease(&self.key, &self.token, LEASE_TTL)).await
                        .map_err(|_| NscaleError::Store("lease renewal timed out".into()))??;
                    if !owned { return Err(NscaleError::Store("scaling lease lost".into())); }
                }
                result = &mut work => return result,
            }
        }
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if self.released {
            return;
        }
        let store = self.store.clone();
        let key = self.key.clone();
        let token = self.token.clone();
        tokio::spawn(async move {
            if let Err(error) = store.release_lease(&key, &token).await {
                tracing::warn!(%error, %key, "lease release failed");
            }
        });
    }
}
