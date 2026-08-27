use axum::body::Body;
use axum::http::{Request, Response, StatusCode, header};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use reqwest::Client;
use thiserror::Error;
use tokio::net::TcpStream;
use tracing::{debug, error, instrument};

use nscale_core::job::Endpoint;

#[derive(Debug, Error)]
pub enum ForwardRequestError {
    #[error("backend transport failure: {source}")]
    Transport {
        #[source]
        source: reqwest::Error,
    },
    #[error("failed to build response: {source}")]
    ResponseBuild {
        #[source]
        source: axum::http::Error,
    },
    #[error("failed to connect to backend for protocol upgrade: {source}")]
    UpgradeConnect {
        #[source]
        source: std::io::Error,
    },
    #[error("failed to establish backend HTTP/1 connection for protocol upgrade: {source}")]
    UpgradeHandshake {
        #[source]
        source: hyper::Error,
    },
    #[error("backend protocol upgrade request failed: {source}")]
    UpgradeRequest {
        #[source]
        source: hyper::Error,
    },
}

impl ForwardRequestError {
    pub fn status_code(&self) -> StatusCode {
        match self {
            Self::Transport { .. }
            | Self::UpgradeConnect { .. }
            | Self::UpgradeHandshake { .. }
            | Self::UpgradeRequest { .. } => StatusCode::BAD_GATEWAY,
            Self::ResponseBuild { .. } => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    pub fn is_retryable_transport(&self) -> bool {
        match self {
            Self::Transport { source } => source.is_connect() || source.is_timeout(),
            Self::UpgradeConnect { .. } | Self::UpgradeHandshake { .. } => true,
            Self::ResponseBuild { .. } | Self::UpgradeRequest { .. } => false,
        }
    }

    pub fn is_connect(&self) -> bool {
        match self {
            Self::Transport { source } => source.is_connect(),
            Self::UpgradeConnect { .. } | Self::UpgradeHandshake { .. } => true,
            Self::ResponseBuild { .. } | Self::UpgradeRequest { .. } => false,
        }
    }

    pub fn is_timeout(&self) -> bool {
        match self {
            Self::Transport { source } => source.is_timeout(),
            Self::UpgradeConnect { source } => source.kind() == std::io::ErrorKind::TimedOut,
            Self::ResponseBuild { .. }
            | Self::UpgradeHandshake { .. }
            | Self::UpgradeRequest { .. } => false,
        }
    }

    pub fn response_status(&self) -> Option<reqwest::StatusCode> {
        match self {
            Self::Transport { source } => source.status(),
            Self::ResponseBuild { .. }
            | Self::UpgradeConnect { .. }
            | Self::UpgradeHandshake { .. }
            | Self::UpgradeRequest { .. } => None,
        }
    }
}

fn header_contains_token(
    headers: &axum::http::HeaderMap,
    name: header::HeaderName,
    token: &str,
) -> bool {
    headers.get_all(name).iter().any(|value| {
        value.to_str().ok().is_some_and(|value| {
            value
                .split(',')
                .any(|part| part.trim().eq_ignore_ascii_case(token))
        })
    })
}

/// Returns true only for a valid HTTP/1 WebSocket upgrade request.
pub fn is_websocket_upgrade(req: &Request<Body>) -> bool {
    header_contains_token(req.headers(), header::CONNECTION, "upgrade")
        && header_contains_token(req.headers(), header::UPGRADE, "websocket")
}

/// Forward a WebSocket handshake and tunnel the upgraded streams.
///
/// `tunnel_guard` remains alive until the tunnel closes. The proxy handler uses
/// it to keep the backing job marked in-flight and its activity heartbeat alive.
#[instrument(skip(req, tunnel_guard), fields(backend = %backend))]
pub async fn forward_websocket_upgrade<T>(
    backend: &Endpoint,
    mut req: Request<Body>,
    tunnel_guard: T,
) -> Result<Response<Body>, ForwardRequestError>
where
    T: Send + 'static,
{
    let downstream_upgrade = hyper::upgrade::on(&mut req);
    let stream = TcpStream::connect(backend.address())
        .await
        .map_err(|source| ForwardRequestError::UpgradeConnect { source })?;
    let (mut sender, connection) = http1::handshake(TokioIo::new(stream))
        .await
        .map_err(|source| ForwardRequestError::UpgradeHandshake { source })?;

    tokio::spawn(async move {
        if let Err(source) = connection.with_upgrades().await {
            error!(error = %source, "backend upgrade connection failed");
        }
    });

    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/")
        .parse()
        .expect("an inbound request path and query should be a valid relative URI");
    *req.uri_mut() = path_and_query;
    req.headers_mut().insert(
        header::HOST,
        backend
            .address()
            .parse()
            .expect("an endpoint address should be a valid Host header"),
    );

    let mut response = sender
        .send_request(req)
        .await
        .map_err(|source| ForwardRequestError::UpgradeRequest { source })?;

    if response.status() == StatusCode::SWITCHING_PROTOCOLS {
        let upstream_upgrade = hyper::upgrade::on(&mut response);
        tokio::spawn(async move {
            let _tunnel_guard = tunnel_guard;
            let result = async {
                let (downstream, upstream) =
                    tokio::try_join!(downstream_upgrade, upstream_upgrade)?;
                let mut downstream = TokioIo::new(downstream);
                let mut upstream = TokioIo::new(upstream);
                tokio::io::copy_bidirectional(&mut downstream, &mut upstream).await?;
                Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
            }
            .await;

            if let Err(source) = result {
                debug!(error = %source, "WebSocket tunnel closed with an error");
            }
        });
    } else {
        drop(tunnel_guard);
    }

    let (parts, body) = response.into_parts();
    Ok(Response::from_parts(parts, Body::new(body)))
}

/// Reverse-proxy a request to the given backend endpoint.
///
/// Copies method, path + query, headers (except `Host`), and body
/// from the inbound request and streams the backend response back.
#[instrument(skip(client, req), fields(backend = %backend))]
pub async fn forward_request(
    client: &Client,
    backend: &Endpoint,
    mut req: Request<Body>,
) -> Result<Response<Body>, ForwardRequestError> {
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
            "host"
                | "connection"
                | "keep-alive"
                | "transfer-encoding"
                | "te"
                | "trailer"
                | "upgrade"
                | "proxy-authorization"
                | "proxy-connection"
        ) {
            continue;
        }
        builder = builder.header(name.clone(), value.clone());
    }

