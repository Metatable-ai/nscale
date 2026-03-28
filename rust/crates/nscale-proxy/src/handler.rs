use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{header, Request, StatusCode},
    response::{IntoResponse, Response},
};
use tracing::{error, info, instrument, warn};

use nscale_core::job::JobId;
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::WakeCoordinator;

use crate::proxy::forward_request;

/// Shared application state for the proxy handler.
#[derive(Clone)]
pub struct AppState {
    pub coordinator: Arc<WakeCoordinator>,
    pub registry: Arc<JobRegistry>,
    pub http_client: reqwest::Client,
}

/// Main request handler.
///
/// 1. Extract service name from the `Host` header (first label before `.`).
/// 2. Look up the `JobRegistration` in the Redis-backed registry.
/// 3. Ensure the backing job is running (wake if dormant).
/// 4. Forward the request to the healthy backend.
#[instrument(skip_all, fields(host))]
pub async fn proxy_handler(
    State(state): State<AppState>,
    req: Request<Body>,
) -> Response {
    // --- 1. Extract service identifier from Host header ---
    let host_value = match req.headers().get(header::HOST) {
        Some(v) => v.to_str().unwrap_or_default().to_string(),
        None => {
            warn!("request missing Host header");
            return (StatusCode::BAD_REQUEST, "missing Host header").into_response();
        }
    };

    // Use the first label of the host (before the first dot or colon) as the job id.
    let service_key = host_value
        .split('.')
        .next()
        .unwrap_or(&host_value)
        .split(':')
        .next()
        .unwrap_or(&host_value)
        .to_string();

    tracing::Span::current().record("host", &service_key.as_str());

    // --- 2. Look up job registration ---
    let job_id = JobId(service_key.clone());
    let registration = match state.registry.get(&job_id).await {
        Ok(Some(reg)) => reg,
        Ok(None) => {
            warn!(job_id = %job_id, "job not found in registry");
            return (StatusCode::NOT_FOUND, "service not registered").into_response();
        }
        Err(e) => {
            error!(error = %e, "registry lookup failed");
            return (StatusCode::INTERNAL_SERVER_ERROR, "registry error").into_response();
        }
    };

    // --- 3. Ensure running (wake if dormant) ---
    let endpoint = match state.coordinator.ensure_running(&registration).await {
        Ok(ep) => ep,
        Err(e) => {
            error!(job_id = %job_id, error = %e, "wake failed");
            return (StatusCode::SERVICE_UNAVAILABLE, format!("wake error: {e}"))
                .into_response();
        }
    };

    info!(
        job_id = %job_id,
        endpoint = %endpoint,
        "routing request to backend"
    );

    // --- 4. Forward request to backend; retry once on connection failure ---
    match forward_request(&state.http_client, &endpoint, req).await {
        Ok(resp) => resp,
        Err(_status) => {
            // Backend unreachable — stale cache. Invalidate and re-wake.
            warn!(
                job_id = %job_id,
                endpoint = %endpoint,
                "backend unreachable, invalidating cache and re-waking"
            );
            state.coordinator.invalidate(&job_id);

            let endpoint = match state.coordinator.ensure_running(&registration).await {
                Ok(ep) => ep,
                Err(e) => {
                    error!(job_id = %job_id, error = %e, "retry wake failed");
                    return (StatusCode::SERVICE_UNAVAILABLE, format!("retry wake error: {e}"))
                        .into_response();
                }
            };

            info!(
                job_id = %job_id,
                endpoint = %endpoint,
                "retry: routing request to new backend"
            );

            // Build a minimal GET request to the same path since we consumed the original body
            let retry_req = Request::builder()
                .method(axum::http::Method::GET)
                .uri("/")
                .body(Body::empty())
                .unwrap();

            match forward_request(&state.http_client, &endpoint, retry_req).await {
                Ok(resp) => resp,
                Err(status) => status.into_response(),
            }
        }
    }
}
