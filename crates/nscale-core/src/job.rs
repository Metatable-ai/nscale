use std::fmt;
use std::time::Duration;

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autoscaling: Option<JobAutoscalingPolicy>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub traefik_routers: Vec<String>,
}

/// Per-job autoscaling policy attached to a registration.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobAutoscalingPolicy {
    #[serde(default = "default_job_autoscaling_enabled")]
    pub enabled: bool,
    #[serde(default = "default_job_autoscaling_min_count")]
    pub min_count: u32,
    pub max_count: u32,
    #[serde(default = "default_job_autoscaling_scale_to_zero")]
    pub scale_to_zero: bool,
    #[serde(default = "default_job_autoscaling_scale_step")]
    pub scale_up_step: u32,
    #[serde(default = "default_job_autoscaling_scale_step")]
    pub scale_down_step: u32,
    #[serde(default)]
    pub target_requests_per_second_per_instance: Option<f64>,
    #[serde(default)]
    pub target_p95_latency_ms: Option<f64>,
    #[serde(default)]
    pub max_error_rate: Option<f64>,
    #[serde(default)]
    pub cooldown_secs: Option<u64>,
    #[serde(default)]
    pub decision_window_secs: Option<u64>,
}

impl JobAutoscalingPolicy {
    pub fn validate(&self) -> Result<(), String> {
        if self.max_count < self.min_count {
            return Err("autoscaling max_count must be greater than or equal to min_count".into());
        }

        if self.scale_up_step == 0 {
            return Err("autoscaling scale_up_step must be greater than zero".into());
        }

        if self.scale_down_step == 0 {
            return Err("autoscaling scale_down_step must be greater than zero".into());
        }

        if self.cooldown_secs == Some(0) {
            return Err("autoscaling cooldown_secs must be greater than zero".into());
        }

        if self.decision_window_secs == Some(0) {
            return Err("autoscaling decision_window_secs must be greater than zero".into());
        }

        if self.target_requests_per_second_per_instance.is_none()
            && self.target_p95_latency_ms.is_none()
            && self.max_error_rate.is_none()
        {
            return Err("autoscaling policy must define at least one metric target".into());
        }

        Ok(())
    }

    pub fn cooldown(&self, default: Duration) -> Duration {
        self.cooldown_secs
            .map(Duration::from_secs)
            .unwrap_or(default)
    }

    pub fn decision_window(&self, default: Duration) -> Duration {
        self.decision_window_secs
            .map(Duration::from_secs)
            .unwrap_or(default)
    }
}

fn default_job_autoscaling_enabled() -> bool {
    true
}

fn default_job_autoscaling_min_count() -> u32 {
    1
}

fn default_job_autoscaling_scale_to_zero() -> bool {
    true
}

fn default_job_autoscaling_scale_step() -> u32 {
    1
}

/// Current state of a managed job in the coordinator.
#[derive(Debug, Clone)]
pub enum JobState {
    /// Job is scaled to zero, no allocations running.
    Dormant,
    /// Scale-up has been requested, waiting for healthy allocation.
    Waking { since: tokio::time::Instant },
    /// Job is running and healthy, endpoint is known.
    Ready { endpoint: Endpoint },
    /// Idle timeout reached, scale-down in progress.
    Draining { since: tokio::time::Instant },
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registration_without_autoscaling_deserializes() {
        let json = r#"{
            "job_id": "api",
            "service_name": "api-service",
            "nomad_group": "web"
        }"#;

        let registration: JobRegistration = serde_json::from_str(json).unwrap();

