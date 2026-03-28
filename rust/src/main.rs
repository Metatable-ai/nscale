use std::sync::Arc;

use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{any, get, post},
    Json, Router,
};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tower_http::trace::TraceLayer;
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use nscale_consul::client::ConsulClient;
use nscale_core::config::Config;
use nscale_core::job::JobRegistration;
use nscale_core::traits::ActivityStore;
use nscale_nomad::client::NomadClient;
use nscale_proxy::handler::{proxy_handler, AppState};
use nscale_proxy::middleware::ActivityLayer;
use nscale_scaler::controller::ScaleDownController;
use nscale_scaler::traffic_probe::TrafficProbe;
use nscale_store::activity::RedisActivityStore;
use nscale_store::registry::JobRegistry;
use nscale_waker::coordinator::WakeCoordinator;

#[tokio::main]
async fn main() {
    // ── Tracing ──────────────────────────────────────────
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,nscale=debug".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    info!("nscale — Nomad Scale-to-Zero starting");

    // ── Config ───────────────────────────────────────────
    let config = Config::load().unwrap_or_else(|e| {
        error!(error = %e, "failed to load config");
        std::process::exit(1);
    });
    info!(listen = %config.listen_addr, admin = %config.admin_addr, "configuration loaded");

    // ── Redis (activity store owns the connection) ───────
    let activity_store = RedisActivityStore::new(&config.redis.url)
        .await
        .expect("failed to connect to Redis");
    let redis_client = activity_store.client().clone();
    let activity_store: Arc<dyn ActivityStore> = Arc::new(activity_store);
    let registry = Arc::new(JobRegistry::new(redis_client));
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
        .build()
        .expect("failed to build HTTP client");

    let app_state = AppState {
        coordinator: coordinator.clone(),
        registry: registry.clone(),
        http_client,
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
        config.scaling.idle_timeout(),
        config.scaling.scale_down_interval(),
        cancel.clone(),
    );
    let scaler_handle = tokio::spawn(scaler.run());

    // ── Proxy router ─────────────────────────────────────
    let proxy_router = Router::new()
        .fallback(any(proxy_handler))
        .layer(ActivityLayer::new(activity_store.clone()))
        .layer(TraceLayer::new_for_http())
        .with_state(app_state);

    // ── Admin router ─────────────────────────────────────
    let admin_state = AdminState {
        registry: registry.clone(),
    };

    let admin_router = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
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

    // Wait for scaler to finish
    let _ = scaler_handle.await;
    info!("nscale shut down");
}

// ─── Admin types & handlers ──────────────────────────────

#[derive(Clone)]
struct AdminState {
    registry: Arc<JobRegistry>,
}

async fn healthz() -> &'static str {
    "ok"
}

async fn readyz(State(state): State<AdminState>) -> impl IntoResponse {
    match state.registry.list_all().await {
        Ok(_) => (StatusCode::OK, "ready").into_response(),
        Err(e) => (
            StatusCode::SERVICE_UNAVAILABLE,
            format!("not ready: {e}"),
        )
            .into_response(),
    }
}

async fn admin_register(
    State(state): State<AdminState>,
    Json(reg): Json<JobRegistration>,
) -> impl IntoResponse {
    match state.registry.register(&reg).await {
        Ok(()) => {
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
            Ok(()) => ok += 1,
            Err(e) => {
                error!(job_id = %reg.job_id, error = %e, "failed to register during sync");
                failed += 1;
            }
        }
    }

    info!(ok, failed, total = registrations.len(), "registry sync complete");
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
