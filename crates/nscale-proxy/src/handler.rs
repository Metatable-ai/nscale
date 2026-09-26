use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    body::Body,
    extract::State,
    http::{Method, Request, StatusCode, header},
    response::{IntoResponse, Response},
};
use tracing::{debug, error, info, instrument, warn};

use nscale_core::error::{NscaleError, Result};
use nscale_core::inflight::InFlightTracker;
use nscale_core::job::{JobId, ServiceName};
use nscale_core::traits::{ActivityStore, MissingJobTracker};
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::{EndpointRefresh, WakeCoordinator};

use crate::metrics::ProxyMetrics;
use crate::proxy::forward_request;

const REQUEST_LEASE_TTL: Duration = Duration::from_secs(30);

const TRANSIENT_RETRY_BACKOFF_MS: [u64; 2] = [100, 250];

struct CancelOnDrop(tokio_util::sync::CancellationToken);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

/// Shared application state for the proxy handler.
#[derive(Clone)]
pub struct AppState {
    pub coordinator: Arc<WakeCoordinator>,
    pub registry: Arc<JobRegistry>,
    pub http_client: reqwest::Client,
    pub in_flight: InFlightTracker,
    pub activity_store: Arc<dyn ActivityStore>,
    pub missing_job_tracker: Arc<dyn MissingJobTracker>,
    pub proxy_metrics: ProxyMetrics,
    /// Interval for refreshing activity during long-running proxied requests.
    pub heartbeat_interval: Duration,
    pub auto_deregister_enabled: bool,
    pub auto_deregister_threshold: u32,
}

/// Only empty GET/HEAD bodies can be replayed without buffering the request.
struct RetryRequest {
    method: Method,
    uri: axum::http::Uri,
    headers: axum::http::HeaderMap,
    version: axum::http::Version,
}

impl RetryRequest {
    fn capture(req: &Request<Body>) -> Option<Self> {
        if !matches!(*req.method(), Method::GET | Method::HEAD)
            || !hyper::body::Body::is_end_stream(req.body())
        {
            return None;
        }
        Some(Self {
            method: req.method().clone(),
            uri: req.uri().clone(),
            headers: req.headers().clone(),
            version: req.version(),
        })
    }

    fn build(&self) -> Request<Body> {
        let mut request = Request::new(Body::empty());
        *request.method_mut() = self.method.clone();
        *request.uri_mut() = self.uri.clone();
        *request.headers_mut() = self.headers.clone();
        *request.version_mut() = self.version;
        request
    }
}

async fn clear_missing_job_counter(state: &AppState, job_id: &JobId) {
    if !state.auto_deregister_enabled {
        return;
    }

    if let Err(e) = state.missing_job_tracker.clear_not_found(job_id).await {
        warn!(job_id = %job_id, error = %e, "failed to clear missing-job counter");
    }
}

async fn cleanup_missing_job_state(state: &AppState, job_id: &JobId) -> Result<()> {
    for reg in state
        .registry
        .list_all()
        .await?
        .iter()
        .filter(|reg| reg.job_id == *job_id)
    {
        let unit = reg.scale_unit_key();
        state.coordinator.mark_dormant(&unit);
        state.activity_store.remove_activity(&unit).await?;
    }
    state.registry.deregister(job_id).await?;

    if let Err(e) = state.missing_job_tracker.clear_not_found(job_id).await {
        warn!(job_id = %job_id, error = %e, "failed to clear missing-job counter after auto-deregister");
    }

    Ok(())
}