        assert_eq!(registration.job_id, JobId("api".to_string()));
        assert_eq!(
            registration.service_name,
            ServiceName("api-service".to_string())
        );
        assert_eq!(registration.nomad_group, "web");
        assert!(registration.autoscaling.is_none());
    }

    #[test]
    fn autoscaling_policy_deserializes_with_defaults() {
        let json = r#"{
            "job_id": "api",
            "service_name": "api-service",
            "nomad_group": "web",
            "autoscaling": {
                "max_count": 5,
                "target_requests_per_second_per_instance": 25.0
            }
        }"#;

        let registration: JobRegistration = serde_json::from_str(json).unwrap();
        let policy = registration.autoscaling.unwrap();

        assert!(policy.enabled);
        assert_eq!(policy.min_count, 1);
        assert_eq!(policy.max_count, 5);
        assert!(policy.scale_to_zero);
        assert_eq!(policy.scale_up_step, 1);
        assert_eq!(policy.scale_down_step, 1);
        assert_eq!(policy.target_requests_per_second_per_instance, Some(25.0));
        assert_eq!(policy.target_p95_latency_ms, None);
        assert_eq!(policy.max_error_rate, None);
        assert_eq!(policy.cooldown_secs, None);
        assert_eq!(policy.decision_window_secs, None);
    }

    #[test]
    fn autoscaling_policy_deserializes_timing_overrides() {
        let json = r#"{
            "job_id": "api",
            "service_name": "api-service",
            "nomad_group": "web",
            "autoscaling": {
                "max_count": 5,
                "cooldown_secs": 20,
                "decision_window_secs": 30,
                "target_requests_per_second_per_instance": 25.0
            }
        }"#;

        let registration: JobRegistration = serde_json::from_str(json).unwrap();
        let policy = registration.autoscaling.unwrap();

        assert_eq!(policy.cooldown_secs, Some(20));
        assert_eq!(policy.decision_window_secs, Some(30));
        assert_eq!(
            policy.cooldown(std::time::Duration::from_secs(120)),
            std::time::Duration::from_secs(20)
        );
        assert_eq!(
            policy.decision_window(std::time::Duration::from_secs(60)),
            std::time::Duration::from_secs(30)
        );
    }

    #[test]
    fn autoscaling_policy_requires_max_count() {
        let json = r#"{
            "job_id": "api",
            "service_name": "api-service",
            "nomad_group": "web",
            "autoscaling": {
                "target_requests_per_second_per_instance": 25.0
            }
        }"#;

        let result = serde_json::from_str::<JobRegistration>(json);

        assert!(result.is_err());
    }

    #[test]
    fn autoscaling_policy_validation_rejects_invalid_caps() {
        let policy = JobAutoscalingPolicy {
            enabled: true,
            min_count: 3,
            max_count: 2,
            scale_to_zero: true,
            scale_up_step: 1,
            scale_down_step: 1,
            target_requests_per_second_per_instance: Some(25.0),
            target_p95_latency_ms: None,
            max_error_rate: None,
            cooldown_secs: None,
            decision_window_secs: None,
        };

        assert!(policy.validate().is_err());
    }

    #[test]
    fn autoscaling_policy_validation_rejects_missing_targets() {
        let policy = JobAutoscalingPolicy {
            enabled: true,
            min_count: 1,
            max_count: 2,
            scale_to_zero: true,
            scale_up_step: 1,
            scale_down_step: 1,
            target_requests_per_second_per_instance: None,
            target_p95_latency_ms: None,
            max_error_rate: None,
            cooldown_secs: None,
            decision_window_secs: None,
        };

        assert!(policy.validate().is_err());
    }

    #[test]
    fn autoscaling_policy_validation_rejects_zero_timing_overrides() {
        let policy = JobAutoscalingPolicy {
            enabled: true,
            min_count: 1,
            max_count: 2,
            scale_to_zero: true,
            scale_up_step: 1,
            scale_down_step: 1,
            target_requests_per_second_per_instance: Some(25.0),
            target_p95_latency_ms: None,
            max_error_rate: None,
            cooldown_secs: Some(0),
            decision_window_secs: Some(30),
        };

        assert!(policy.validate().is_err());

        let policy = JobAutoscalingPolicy {
            cooldown_secs: Some(20),
            decision_window_secs: Some(0),
            ..policy
        };

        assert!(policy.validate().is_err());
    }
}
