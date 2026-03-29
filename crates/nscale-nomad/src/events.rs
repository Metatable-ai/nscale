use reqwest::header::HeaderValue;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use nscale_core::error::{NscaleError, Result};

use crate::models::EventStreamFrame;

/// A parsed Nomad event from the event stream.
#[derive(Debug, Clone)]
pub struct NomadEvent {
    pub index: u64,
    pub topic: String,
    pub event_type: String,
    pub payload: serde_json::Value,
}

/// Configuration for the event stream consumer.
pub struct EventStreamConfig {
    pub nomad_addr: String,
    pub nomad_token: Option<String>,
    pub topics: Vec<String>,
    pub initial_index: u64,
}

/// Start consuming the Nomad event stream in a background task.
/// Returns a receiver for parsed events.
pub fn start_event_stream(
    config: EventStreamConfig,
    cancel: tokio_util::sync::CancellationToken,
) -> mpsc::Receiver<NomadEvent> {
    let (tx, rx) = mpsc::channel(256);
    tokio::spawn(event_stream_loop(config, tx, cancel));
    rx
}

async fn event_stream_loop(
    config: EventStreamConfig,
    tx: mpsc::Sender<NomadEvent>,
    cancel: tokio_util::sync::CancellationToken,
) {
    let mut last_index = config.initial_index;

    loop {
        if cancel.is_cancelled() {
            info!("event stream shutting down");
            return;
        }

        match connect_and_consume(&config, &tx, &mut last_index, &cancel).await {
            Ok(()) => {
                info!("event stream ended normally");
                return;
            }
            Err(e) => {
                warn!(error = %e, last_index, "event stream disconnected, reconnecting in 1s");
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => {}
                    _ = cancel.cancelled() => return,
                }
            }
        }
    }
}

async fn connect_and_consume(
    config: &EventStreamConfig,
    tx: &mpsc::Sender<NomadEvent>,
    last_index: &mut u64,
    cancel: &tokio_util::sync::CancellationToken,
) -> Result<()> {
    let topics_query: String = config
        .topics
        .iter()
        .map(|t| format!("topic={}", t))
        .collect::<Vec<_>>()
        .join("&");

    let url = format!(
        "{}/v1/event/stream?{}&index={}",
        config.nomad_addr.trim_end_matches('/'),
        topics_query,
        last_index
    );

    debug!(url = %url, "connecting to nomad event stream");

    let mut req = reqwest::Client::new().get(&url);
    if let Some(ref token) = config.nomad_token {
        req = req.header(
            "X-Nomad-Token",
            HeaderValue::from_str(token).map_err(|e| NscaleError::Nomad(e.to_string()))?,
        );
    }

    let resp = req.send().await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(NscaleError::Nomad(format!(
            "event stream returned {}: {}",
            status, body
        )));
    }

    info!("connected to nomad event stream");

    let mut stream = resp.bytes_stream();
    let mut buffer = Vec::new();

    use futures_util::StreamExt;
    loop {
        tokio::select! {
            chunk = stream.next() => {
                match chunk {
                    Some(Ok(bytes)) => {
                        buffer.extend_from_slice(&bytes);
                        // Process complete lines (newline-delimited JSON)
                        while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                            let line: Vec<u8> = buffer.drain(..=pos).collect();
                            let line = String::from_utf8_lossy(&line);
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }
                            match serde_json::from_str::<EventStreamFrame>(line) {
                                Ok(frame) => {
                                    *last_index = frame.index;
                                    for envelope in frame.events {
                                        let event = NomadEvent {
                                            index: frame.index,
                                            topic: envelope.topic,
                                            event_type: envelope.event_type,
                                            payload: envelope.payload,
                                        };
                                        if tx.send(event).await.is_err() {
                                            debug!("event receiver dropped, stopping stream");
                                            return Ok(());
                                        }
                                    }
                                }
                                Err(e) => {
                                    warn!(error = %e, "failed to parse event frame, skipping");
                                }
                            }
                        }
                    }
                    Some(Err(e)) => {
                        return Err(NscaleError::Nomad(format!("stream read error: {}", e)));
                    }
                    None => {
                        return Err(NscaleError::Nomad("event stream ended unexpectedly".to_string()));
                    }
                }
            }
            _ = cancel.cancelled() => {
                return Ok(());
            }
        }
    }
}
