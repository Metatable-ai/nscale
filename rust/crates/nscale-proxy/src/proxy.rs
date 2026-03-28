use axum::body::Body;
use axum::http::{Request, Response, StatusCode};
use reqwest::Client;
use tracing::{debug, error, instrument};

use nscale_core::job::Endpoint;

/// Reverse-proxy a request to the given backend endpoint.
///
/// Copies method, path + query, headers (except `Host`), and body
/// from the inbound request and streams the backend response back.
#[instrument(skip(client, req), fields(backend = %backend))]
pub async fn forward_request(
    client: &Client,
    backend: &Endpoint,
    mut req: Request<Body>,
) -> Result<Response<Body>, StatusCode> {
    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");

    let url = format!("{}{}", backend.base_url("http"), path_and_query);
    debug!(url = %url, method = %req.method(), "forwarding request");

    // Build the outbound request
    let mut builder = client.request(req.method().clone(), &url);

    // Copy headers, skipping hop-by-hop and Host
    for (name, value) in req.headers() {
        let n = name.as_str();
        if matches!(
            n,
            "host" | "connection" | "keep-alive" | "transfer-encoding" | "te" | "trailer"
            | "upgrade" | "proxy-authorization" | "proxy-connection"
        ) {
            continue;
        }
        builder = builder.header(name.clone(), value.clone());
    }

    // Forward the body
    let body = std::mem::replace(req.body_mut(), Body::empty());
    let body_stream = body.into_data_stream();
    builder = builder.body(reqwest::Body::wrap_stream(body_stream));

    let response = builder.send().await.map_err(|e| {
        error!(error = %e, "backend request failed");
        StatusCode::BAD_GATEWAY
    })?;

    // Convert reqwest response back to axum response
    let status = StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut resp_builder = Response::builder().status(status);

    for (name, value) in response.headers() {
        resp_builder = resp_builder.header(name.clone(), value.clone());
    }

    let body_bytes = response.bytes_stream();
    let body = Body::from_stream(body_bytes);

    resp_builder.body(body).map_err(|e| {
        error!(error = %e, "failed to build response");
        StatusCode::INTERNAL_SERVER_ERROR
    })
}
