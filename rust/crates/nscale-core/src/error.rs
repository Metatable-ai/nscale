use thiserror::Error;

#[derive(Error, Debug)]
pub enum NscaleError {
    #[error("nomad API error: {0}")]
    Nomad(String),

    #[error("consul API error: {0}")]
    Consul(String),

    #[error("store error: {0}")]
    Store(String),

    #[error("proxy error: {0}")]
    Proxy(String),

    #[error("wake timeout for job {job_id} after {elapsed_secs:.1}s")]
    WakeTimeout { job_id: String, elapsed_secs: f64 },

    #[error("job not found: {0}")]
    JobNotFound(String),

    #[error("job not ready: {0}")]
    JobNotReady(String),

    #[error("configuration error: {0}")]
    Config(String),

    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, NscaleError>;