async fn handle_missing_job(state: &AppState, job_id: &JobId, source: &'static str) -> Response {
    if !state.auto_deregister_enabled {
        warn!(job_id = %job_id, source, "registered job missing in Nomad but auto-deregister is disabled");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            format!("service missing in Nomad during {source}"),
        )
            .into_response();
    }

    let count = match state.missing_job_tracker.increment_not_found(job_id).await {
        Ok(count) => count,
        Err(e) => {
            error!(job_id = %job_id, source, error = %e, "failed to increment missing-job counter");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "service unavailable while tracking stale registration",
            )
                .into_response();
        }
    };

    if count >= state.auto_deregister_threshold {
        match cleanup_missing_job_state(state, job_id).await {
            Ok(()) => {
                warn!(
                    job_id = %job_id,
                    source,
                    count,
                    threshold = state.auto_deregister_threshold,
                    "auto-deregistered stale job after repeated Nomad missing-job responses"
                );
                (StatusCode::NOT_FOUND, "service not registered").into_response()
            }
            Err(e) => {
                error!(
                    job_id = %job_id,
                    source,
                    count,
                    threshold = state.auto_deregister_threshold,
                    error = %e,
                    "failed to auto-deregister stale job after missing-job threshold"
                );
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    format!("service missing in Nomad and cleanup failed: {e}"),
                )
                    .into_response()
            }
        }
    } else {
        warn!(
            job_id = %job_id,
            source,
            count,
            threshold = state.auto_deregister_threshold,
            "registered job missing in Nomad"
        );
        (
            StatusCode::SERVICE_UNAVAILABLE,
            format!(
                "service missing in Nomad ({count}/{})",
                state.auto_deregister_threshold
            ),
        )
            .into_response()
    }
}

/// Main request handler.
///
/// 1. Extract service name from the `Host` header (first label before `.`).
/// 2. Look up the `JobRegistration` in the Redis-backed registry.
/// 3. Ensure the backing job is running (wake if dormant).
/// 4. Forward the request to the healthy backend.
#[instrument(skip_all, fields(host))]
pub async fn proxy_handler(State(state): State<AppState>, req: Request<Body>) -> Response {
    // --- 1. Extract service identifier from Host header ---
    let host_value = match req.headers().get(header::HOST) {
        Some(v) => v.to_str().unwrap_or_default().to_string(),
        None => {
            warn!("request missing Host header");
            return (StatusCode::BAD_REQUEST, "missing Host header").into_response();
        }
    };

    // Use the first label of the host (before the first dot or colon) as the service name.
    let service_key = host_value
        .split('.')
        .next()
        .unwrap_or(&host_value)
        .split(':')
        .next()
        .unwrap_or(&host_value)
        .to_string();

    tracing::Span::current().record("host", service_key.as_str());

    // --- 2. Look up job registration ---
    let service_name = ServiceName(service_key);
    let registration = match state.registry.get_by_service_name(&service_name).await {
        Ok(Some(reg)) => reg,
        Ok(None) => {
            warn!(%service_name, "service not found in registry");
            return (StatusCode::NOT_FOUND, "service not registered").into_response();
        }
        Err(e) => {
            error!(error = %e, "registry lookup failed");
            return (StatusCode::INTERNAL_SERVER_ERROR, "registry error").into_response();
        }
    };
    let job_id = registration.job_id.clone();
    let unit = registration.scale_unit_key();
    let request_started = Instant::now();
    let request_token = nscale_core::lease::unique_token();
    if let Err(error) = state
        .activity_store
        .refresh_request(&unit, &request_token, REQUEST_LEASE_TTL)
        .await
    {
        warn!(%error, "request admission unavailable");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "activity store unavailable",
        )
            .into_response();
    }

    if let Err(e) = state.activity_store.record_activity(&unit).await {
        warn!(job_id = %job_id, unit = %unit, error = %e, "failed to record unit activity at request start");
    }

    // --- Track in-flight request so the scale-down controller skips this unit ---
    let in_flight_guard = state.in_flight.track(&unit.0);

    // Spawn a heartbeat that refreshes activity while the proxy request is in-flight.
    // This prevents the scale-down controller from treating the unit as idle during
    // long-running requests.
    let heartbeat_store = state.activity_store.clone();
    let heartbeat_unit = unit.clone();
    let heartbeat_request = request_token.clone();
    let heartbeat_interval = state
        .heartbeat_interval
        .clamp(Duration::from_millis(100), Duration::from_secs(5));
    let heartbeat_cancel = tokio_util::sync::CancellationToken::new();
    let heartbeat_cancel_clone = heartbeat_cancel.clone();
    let heartbeat_cancel_guard = CancelOnDrop(heartbeat_cancel.clone());

    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(heartbeat_interval);
        ticker.tick().await; // first tick is immediate, skip it
        loop {
            tokio::select! {
                _ = heartbeat_cancel_clone.cancelled() => break,
                _ = ticker.tick() => {
                    debug!(unit = %heartbeat_unit, source = "heartbeat", "recording activity");
                    if let Err(error) = heartbeat_store.refresh_request(&heartbeat_unit, &heartbeat_request, REQUEST_LEASE_TTL).await {
                        warn!(%error, "request lease renewal failed");
                    }
                    if let Err(e) = heartbeat_store.record_activity(&heartbeat_unit).await {
                        warn!(unit = %heartbeat_unit, error = %e, "activity heartbeat failed");
                    }
                }
            }
        }
    });

    let lifetime = RequestLifetime {
        _in_flight: in_flight_guard,
        _heartbeat: heartbeat_cancel_guard,
        metrics: state.proxy_metrics.clone(),
        job_id: job_id.clone(),
        service: registration.service_name.clone(),
        started: request_started,
        status: 499,
        shared: Some((state.activity_store.clone(), unit.clone(), request_token)),
    };
    let response = proxy_registered(&state, &registration, req).await;
    track_response(response, lifetime)
}

