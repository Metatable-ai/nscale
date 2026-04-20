use std::sync::Arc;
use std::task::{Context, Poll};

use axum::body::Body;
use axum::http::{Request, header};
use tower::{Layer, Service};
use tracing::{debug, warn};

use nscale_core::job::JobId;
use nscale_core::traits::ActivityStore;

// ──────────────────────────────────
// Job ID extraction
// ──────────────────────────────────

/// Extract the job identifier from a raw `Host` header value.
///
/// The first label before the first `.` is used, and any trailing `:port`
/// is stripped.  Returns `None` only when the input is empty.
fn extract_job_id_from_host(host: &str) -> Option<String> {
    let label = host.split('.').next().unwrap_or(host);
    let label = label.split(':').next().unwrap_or(label);
    if label.is_empty() {
        None
    } else {
        Some(label.to_string())
    }
}

// ──────────────────────────────────
// Activity recording layer
// ──────────────────────────────────

/// Tower layer that wraps services to record activity after each request.
#[derive(Clone)]
pub struct ActivityLayer {
    store: Arc<dyn ActivityStore>,
}

impl ActivityLayer {
    pub fn new(store: Arc<dyn ActivityStore>) -> Self {
        Self { store }
    }
}

impl<S> Layer<S> for ActivityLayer {
    type Service = ActivityService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        ActivityService {
            inner,
            store: self.store.clone(),
        }
    }
}

/// Tower service wrapper that records activity for each inbound request.
#[derive(Clone)]
pub struct ActivityService<S> {
    inner: S,
    store: Arc<dyn ActivityStore>,
}

impl<S> Service<Request<Body>> for ActivityService<S>
where
    S: Service<Request<Body>> + Clone + Send + 'static,
    S::Future: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<Self::Response, Self::Error>> + Send>,
    >;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: Request<Body>) -> Self::Future {
        // Extract job id from Host header before passing request to inner service
        let job_id = req
            .headers()
            .get(header::HOST)
            .and_then(|v| v.to_str().ok())
            .and_then(extract_job_id_from_host);

        let store = self.store.clone();
        let future = self.inner.call(req);

        Box::pin(async move {
            // Record activity at request START so the idle timer is pushed
            // forward immediately — this protects against scale-down during
            // long-running requests.
            if let Some(ref id) = job_id {
                let job = JobId(id.clone());
                debug!(job_id = %id, source = "middleware-start", "recording activity");
                if let Err(e) = store.record_activity(&job).await {
                    warn!(job_id = %id, error = %e, "failed to record start activity");
                }
            }

            let response = future.await?;

            // Also record activity at request END (fire-and-forget)
            if let Some(id) = job_id {
                let store = store.clone();
                tokio::spawn(async move {
                    let job = JobId(id.clone());
                    debug!(job_id = %id, source = "middleware-end", "recording activity");
                    if let Err(e) = store.record_activity(&job).await {
                        warn!(job_id = %id, error = %e, "failed to record activity");
                    }
                });
            }

            Ok(response)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_hostname() {
        assert_eq!(
            extract_job_id_from_host("my-service"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_domain() {
        assert_eq!(
            extract_job_id_from_host("my-service.example.com"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_port() {
        assert_eq!(
            extract_job_id_from_host("my-service:8080"),
            Some("my-service".into())
        );
    }

    #[test]
    fn hostname_with_domain_and_port() {
        assert_eq!(
            extract_job_id_from_host("my-service.example.com:443"),
            Some("my-service".into())
        );
    }

    #[test]
    fn subdomain_chain() {
        assert_eq!(
            extract_job_id_from_host("my-service.sub.example.com"),
            Some("my-service".into())
        );
    }

    #[test]
    fn ip_address_host() {
        assert_eq!(extract_job_id_from_host("192.168.1.1"), Some("192".into()));
    }

    #[test]
    fn ip_address_with_port() {
        assert_eq!(
            extract_job_id_from_host("192.168.1.1:3000"),
            Some("192".into())
        );
    }

    #[test]
    fn empty_host_returns_none() {
        assert_eq!(extract_job_id_from_host(""), None);
    }

    #[test]
    fn port_only_returns_none() {
        // ":8080" -> first split on '.' is ":8080", split on ':' -> ""
        assert_eq!(extract_job_id_from_host(":8080"), None);
    }

    #[test]
    fn localhost() {
        assert_eq!(
            extract_job_id_from_host("localhost"),
            Some("localhost".into())
        );
    }

    #[test]
    fn localhost_with_port() {
        assert_eq!(
            extract_job_id_from_host("localhost:3000"),
            Some("localhost".into())
        );
    }

    #[test]
    fn hyphenated_job_name() {
        assert_eq!(
            extract_job_id_from_host("my-cool-service.traefik.local:9999"),
            Some("my-cool-service".into())
        );
    }
}
