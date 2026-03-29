use std::net::SocketAddr;
use std::time::Duration;

use figment::{
    providers::{Env, Format, Serialized, Toml},
    Figment,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: SocketAddr,
    pub admin_addr: SocketAddr,
    pub nomad: NomadConfig,
    pub consul: ConsulConfig,
    pub redis: RedisConfig,
    pub scaling: ScalingConfig,
    pub proxy: ProxyConfig,
    #[serde(default)]
    pub traefik: Option<TraefikConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NomadConfig {
    pub addr: String,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default = "default_nomad_concurrency")]
    pub concurrency: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsulConfig {
    pub addr: String,
    #[serde(default)]
    pub token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedisConfig {
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScalingConfig {
    #[serde(default = "default_idle_timeout")]
    pub idle_timeout_secs: u64,
    #[serde(default = "default_wake_timeout")]
    pub wake_timeout_secs: u64,
    #[serde(default = "default_scale_down_interval")]
    pub scale_down_interval_secs: u64,
    #[serde(default = "default_min_scale_down_age")]
    pub min_scale_down_age_secs: u64,
}

impl ScalingConfig {
    pub fn idle_timeout(&self) -> Duration {
        Duration::from_secs(self.idle_timeout_secs)
    }

    pub fn wake_timeout(&self) -> Duration {
        Duration::from_secs(self.wake_timeout_secs)
    }

    pub fn scale_down_interval(&self) -> Duration {
        Duration::from_secs(self.scale_down_interval_secs)
    }

    pub fn min_scale_down_age(&self) -> Duration {
        Duration::from_secs(self.min_scale_down_age_secs)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraefikConfig {
    /// Base URL for Traefik's metrics endpoint, e.g. "http://traefik:8082"
    pub metrics_url: String,
    /// Consul Catalog provider name used in Traefik service labels.
    #[serde(default = "default_traefik_provider")]
    pub provider: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyConfig {
    #[serde(default = "default_request_timeout")]
    pub request_timeout_secs: u64,
    #[serde(default = "default_request_buffer_size")]
    pub request_buffer_size: usize,
}

impl ProxyConfig {
    pub fn request_timeout(&self) -> Duration {
        Duration::from_secs(self.request_timeout_secs)
    }
}

fn default_nomad_concurrency() -> usize {
    50
}
fn default_idle_timeout() -> u64 {
    300
}
fn default_wake_timeout() -> u64 {
    60
}
fn default_scale_down_interval() -> u64 {
    30
}
fn default_min_scale_down_age() -> u64 {
    120
}
fn default_request_timeout() -> u64 {
    30
}
fn default_request_buffer_size() -> usize {
    1000
}
fn default_traefik_provider() -> String {
    "consulcatalog".to_string()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen_addr: "0.0.0.0:8080".parse().unwrap(),
            admin_addr: "0.0.0.0:9090".parse().unwrap(),
            nomad: NomadConfig {
                addr: "http://localhost:4646".into(),
                token: None,
                concurrency: default_nomad_concurrency(),
            },
            consul: ConsulConfig {
                addr: "http://localhost:8500".into(),
                token: None,
            },
            redis: RedisConfig {
                url: "redis://localhost:6379".into(),
            },
            scaling: ScalingConfig {
                idle_timeout_secs: default_idle_timeout(),
                wake_timeout_secs: default_wake_timeout(),
                scale_down_interval_secs: default_scale_down_interval(),
                min_scale_down_age_secs: default_min_scale_down_age(),
            },
            proxy: ProxyConfig {
                request_timeout_secs: default_request_timeout(),
                request_buffer_size: default_request_buffer_size(),
            },
            traefik: None,
        }
    }
}

impl Config {
    /// Load configuration from: defaults → config/default.toml → NSCALE_* env vars.
    pub fn load() -> std::result::Result<Self, figment::Error> {
        Figment::from(Serialized::defaults(Config::default()))
            .merge(Toml::file("config/default.toml").nested())
            .merge(Env::prefixed("NSCALE_").split("__"))
            .extract()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let cfg = Config::default();
        assert_eq!(cfg.listen_addr.port(), 8080);
        assert_eq!(cfg.admin_addr.port(), 9090);
        assert_eq!(cfg.nomad.concurrency, 50);
        assert_eq!(cfg.scaling.idle_timeout_secs, 300);
        assert_eq!(cfg.scaling.wake_timeout().as_secs(), 60);
        assert_eq!(cfg.proxy.request_timeout().as_secs(), 30);
    }
}