async fn proxy_registered(
    state: &AppState,
    registration: &nscale_core::job::JobRegistration,
    req: Request<Body>,
) -> Response {
    let job_id = registration.job_id.clone();

    // --- 3. Ensure running (wake if dormant) ---
    let wake_started = Instant::now();
    let endpoint = match state.coordinator.ensure_running(registration).await {
        Ok(ep) => {
            state.proxy_metrics.record_wake(
                &job_id,
                &registration.service_name,
                "success",
                wake_started.elapsed(),
            );
            clear_missing_job_counter(state, &job_id).await;
            ep
        }
        Err(NscaleError::JobNotFound(_)) => {
            state.proxy_metrics.record_wake(
                &job_id,
                &registration.service_name,
                "job-not-found",
                wake_started.elapsed(),
            );
            return handle_missing_job(state, &job_id, "wake").await;
        }
        Err(e) => {
            state.proxy_metrics.record_wake(
                &job_id,
                &registration.service_name,
                "error",
                wake_started.elapsed(),
            );
            error!(job_id = %job_id, error = %e, "wake failed");
            return (StatusCode::SERVICE_UNAVAILABLE, format!("wake error: {e}")).into_response();
        }
    };

    info!(
        job_id = %job_id,
        endpoint = %endpoint,
        "routing request to backend"
    );

    let retry_request = RetryRequest::capture(&req);

    // --- 4. Forward request to backend; retry transient transport failures ---
    match forward_request(&state.http_client, &endpoint, req).await {
        Ok(resp) => resp,
        Err(err) if !err.is_retryable_transport() => {
            error!(
                job_id = %job_id,
                endpoint = %endpoint,
                error = %err,
                status = ?err.response_status(),
                "backend request failed"
            );
            err.status_code().into_response()
        }
        Err(mut err) => {
            let Some(retry_request) = retry_request else {
                error!(
                    job_id = %job_id,
                    endpoint = %endpoint,
                    error = %err,
                    is_connect = err.is_connect(),
                    is_timeout = err.is_timeout(),
                    status = ?err.response_status(),
                    "backend request failed and request is not safe to replay"
                );
                return err.status_code().into_response();
            };

            for (attempt, delay_ms) in TRANSIENT_RETRY_BACKOFF_MS.iter().enumerate() {
                tokio::time::sleep(Duration::from_millis(*delay_ms)).await;

                let retry_req = retry_request.build();
                match forward_request(&state.http_client, &endpoint, retry_req).await {
                    Ok(resp) => {
                        info!(
                            job_id = %job_id,
                            endpoint = %endpoint,
                            attempts = attempt + 1,
                            "retry: original backend recovered"
                        );
                        return resp;
                    }
                    Err(retry_err) if retry_err.is_retryable_transport() => {
                        err = retry_err;
                    }
                    Err(retry_err) => {
                        error!(
                            job_id = %job_id,
                            endpoint = %endpoint,
                            error = %retry_err,
                            status = ?retry_err.response_status(),
                            "backend request failed after retry"
                        );
                        return retry_err.status_code().into_response();
                    }
                }
            }

            match state
                .coordinator
                .refresh_endpoint(registration, &endpoint)
                .await
            {
                Ok(EndpointRefresh::Confirmed(_)) => {
                    clear_missing_job_counter(state, &job_id).await;
                    error!(
                        job_id = %job_id,
                        endpoint = %endpoint,
                        error = %err,
                        is_connect = err.is_connect(),
                        is_timeout = err.is_timeout(),
                        status = ?err.response_status(),
                        "backend request failed after transient retries; cached endpoint still healthy"
                    );
                    err.status_code().into_response()
                }
                Ok(EndpointRefresh::Updated(refreshed_endpoint)) => {
                    clear_missing_job_counter(state, &job_id).await;
                    warn!(
                        job_id = %job_id,
                        old_endpoint = %endpoint,
                        endpoint = %refreshed_endpoint,
                        "healthy endpoint changed after transient transport failures, retrying refreshed endpoint"
                    );

                    let retry_req = retry_request.build();
                    match forward_request(&state.http_client, &refreshed_endpoint, retry_req).await
                    {
                        Ok(resp) => resp,
                        Err(refresh_err) => {
                            error!(
                                job_id = %job_id,
                                endpoint = %refreshed_endpoint,
                                error = %refresh_err,
                                is_connect = refresh_err.is_connect(),
                                is_timeout = refresh_err.is_timeout(),
                                status = ?refresh_err.response_status(),
                                "backend request failed after endpoint refresh"
                            );
                            refresh_err.status_code().into_response()
                        }
                    }
                }
                Ok(EndpointRefresh::Missing) => {
                    warn!(
                        job_id = %job_id,
                        endpoint = %endpoint,
                        "backend no longer has a running endpoint, re-waking"
                    );

                    let endpoint = match state.coordinator.ensure_running(registration).await {
                        Ok(ep) => {
                            clear_missing_job_counter(state, &job_id).await;
                            ep
                        }
                        Err(NscaleError::JobNotFound(_)) => {
                            return handle_missing_job(state, &job_id, "rewake").await;
                        }
                        Err(e) => {
                            error!(job_id = %job_id, error = %e, "retry wake failed");
                            return (
                                StatusCode::SERVICE_UNAVAILABLE,
                                format!("retry wake error: {e}"),
                            )
                                .into_response();
                        }
                    };

                    info!(
                        job_id = %job_id,
                        endpoint = %endpoint,
                        "retry: routing request to re-woken backend"
                    );

                    let retry_req = retry_request.build();
                    match forward_request(&state.http_client, &endpoint, retry_req).await {
                        Ok(resp) => resp,
                        Err(rewake_err) => {
                            error!(
                                job_id = %job_id,
                                endpoint = %endpoint,
                                error = %rewake_err,
                                is_connect = rewake_err.is_connect(),
                                is_timeout = rewake_err.is_timeout(),
                                status = ?rewake_err.response_status(),
                                "backend request failed after re-wake"
                            );
                            rewake_err.status_code().into_response()
                        }
                    }
                }
                Err(NscaleError::JobNotFound(_)) => {
                    return handle_missing_job(state, &job_id, "refresh").await;
                }
                Err(e) => {
                    error!(
                        job_id = %job_id,
                        endpoint = %endpoint,
                        error = %e,
                        "failed to refresh backend endpoint after transient transport failures"
                    );
                    StatusCode::BAD_GATEWAY.into_response()
                }
            }
        }
    }
}

