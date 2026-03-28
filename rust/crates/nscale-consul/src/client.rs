use reqwest::header::{HeaderMap, HeaderValue};

use nscale_core::error::{NscaleError, Result};

pub struct ConsulClient {
    pub(crate) client: reqwest::Client,
    pub(crate) base_url: String,
}

impl ConsulClient {
    pub fn new(addr: &str, token: Option<&str>) -> Result<Self> {
        let mut headers = HeaderMap::new();
        if let Some(t) = token {
            headers.insert(
                "X-Consul-Token",
                HeaderValue::from_str(t).map_err(|e| NscaleError::Consul(e.to_string()))?,
            );
        }

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .pool_max_idle_per_host(10)
            .build()?;

        Ok(Self {
            client,
            base_url: addr.trim_end_matches('/').to_string(),
        })
    }

    pub(crate) fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }
}