    // Forward the body
    let body = std::mem::replace(req.body_mut(), Body::empty());
    let body_stream = body.into_data_stream();
    builder = builder.body(reqwest::Body::wrap_stream(body_stream));

    let response = builder
        .send()
        .await
        .map_err(|source| ForwardRequestError::Transport { source })?;

    // Convert reqwest response back to axum response
    let status =
        StatusCode::from_u16(response.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut resp_builder = Response::builder().status(status);

    for (name, value) in response.headers() {
        resp_builder = resp_builder.header(name.clone(), value.clone());
    }

    let body_bytes = response.bytes_stream();
    let body = Body::from_stream(body_bytes);

    resp_builder
        .body(body)
        .map_err(|source| ForwardRequestError::ResponseBuild { source })
}

#[cfg(test)]
mod tests {
    use std::{
        convert::Infallible,
        net::TcpListener,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        },
        time::Duration,
    };

    use super::*;
    use axum::{Router, body::to_bytes, routing::any};
    use hyper::service::service_fn;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        sync::{Notify, oneshot},
    };
    use wiremock::matchers::{body_string, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    struct DropSignal {
        dropped: Arc<AtomicBool>,
        notify: Arc<Notify>,
    }

    impl Drop for DropSignal {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
            self.notify.notify_waiters();
        }
    }

    async fn read_http_head(stream: &mut TcpStream) -> String {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            assert!(bytes.len() < 16 * 1024, "HTTP response head is too large");
            bytes.push(stream.read_u8().await.expect("response head byte"));
        }
        String::from_utf8(bytes).expect("response head should be UTF-8")
    }

    async fn assert_forward_request_preserves_method_and_body(
        request_method: &str,
        request_path: &str,
        request_body: &str,
    ) {
        let mock_server = MockServer::start().await;

        Mock::given(method(request_method))
            .and(path(request_path))
            .and(header("x-test-header", "nscale"))
            .and(body_string(request_body))
            .respond_with(ResponseTemplate::new(202).set_body_string("forwarded"))
            .expect(1)
            .mount(&mock_server)
            .await;

        let client = Client::builder().build().expect("client should build");
        let request = Request::builder()
            .method(request_method)
            .uri(request_path)
            .header("host", "echo-s2z.example")
            .header("x-test-header", "nscale")
            .body(Body::from(request_body.to_owned()))
            .expect("request should build");

        let backend = Endpoint::new(
            mock_server.address().ip().to_string(),
            mock_server.address().port(),
        );

        let response = forward_request(&client, &backend, request)
            .await
            .expect("forward request should succeed");

        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("response body should be readable");
        assert_eq!(body, "forwarded");
    }

    #[tokio::test]
    async fn forward_request_marks_connect_failures_retryable() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let port = listener
            .local_addr()
            .expect("listener should have an address")
            .port();
        drop(listener);

        let client = Client::builder()
            .connect_timeout(std::time::Duration::from_millis(100))
            .build()
            .expect("client should build");
        let request = Request::builder()
            .method("GET")
            .uri("/")
            .body(Body::empty())
            .expect("request should build");

        let err = forward_request(&client, &Endpoint::new("127.0.0.1", port), request)
            .await
            .expect_err("closed port should fail");

        assert!(err.is_retryable_transport());
        assert!(err.is_connect() || err.is_timeout());
        assert_eq!(err.status_code(), StatusCode::BAD_GATEWAY);
        assert_eq!(err.response_status(), None);
    }

    #[tokio::test]
    async fn forward_request_preserves_post_method_and_body() {
        assert_forward_request_preserves_method_and_body(
            "POST",
            "/submit",
            r#"{"message":"hello from post"}"#,
        )
        .await;
    }

    #[tokio::test]
    async fn forward_request_preserves_put_method_and_body() {
        assert_forward_request_preserves_method_and_body(
            "PUT",
            "/resource/42",
            r#"{"message":"hello from put"}"#,
        )
        .await;
    }

    #[test]
    fn detects_websocket_upgrade_tokens_case_insensitively() {
        let request = Request::builder()
            .uri("/socket")
            .header(header::CONNECTION, "keep-alive, Upgrade")
            .header(header::UPGRADE, "WebSocket")
            .body(Body::empty())
            .expect("request should build");
        assert!(is_websocket_upgrade(&request));

        let regular_request = Request::builder()
            .uri("/socket")
            .header(header::UPGRADE, "websocket")
            .body(Body::empty())
            .expect("request should build");
        assert!(!is_websocket_upgrade(&regular_request));
    }

    #[tokio::test]
    async fn forwards_websocket_upgrade_and_tunnels_both_directions() {
        let backend_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("backend listener should bind");
        let backend_address = backend_listener
            .local_addr()
            .expect("backend listener should have an address");
        let (backend_tunnel_tx, backend_tunnel_rx) = oneshot::channel();
        let backend_tunnel_tx = Arc::new(Mutex::new(Some(backend_tunnel_tx)));
        let backend_task = tokio::spawn(async move {
            let (stream, _) = backend_listener
                .accept()
                .await
                .expect("backend should accept proxy connection");
            let backend_tunnel_tx = backend_tunnel_tx.clone();
            let service = service_fn(move |mut request: hyper::Request<hyper::body::Incoming>| {
                let backend_tunnel_tx = backend_tunnel_tx.clone();
                async move {
                    assert!(header_contains_token(
                        request.headers(),
                        header::CONNECTION,
                        "upgrade"
                    ));
                    assert!(header_contains_token(
                        request.headers(),
                        header::UPGRADE,
                        "websocket"
                    ));

                    let on_upgrade = hyper::upgrade::on(&mut request);
                    let backend_tunnel_tx = backend_tunnel_tx
                        .lock()
                        .expect("backend tunnel sender lock should not be poisoned")
                        .take()
                        .expect("backend should receive exactly one request");
                    tokio::spawn(async move {
                        let result = async {
                            let upgraded = on_upgrade.await.map_err(|error| error.to_string())?;
                            let mut upgraded = TokioIo::new(upgraded);
                            let mut payload = [0; 4];
                            upgraded
                                .read_exact(&mut payload)
                                .await
                                .map_err(|error| error.to_string())?;
                            if &payload != b"ping" {
                                return Err(format!("unexpected client payload: {payload:?}"));
                            }
                            upgraded
                                .write_all(b"pong")
                                .await
                                .map_err(|error| error.to_string())?;
                            let error = upgraded.read_u8().await.expect_err("client should close");
                            if error.kind() != std::io::ErrorKind::UnexpectedEof {
                                return Err(format!("unexpected close error: {error}"));
                            }
                            Ok::<(), String>(())
                        }
                        .await;
                        let _ = backend_tunnel_tx.send(result);
                    });

                    Ok::<_, Infallible>(
                        hyper::Response::builder()
                            .status(StatusCode::SWITCHING_PROTOCOLS)
                            .header(header::CONNECTION, "upgrade")
                            .header(header::UPGRADE, "websocket")
                            .body(Body::empty())
                            .expect("upgrade response should build"),
                    )
                }
            });
            hyper::server::conn::http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .with_upgrades()
                .await
                .expect("backend connection should complete");
        });

        let dropped = Arc::new(AtomicBool::new(false));
        let notify = Arc::new(Notify::new());
        let proxy_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("proxy listener should bind");
        let proxy_address = proxy_listener
            .local_addr()
            .expect("proxy listener should have an address");
        let backend = Endpoint::new(backend_address.ip().to_string(), backend_address.port());
        let dropped_for_proxy = dropped.clone();
        let notify_for_proxy = notify.clone();
        let proxy = Router::new().fallback(any(move |request: Request<Body>| {
            let backend = backend.clone();
            let signal = DropSignal {
                dropped: dropped_for_proxy.clone(),
                notify: notify_for_proxy.clone(),
            };
            async move {
                forward_websocket_upgrade(&backend, request, signal)
                    .await
                    .expect("proxy should forward upgrade")
            }
        }));
        let proxy_task = tokio::spawn(async move {
            axum::serve(proxy_listener, proxy)
                .await
                .expect("proxy server should run");
        });

        let mut client = TcpStream::connect(proxy_address)
            .await
            .expect("client should connect to proxy");
        client
            .write_all(
                b"GET /socket HTTP/1.1\r\nHost: websocket.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: MTIzNDU2Nzg5MDEyMzQ1Ng==\r\n\r\n",
            )
            .await
            .expect("client should write upgrade request");

        let response_head = read_http_head(&mut client).await;
        assert!(
            response_head.starts_with("HTTP/1.1 101"),
            "unexpected response: {response_head}"
        );
        client
            .write_all(b"ping")
            .await
            .expect("client should write tunneled payload");
        let mut payload = [0; 4];
        client
            .read_exact(&mut payload)
            .await
            .expect("client should read tunneled response payload");
        assert_eq!(&payload, b"pong");
        assert!(!dropped.load(Ordering::SeqCst));

        client
            .shutdown()
            .await
            .expect("client should close its tunnel");
        if !dropped.load(Ordering::SeqCst) {
            tokio::time::timeout(Duration::from_secs(1), notify.notified())
                .await
                .expect("tunnel guard should drop when the socket closes");
        }
        assert!(dropped.load(Ordering::SeqCst));

        tokio::time::timeout(Duration::from_secs(1), backend_tunnel_rx)
            .await
            .expect("backend tunnel should finish")
            .expect("backend tunnel result should be sent")
            .expect("backend tunnel should succeed");
        tokio::time::timeout(Duration::from_secs(1), backend_task)
            .await
            .expect("backend task should finish")
            .expect("backend task should not panic");
        proxy_task.abort();
    }
}