struct RequestLifetime {
    shared: Option<(Arc<dyn ActivityStore>, nscale_core::job::ScaleUnit, String)>,
    _in_flight: nscale_core::inflight::InFlightGuard,
    _heartbeat: CancelOnDrop,
    metrics: ProxyMetrics,
    job_id: JobId,
    service: nscale_core::job::ServiceName,
    started: Instant,
    status: u16,
}

impl Drop for RequestLifetime {
    fn drop(&mut self) {
        if let Some((store, unit, token)) = self.shared.take() {
            tokio::spawn(async move {
                if let Err(error) = store.finish_request(&unit, &token).await {
                    warn!(%error, "request lease release failed");
                }
            });
        }
        self.metrics.record_request(
            &self.job_id,
            &self.service,
            self.status,
            self.started.elapsed(),
        );
    }
}

struct TrackedBody {
    body: Body,
    lifetime: Option<RequestLifetime>,
}

impl Drop for TrackedBody {
    fn drop(&mut self) {
        if let Some(lifetime) = self.lifetime.as_mut() {
            lifetime.status = 499;
        }
    }
}

impl hyper::body::Body for TrackedBody {
    type Data = axum::body::Bytes;
    type Error = axum::Error;

    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<std::result::Result<hyper::body::Frame<Self::Data>, Self::Error>>>
    {
        let result = std::pin::Pin::new(&mut self.body).poll_frame(cx);
        if matches!(&result, std::task::Poll::Ready(Some(Err(_))))
            && let Some(lifetime) = self.lifetime.as_mut()
        {
            lifetime.status = 502;
        }
        if matches!(&result, std::task::Poll::Ready(None | Some(Err(_))))
            || self.body.is_end_stream()
        {
            self.lifetime.take();
        }
        result
    }
    fn is_end_stream(&self) -> bool {
        self.body.is_end_stream()
    }
    fn size_hint(&self) -> hyper::body::SizeHint {
        self.body.size_hint()
    }
}

