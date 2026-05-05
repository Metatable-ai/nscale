use std::pin::Pin;
use std::time::Duration;

use async_trait::async_trait;
use futures_core::Stream;

use crate::error::Result;
use crate::job::{Endpoint, JobId, JobRegistration, ServiceName};

/// Abstraction over a job orchestrator (Nomad).
#[async_trait]
pub trait Orchestrator: Send + Sync {
    /// Scale a job up to the given count.
    async fn scale_up(&self, job_id: &JobId, group: &str, count: u32) -> Result<()>;

    /// Scale a job down to zero.
    async fn scale_down(&self, job_id: &JobId, group: &str) -> Result<()>;

    /// Get the current count for a job's task group.
    async fn get_job_count(&self, job_id: &JobId, group: &str) -> Result<u32>;

    /// Get a healthy endpoint for a running job.
    /// Returns `None` if no healthy allocation exists.
    async fn get_healthy_endpoint(&self, job_id: &JobId) -> Result<Option<Endpoint>>;
}

/// Abstraction over a service discovery system (Consul).
#[async_trait]
pub trait ServiceDiscovery: Send + Sync {
    /// Register the scale-to-zero proxy as a fallback service.
    async fn register_fallback(
        &self,
        service_name: &ServiceName,
        proxy_endpoint: &Endpoint,
    ) -> Result<()>;

    /// Deregister the fallback service for a given service name.
    async fn deregister_fallback(&self, service_name: &ServiceName) -> Result<()>;

    /// Wait for a healthy service instance to appear, using blocking queries.
    /// Returns the endpoint once healthy, or errors on timeout.
    async fn wait_for_healthy(
        &self,
        service_name: &ServiceName,
        timeout: Duration,
    ) -> Result<Endpoint>;
}

/// Abstraction over the activity tracking store (Redis).
#[async_trait]
pub trait ActivityStore: Send + Sync {
    /// Record that a job was accessed at the current time.
    async fn record_activity(&self, job_id: &JobId) -> Result<()>;

    /// Get all jobs that have been idle longer than the given threshold.
    async fn get_idle_jobs(&self, idle_threshold: Duration) -> Result<Vec<JobId>>;

    /// Check whether a job has an activity record (any score at all).
    async fn has_activity(&self, job_id: &JobId) -> Result<bool>;

    /// Attempt to acquire a distributed lock. Returns `true` if acquired.
    async fn try_acquire_lock(&self, key: &str, ttl: Duration) -> Result<bool>;

    /// Release a distributed lock.
    async fn release_lock(&self, key: &str) -> Result<()>;

    /// Remove activity tracking for a job (after scale-down).
    async fn remove_activity(&self, job_id: &JobId) -> Result<()>;
}

/// Change notification emitted by a durable registration store.
#[derive(Debug, Clone)]
pub enum RegistrationEvent {
    Upsert(JobRegistration),
    Remove(JobRegistration),
}

/// Abstraction over a durable registration store.
#[async_trait]
pub trait DurableRegistry: Send + Sync {
    /// Store or update a job registration durably.
    async fn store_registration(&self, reg: &JobRegistration) -> Result<()>;

    /// Remove a registration from durable storage.
    async fn remove_registration(&self, job_id: &JobId) -> Result<()>;

    /// Look up a registration by job id.
    async fn get_by_job_id(&self, job_id: &JobId) -> Result<Option<JobRegistration>>;

    /// Look up a registration by service name.
    async fn get_by_service_name(
        &self,
        service_name: &ServiceName,
    ) -> Result<Option<JobRegistration>>;

    /// List all current registrations.
    async fn list_all(&self) -> Result<Vec<JobRegistration>>;

    /// Watch for registration changes.
    async fn watch_registrations(
        &self,
    ) -> Result<Pin<Box<dyn Stream<Item = RegistrationEvent> + Send>>>;
}
