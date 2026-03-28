use std::fmt;

use serde::{Deserialize, Serialize};

/// Unique identifier for a Nomad job.
#[derive(Debug, Clone, Hash, Eq, PartialEq, Serialize, Deserialize)]
pub struct JobId(pub String);

impl fmt::Display for JobId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<String> for JobId {
    fn from(s: String) -> Self {
        Self(s)
    }
}

impl From<&str> for JobId {
    fn from(s: &str) -> Self {
        Self(s.to_owned())
    }
}

/// Consul service name associated with a Nomad job.
#[derive(Debug, Clone, Hash, Eq, PartialEq, Serialize, Deserialize)]
pub struct ServiceName(pub String);

impl fmt::Display for ServiceName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<String> for ServiceName {
    fn from(s: String) -> Self {
        Self(s)
    }
}

impl From<&str> for ServiceName {
    fn from(s: &str) -> Self {
        Self(s.to_owned())
    }
}

/// A network endpoint for a running service.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

impl Endpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
        }
    }

    pub fn address(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }

    pub fn base_url(&self, scheme: &str) -> String {
        format!("{}://{}:{}", scheme, self.host, self.port)
    }
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.host, self.port)
    }
}

/// Registration entry for a managed job.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRegistration {
    pub job_id: JobId,
    pub service_name: ServiceName,
    pub nomad_group: String,
}

/// Current state of a managed job in the coordinator.
#[derive(Debug, Clone)]
pub enum JobState {
    /// Job is scaled to zero, no allocations running.
    Dormant,
    /// Scale-up has been requested, waiting for healthy allocation.
    Waking {
        since: tokio::time::Instant,
    },
    /// Job is running and healthy, endpoint is known.
    Ready {
        endpoint: Endpoint,
    },
    /// Idle timeout reached, scale-down in progress.
    Draining {
        since: tokio::time::Instant,
    },
}

impl JobState {
    pub fn is_dormant(&self) -> bool {
        matches!(self, Self::Dormant)
    }

    pub fn is_waking(&self) -> bool {
        matches!(self, Self::Waking { .. })
    }

    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready { .. })
    }

    pub fn is_draining(&self) -> bool {
        matches!(self, Self::Draining { .. })
    }
}