fn track_response(response: Response, mut lifetime: RequestLifetime) -> Response {
    lifetime.status = response.status().as_u16();
    let (parts, body) = response.into_parts();
    if hyper::body::Body::is_end_stream(&body) {
        drop(lifetime);
        return Response::from_parts(parts, body);
    }
    Response::from_parts(
        parts,
        Body::new(TrackedBody {
            body,
            lifetime: Some(lifetime),
        }),
    )
}

#[cfg(test)]
mod tests {
    use axum::http::Method;

    use super::{CancelOnDrop, RetryRequest};

    #[tokio::test]
    async fn cancel_on_drop_cancels_token() {
        let token = tokio_util::sync::CancellationToken::new();

        {
            let _guard = CancelOnDrop(token.clone());
        }

        tokio::time::timeout(std::time::Duration::from_millis(50), token.cancelled())
            .await
            .expect("token should be canceled when guard drops");
    }

    #[test]
    fn retries_require_an_empty_safe_request_and_preserve_headers() {
        use axum::{body::Body, http::Request};
        for method in [Method::GET, Method::HEAD] {
            let req = Request::builder()
                .method(method)
                .uri("/private?a=1")
                .header("authorization", "Bearer test-token")
                .header("cookie", "session=abc")
                .header("range", "bytes=0-10")
                .body(Body::empty())
                .unwrap();
            let replay = RetryRequest::capture(&req).unwrap().build();
            assert_eq!(replay.method(), req.method());
            assert_eq!(replay.uri(), req.uri());
            assert_eq!(replay.headers(), req.headers());
        }
        for method in [Method::POST, Method::PUT] {
            let req = Request::builder()
                .method(method)
                .body(Body::empty())
                .unwrap();
            assert!(RetryRequest::capture(&req).is_none());
        }
        let req = Request::new(Body::from("GET payload"));
        assert!(RetryRequest::capture(&req).is_none());
    }

    fn tracked_test_response() -> (
        super::Response,
        nscale_core::inflight::InFlightTracker,
        tokio_util::sync::CancellationToken,
        super::ProxyMetrics,
    ) {
        let tracker = nscale_core::inflight::InFlightTracker::new();
        let token = tokio_util::sync::CancellationToken::new();
        let metrics = super::ProxyMetrics::new();
        let lifetime = super::RequestLifetime {
            _in_flight: tracker.track("api/web"),
            _heartbeat: CancelOnDrop(token.clone()),
            metrics: metrics.clone(),
            job_id: super::JobId("api".into()),
            service: "web".into(),
            started: std::time::Instant::now(),
            status: 499,
            shared: None,
        };
        let response = super::Response::new(axum::body::Body::from("response body"));
        (
            super::track_response(response, lifetime),
            tracker,
            token,
            metrics,
        )
    }

    #[tokio::test]
    async fn body_completion_releases_guard_and_records_request() {
        let (response, tracker, token, metrics) = tracked_test_response();
        assert_eq!(
            tracker.count("api/web"),
            1,
            "headers must not end request tracking"
        );
        assert!(!token.is_cancelled());
        let body = axum::body::to_bytes(response.into_body(), 100)
            .await
            .unwrap();
        assert_eq!(body, "response body");
        assert_eq!(tracker.count("api/web"), 0);
        assert!(token.is_cancelled());
        assert_eq!(
            metrics
                .snapshot(
                    &"api".into(),
                    &"web".into(),
                    std::time::Duration::from_secs(60)
                )
                .request_count,
            1
        );
    }

