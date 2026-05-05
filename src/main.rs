use std::collections::BTreeSet;
use std::sync::Arc;

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{any, get, post},
};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tower_http::trace::TraceLayer;
use tracing::{error, info};
use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

use nscale_consul::client::ConsulClient;
use nscale_core::config::Config;
use nscale_core::error::NscaleError;
use nscale_core::inflight::InFlightTracker;
use nscale_core::job::{JobId, JobRegistration};
use nscale_core::traits::ActivityStore;
use nscale_etcd::EtcdClient;
use nscale_nomad::client::NomadClient;
use nscale_nomad::events::{EventStreamConfig, start_event_stream};
use nscale_nomad::job_mutator::inject_nscale_tags;
use nscale_proxy::handler::{AppState, proxy_handler};
use nscale_proxy::middleware::ActivityLayer;
use nscale_scaler::controller::ScaleDownController;
use nscale_scaler::event_processor::EventProcessor;
use nscale_scaler::traffic_probe::TrafficProbe;
use nscale_store::activity::RedisActivityStore;
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::WakeCoordinator;

#[tokio::main]
async fn main() {
    // ── Tracing ──────────────────────────────────────────
    //
    // Log format is controlled by the `NSCALE_LOG_FORMAT` environment variable:
    //   compact  – plain text, no ANSI escape codes (default when stdout is not a TTY)
    //   pretty   – human-friendly with ANSI colour (default when stdout is a TTY)
    //   json     – structured JSON, suitable for log aggregators (Loki, CloudWatch, …)
    {
        use std::io::IsTerminal as _;
        let env_filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,nscale=debug".into());

        // Resolve the env var once so we can borrow it as &str.
        let format_var = std::env::var("NSCALE_LOG_FORMAT").ok();
        let log_format = format_var.as_deref().unwrap_or_else(|| {
            if std::io::stdout().is_terminal() {
                "pretty"
            } else {
                "compact"
            }
        });
        let unknown_format = !matches!(log_format, "compact" | "pretty" | "json");

        match log_format {
            "json" => tracing_subscriber::registry()
                .with(env_filter)
                .with(tracing_subscriber::fmt::layer().json())
                .init(),
            "pretty" => tracing_subscriber::registry()
                .with(env_filter)
                .with(tracing_subscriber::fmt::layer())
                .init(),
            _ => tracing_subscriber::registry()
                .with(env_filter)
                .with(tracing_subscriber::fmt::layer().with_ansi(false).compact())
                .init(),
        }

        if unknown_format {
            tracing::warn!(
                value = log_format,
                "unrecognised NSCALE_LOG_FORMAT value; defaulting to compact (valid values: compact, pretty, json)"
            );
        }
    }

    info!("nscale — Nomad Scale-to-Zero starting");

    // ── Config ───────────────────────────────────────────
    let config = Config::load().unwrap_or_else(|e| {
        error!(error = %e, "failed to load config");
        std::process::exit(1);
    });
    info!(listen = %config.listen_addr, admin = %config.admin_addr, "configuration loaded");

    // ── Redis (activity store owns the connection) ───────
    let activity_store = {
        let max_retries = 30;
        let mut attempt = 0;
        loop {
            attempt += 1;
            match RedisActivityStore::new(&config.redis.url).await {
                Ok(store) => break store,
                Err(e) => {
                    if attempt >= max_retries {
                        error!(error = %e, "failed to connect to Redis after {max_retries} attempts");
                        std::process::exit(1);
                    }
                    info!(attempt, max_retries, error = %e, "Redis not ready, retrying in 1s...");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    };
    let redis_client = activity_store.client().clone();
    let activity_store: Arc<dyn ActivityStore> = Arc::new(activity_store);

    let registry = if config.registry.durable_enabled {
        let endpoints = config
            .registry
            .etcd_endpoints
            .split(',')
            .map(str::trim)
            .filter(|endpoint| !endpoint.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();

        if endpoints.is_empty() {
            error!(
                "durable registry enabled but registry.etcd_endpoints (NSCALE_REGISTRY__ETCD_ENDPOINTS) is empty"
            );
            std::process::exit(1);
        }

        let durable_registry = Arc::new(
            EtcdClient::new(endpoints, config.registry.etcd_key_prefix.clone())
                .await
                .unwrap_or_else(|e| {
                    error!(error = %e, "failed to connect to etcd durable registry");
                    std::process::exit(1);
                }),
        );

        let registry = Arc::new(JobRegistry::with_durable(redis_client, durable_registry));
        match registry.sync_from_durable().await {
            Ok(restored) => {
                info!(restored, "hydrated Redis registry cache from etcd");
            }
            Err(e) => {
                error!(error = %e, "failed to hydrate Redis registry cache from etcd");
            }
        }
        registry
    } else {
        Arc::new(JobRegistry::new(redis_client))
    };
    info!("connected to Redis");

    // ── Build subsystems ─────────────────────────────────
    let nomad_client = Arc::new(
        NomadClient::new(&config.nomad.addr, config.nomad.token.as_deref())
            .expect("failed to create Nomad client"),
    );
    let consul_client = Arc::new(
        ConsulClient::new(&config.consul.addr, config.consul.token.as_deref())
            .expect("failed to create Consul client"),
    );

    let coordinator = Arc::new(WakeCoordinator::new(
        nomad_client.clone(),
        consul_client.clone(),
        config.nomad.concurrency,
        config.scaling.wake_timeout(),
    ));

    let http_client = reqwest::Client::builder()
        .pool_max_idle_per_host(100)
        .timeout(config.proxy.request_timeout())
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()
        .expect("failed to build HTTP client");

    // ── In-flight request tracker (shared between proxy and scaler) ──
    let in_flight = InFlightTracker::new();

    // Heartbeat interval: refresh activity every idle_timeout / 3 during long requests
    let heartbeat_interval = config.scaling.idle_timeout() / 3;

    let app_state = AppState {
        coordinator: coordinator.clone(),
        registry: registry.clone(),
        http_client,
        in_flight: in_flight.clone(),
        activity_store: activity_store.clone(),
        heartbeat_interval,
    };

    let cancel = CancellationToken::new();

    // ── Traffic probe (optional — only when Traefik metrics are configured) ──
    let traffic_probe = config.traefik.as_ref().map(|tc| {
        info!(metrics_url = %tc.metrics_url, provider = %tc.provider, "Traefik traffic probe enabled");
        Arc::new(TrafficProbe::new(&tc.metrics_url, &tc.provider))
    });

    // ── Scale-down controller ────────────────────────────
    let scaler = ScaleDownController::new(
        nomad_client.clone(),
        activity_store.clone(),
        registry.clone(),
        coordinator.clone(),
        traffic_probe,
        in_flight.clone(),
        config.scaling.idle_timeout(),
        config.scaling.scale_down_interval(),
        cancel.clone(),
    );
    let scaler_handle = tokio::spawn(scaler.run());

    // ── Nomad event stream ───────────────────────────────
    let event_rx = start_event_stream(
        EventStreamConfig {
            nomad_addr: config.nomad.addr.clone(),
            nomad_token: config.nomad.token.clone(),
            topics: vec!["Allocation".to_string()],
            initial_index: 0,
        },
        cancel.clone(),
    );

    let event_processor = EventProcessor::new(
        coordinator.clone(),
        activity_store.clone(),
        registry.clone(),
    );
    let event_handle = tokio::spawn(event_processor.run(event_rx));
    info!("nomad event stream consumer started");

    // ── Proxy router ─────────────────────────────────────
    let proxy_router = Router::new()
        .fallback(any(proxy_handler))
        .layer(ActivityLayer::new(activity_store.clone()))
        .layer(TraceLayer::new_for_http())
        .with_state(app_state);

    // ── Admin router ─────────────────────────────────────
    let admin_state = AdminState {
        registry: registry.clone(),
        activity_store: activity_store.clone(),
        nomad_client: nomad_client.clone(),
        file_provider_service: config.routing.file_provider_service.clone(),
    };

    let admin_router = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/admin/jobs", post(admin_submit_job))
        .route("/admin/registry", post(admin_register))
        .route("/admin/registry/sync", post(admin_sync))
        .with_state(admin_state);

    // ── Start listeners ──────────────────────────────────
    let proxy_listener = TcpListener::bind(config.listen_addr)
        .await
        .expect("failed to bind proxy listener");
    let admin_listener = TcpListener::bind(config.admin_addr)
        .await
        .expect("failed to bind admin listener");

    info!(addr = %config.listen_addr, "proxy server listening");
    info!(addr = %config.admin_addr, "admin server listening");

    let cancel_clone = cancel.clone();
    tokio::select! {
        result = axum::serve(proxy_listener, proxy_router) => {
            if let Err(e) = result {
                error!(error = %e, "proxy server error");
            }
        }
        result = axum::serve(admin_listener, admin_router) => {
            if let Err(e) = result {
                error!(error = %e, "admin server error");
            }
        }
        _ = tokio::signal::ctrl_c() => {
            info!("received SIGINT, shutting down...");
            cancel_clone.cancel();
        }
    }

    // Wait for background tasks to finish
    let _ = scaler_handle.await;
    let _ = event_handle.await;
    info!("nscale shut down");
}

// ─── Admin types & handlers ──────────────────────────────

#[derive(Clone)]
struct AdminState {
    registry: Arc<JobRegistry>,
    activity_store: Arc<dyn ActivityStore>,
    nomad_client: Arc<NomadClient>,
    file_provider_service: String,
}

#[derive(Debug, Deserialize)]
struct SubmitJobRequest {
    hcl: String,
    #[serde(default)]
    variables: Option<String>,
}

#[derive(Debug, Serialize)]
struct RegistrationFailure {
    service_name: String,
    error: String,
}

#[derive(Debug, Serialize)]
struct SubmitJobResponse {
    job_id: String,
    eval_id: String,
    job_modify_index: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    warnings: Option<String>,
    managed_services: Vec<JobRegistration>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    registration_failures: Vec<RegistrationFailure>,
}

async fn healthz() -> &'static str {
    "ok"
}

fn admin_error_status(error: &NscaleError) -> StatusCode {
    match error {
        NscaleError::Http(_) => StatusCode::BAD_GATEWAY,
        _ => StatusCode::BAD_REQUEST,
    }
}

async fn readyz(State(state): State<AdminState>) -> impl IntoResponse {
    match state.registry.list_all().await {
        Ok(_) => (StatusCode::OK, "ready").into_response(),
        Err(e) => (StatusCode::SERVICE_UNAVAILABLE, format!("not ready: {e}")).into_response(),
    }
}

async fn admin_submit_job(
    State(state): State<AdminState>,
    Json(request): Json<SubmitJobRequest>,
) -> impl IntoResponse {
    let mut parsed_job = match state
        .nomad_client
        .parse_job(&request.hcl, request.variables.as_deref())
        .await
    {
        Ok(job) => job,
        Err(e) => {
            error!(error = %e, "failed to parse Nomad job submission");
            return (
                admin_error_status(&e),
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let managed_services = match inject_nscale_tags(&mut parsed_job, &state.file_provider_service) {
        Ok(services) => services,
        Err(e) => {
            error!(error = %e, "failed to inject nscale routing tags into parsed job");
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    if managed_services.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": "parsed job does not contain any Traefik-enabled services for nscale"
            })),
        )
            .into_response();
    }

    let unique_groups = managed_services
        .iter()
        .map(|registration| registration.nomad_group.clone())
        .collect::<BTreeSet<_>>();
    if unique_groups.len() > 1 {
        error!(
            job_id = %managed_services[0].job_id,
            groups = ?unique_groups,
            "multiple groups detected for submitted job; scale-down will use the last registered group"
        );
    }

    let submit_response = match state.nomad_client.submit_job(&parsed_job).await {
        Ok(response) => response,
        Err(e) => {
            error!(error = %e, "failed to submit Nomad job");
            return (
                admin_error_status(&e),
                Json(serde_json::json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    };

    let mut seeded_job_ids = BTreeSet::new();
    let mut registration_failures = Vec::new();
    for registration in &managed_services {
        match state.registry.register(registration).await {
            Ok(()) => {
                seeded_job_ids.insert(registration.job_id.0.clone());
                info!(
                    job_id = %registration.job_id,
                    service_name = %registration.service_name,
                    group = %registration.nomad_group,
                    "registered submitted job with nscale"
                );
            }
            Err(e) => {
                error!(
                    job_id = %registration.job_id,
                    service_name = %registration.service_name,
                    error = %e,
                    "failed to register submitted job with nscale"
                );
                registration_failures.push(RegistrationFailure {
                    service_name: registration.service_name.0.clone(),
                    error: e.to_string(),
                });
            }
        }
    }

    for job_id in seeded_job_ids {
        let job_id = JobId(job_id);
        if let Err(e) = state.activity_store.record_activity(&job_id).await {
            error!(job_id = %job_id, error = %e, "failed to seed activity for submitted job");
        }
    }

    let status = if registration_failures.is_empty() {
        StatusCode::CREATED
    } else {
        StatusCode::MULTI_STATUS
    };

    (
        status,
        Json(SubmitJobResponse {
            job_id: managed_services[0].job_id.0.clone(),
            eval_id: submit_response.eval_id,
            job_modify_index: submit_response.job_modify_index,
            warnings: submit_response
                .warnings
                .filter(|warning| !warning.is_empty()),
            managed_services,
            registration_failures,
        }),
    )
        .into_response()
}

async fn admin_register(
    State(state): State<AdminState>,
    Json(reg): Json<JobRegistration>,
) -> impl IntoResponse {
    match state.registry.register(&reg).await {
        Ok(()) => {
            // Seed activity so the scaler can detect this job as idle later.
            if let Err(e) = state.activity_store.record_activity(&reg.job_id).await {
                error!(job_id = %reg.job_id, error = %e, "failed to seed activity");
            }
            info!(job_id = %reg.job_id, "registered job via admin API");
            (StatusCode::CREATED, "registered").into_response()
        }
        Err(e) => {
            error!(error = %e, "failed to register job");
            (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response()
        }
    }
}

async fn admin_sync(
    State(state): State<AdminState>,
    Json(registrations): Json<Vec<JobRegistration>>,
) -> impl IntoResponse {
    let mut ok = 0u32;
    let mut failed = 0u32;

    for reg in &registrations {
        match state.registry.register(reg).await {
            Ok(()) => {
                if let Err(e) = state.activity_store.record_activity(&reg.job_id).await {
                    error!(job_id = %reg.job_id, error = %e, "failed to seed activity during sync");
                }
                ok += 1;
            }
            Err(e) => {
                error!(job_id = %reg.job_id, error = %e, "failed to register during sync");
                failed += 1;
            }
        }
    }

    info!(
        ok,
        failed,
        total = registrations.len(),
        "registry sync complete"
    );
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "synced": ok,
            "failed": failed,
            "total": registrations.len()
        })),
    )
        .into_response()
}