    #[tokio::test]
    async fn dropping_unconsumed_response_releases_guard() {
        let (response, tracker, token, _) = tracked_test_response();
        assert_eq!(tracker.count("api/web"), 1);
        drop(response);
        assert_eq!(tracker.count("api/web"), 0);
        assert!(token.is_cancelled());
    }
    #[tokio::test]
    #[ignore = "requires isolated Redis"]
    async fn retry_preserves_authentication() {
        use super::*;
        use nscale_core::{
            job::{Endpoint, JobRegistration},
            traits::{Orchestrator, ServiceDiscovery},
        };
        use std::sync::atomic::{AtomicUsize, Ordering};
        use wiremock::{Mock, MockServer, Request as MockRequest, ResponseTemplate};
        struct Backend {
            endpoint: Endpoint,
        }
        #[async_trait::async_trait]
        impl Orchestrator for Backend {
            async fn scale_up(&self, _: &JobId, _: &str, _: u32) -> Result<()> {
                Ok(())
            }
            async fn scale_down(&self, _: &JobId, _: &str) -> Result<()> {
                Ok(())
            }
            async fn scale_to(&self, _: &JobId, _: &str, _: u32, _: &str) -> Result<()> {
                Ok(())
            }
            async fn get_job_count(&self, _: &JobId, _: &str) -> Result<u32> {
                Ok(1)
            }
            async fn get_healthy_endpoint(&self, _: &JobId, _: &str) -> Result<Option<Endpoint>> {
                Ok(Some(self.endpoint.clone()))
            }
        }
        #[async_trait::async_trait]
        impl ServiceDiscovery for Backend {
            async fn register_fallback(&self, _: &ServiceName, _: &Endpoint) -> Result<()> {
                Ok(())
            }
            async fn deregister_fallback(&self, _: &ServiceName) -> Result<()> {
                Ok(())
            }
            async fn healthy_endpoints(&self, _: &ServiceName) -> Result<Vec<Endpoint>> {
                Ok(vec![self.endpoint.clone()])
            }
            async fn wait_for_healthy(&self, _: &ServiceName, _: Duration) -> Result<Endpoint> {
                Ok(self.endpoint.clone())
            }
        }
        let server = MockServer::start().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let sequence = calls.clone();
        Mock::given(wiremock::matchers::path("/private"))
            .respond_with(move |req: &MockRequest| {
                if sequence.fetch_add(1, Ordering::SeqCst) == 0 {
                    assert_eq!(
                        req.headers.get("authorization").unwrap(),
                        "Bearer test-token"
                    );
                    ResponseTemplate::new(200).set_delay(Duration::from_millis(300))
                } else if req
                    .headers
                    .get("authorization")
                    .is_some_and(|v| v == "Bearer test-token")
                {
                    ResponseTemplate::new(200)
                } else {
                    ResponseTemplate::new(401)
                }
            })
            .mount(&server)
            .await;
        let backend = Arc::new(Backend {
            endpoint: Endpoint::new("127.0.0.1", server.address().port()),
        });
        let store = Arc::new(
            nscale_store::activity::RedisActivityStore::new(
                &std::env::var("NSCALE_TEST_REDIS_URL").unwrap(),
            )
            .await
            .unwrap(),
        );
        let state = AppState {
            coordinator: Arc::new(WakeCoordinator::new(
                backend.clone(),
                backend,
                10,
                Duration::from_secs(2),
            )),
            registry: Arc::new(JobRegistry::new(store.client().clone())),
            http_client: reqwest::Client::builder()
                .timeout(Duration::from_millis(50))
                .build()
                .unwrap(),
            in_flight: InFlightTracker::new(),
            activity_store: store.clone(),
            missing_job_tracker: Arc::new(
                nscale_store::auto_deregister::RedisMissingJobTracker::new(store.client().clone()),
            ),
            proxy_metrics: ProxyMetrics::new(),
            heartbeat_interval: Duration::from_secs(1),
            auto_deregister_enabled: false,
            auto_deregister_threshold: 3,
        };
        let reg = JobRegistration {
            job_id: "review".into(),
            service_name: "review".into(),
            nomad_group: "web".into(),
            scale_unit: None,
            autoscaling: None,
            traefik_routers: vec![],
        };
        let response = proxy_registered(
            &state,
            &reg,
            Request::builder()
                .uri("/private")
                .header("Authorization", "Bearer test-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await;
        assert!(calls.load(Ordering::SeqCst) >= 2);
        assert_eq!(
            response.status(),
            StatusCode::OK,
            "transport retry must keep authentication context"
        );
    }
}
