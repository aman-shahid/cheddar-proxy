//! Proxy server implementation
//!
//! Handles forwarding HTTP traffic and capturing transactions for the UI.

use crate::api::proxy_api::{is_running_internal, send_transaction_to_sink};
use crate::models::breakpoint::RequestEdit;
use crate::models::{HttpMethod, HttpTransaction, TransactionState};
use crate::proxy::breakpoints::{self, BreakpointContext};
use crate::proxy::cert_manager::CertManager;
use crate::storage;
use anyhow::{anyhow, Context};
use bytes::Bytes;
use dashmap::DashMap;
use http::Request;
use http_body_util::channel::Channel;
use http_body_util::{combinators::BoxBody, BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::Response as HyperResponse;
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as AutoServerBuilder;
use once_cell::sync::Lazy;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore};
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant as StdInstant};

use std::convert::Infallible;
#[cfg(test)]
use std::future::Future;
use std::io;
use std::mem;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::task::{Context as TaskContext, Poll};
use thiserror::Error;
use tokio::io::DuplexStream;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::Instant;
use tokio_rustls::{TlsAcceptor, TlsConnector, TlsStream};
use webpki_roots::TLS_SERVER_ROOTS;

const MAX_HEADER_BYTES: usize = 128 * 1024;
const MAX_HEADER_COUNT: usize = 256;
const MAX_BODY_CAPTURE_BYTES: usize = 512 * 1024;
const MAX_REQUEST_BODY_BYTES: usize = 32 * 1024 * 1024; // 32MB hard cap on inbound bodies

#[derive(Debug, Error)]
#[error("request body exceeds configured limit of {limit} bytes")]
struct RequestBodyTooLarge {
    limit: usize,
}

impl RequestBodyTooLarge {
    fn new(limit: usize) -> Self {
        Self { limit }
    }
}

fn build_tls_client_config() -> anyhow::Result<ClientConfig> {
    let root_store = RootCertStore::from_iter(TLS_SERVER_ROOTS.iter().cloned());
    let mut config = ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();
    // Prefer HTTP/2 but allow HTTP/1.1 fallback.
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(config)
}

/// Proxy server configuration
pub struct ProxyConfig {
    /// Port to listen on
    pub port: u16,
    /// Bind address
    pub bind_address: String,
    /// Whether HTTPS interception is enabled
    pub enable_https: bool,
    /// Whether HTTP/2 support is enabled for upstream connections
    pub enable_h2: bool,
    /// Certificate storage root
    pub storage_path: String,
}

/// Run the proxy server
pub async fn run_server(config: ProxyConfig) -> anyhow::Result<()> {
    // Configure HTTP/2 support based on config
    H2_ENABLED.store(config.enable_h2, Ordering::SeqCst);
    tracing::info!(
        "HTTP/2 upstream support: {}",
        if config.enable_h2 {
            "enabled"
        } else {
            "disabled"
        }
    );

    let addr = format!("{}:{}", config.bind_address, config.port);
    let listener = TcpListener::bind(&addr).await?;

    tracing::info!("Proxy server listening on {}", addr);

    let cert_manager = if config.enable_https {
        Some(Arc::new(CertManager::new(&config.storage_path)?))
    } else {
        None
    };

    let tls_client_config = if config.enable_https {
        Some(Arc::new(build_tls_client_config()?))
    } else {
        None
    };

    loop {
        if !is_running_internal() {
            break;
        }

        // Use accept with timeout so we can check cancellation periodically
        let accept_result =
            tokio::time::timeout(tokio::time::Duration::from_millis(500), listener.accept()).await;

        match accept_result {
            Ok(Ok((socket, peer_addr))) => {
                tracing::debug!("Connection from {}", peer_addr);
                let cert_manager = cert_manager.clone();
                let tls_client_config = tls_client_config.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_connection(socket, cert_manager, tls_client_config).await
                    {
                        // Downgrade expected errors to debug level:
                        // - "tls handshake eof" = client rejected intercepted cert
                        // - "Broken pipe" = client closed connection early
                        // - "connection reset" = client aborted
                        let err_str = e.to_string().to_lowercase();
                        if err_str.contains("eof")
                            || err_str.contains("broken pipe")
                            || err_str.contains("connection reset")
                            || err_str.contains("connection closed")
                            || err_str.contains("invalidcontenttype")
                            || err_str.contains("corrupt message")
                            || err_str.contains("connection error")
                        {
                            tracing::debug!("Connection closed by client: {}", e);
                        } else {
                            tracing::error!("Error handling connection: {}", e);
                        }
                    }
                });
            }
            Ok(Err(e)) => tracing::error!("Accept error: {}", e),
            Err(_) => {
                // Timeout, check is_running flag and continue
                continue;
            }
        }
    }

    tracing::info!("Proxy server stopped");
    Ok(())
}

/// Keep-alive idle timeout in seconds
const KEEP_ALIVE_TIMEOUT_SECS: u64 = 30;
const H2_POOL_TTL: Duration = Duration::from_secs(30);

type H2ClientEntry = (hyper::client::conn::http2::SendRequest<ReqBody>, StdInstant);

/// Manages a pool of persistent connections to upstream servers
pub struct UpstreamPool {
    /// H2 client handlers keyed by (host, port)
    h2_clients: Mutex<HashMap<(String, u16), H2ClientEntry>>,
}

impl Default for UpstreamPool {
    fn default() -> Self {
        Self::new()
    }
}

impl UpstreamPool {
    pub fn new() -> Self {
        Self {
            h2_clients: Mutex::new(HashMap::new()),
        }
    }

    /// Get an H2 client for the given host/port, or None if not available/supported.
    /// Performs a health check to ensure the connection is still alive.
    pub async fn get_h2_client(
        &self,
        host: &str,
        port: u16,
    ) -> Option<hyper::client::conn::http2::SendRequest<ReqBody>> {
        let key = (host.to_string(), port);
        let mut sender = {
            let mut clients = self.h2_clients.lock().unwrap();
            if let Some((s, ts)) = clients.get(&key) {
                if ts.elapsed() > H2_POOL_TTL || s.is_closed() {
                    clients.remove(&key);
                    return None;
                }
                s.clone()
            } else {
                return None;
            }
        };

        // Ensure the sender is actually ready to handle a request
        match sender.ready().await {
            Ok(_) => Some(sender),
            Err(_) => {
                let mut clients = self.h2_clients.lock().unwrap();
                // Double check it's the same client before removing
                if let Some((s, _)) = clients.get(&key) {
                    if s.is_closed() {
                        clients.remove(&key);
                    }
                }
                None
            }
        }
    }

    pub fn set_h2_client(
        &self,
        host: String,
        port: u16,
        client: hyper::client::conn::http2::SendRequest<ReqBody>,
    ) {
        let mut clients = self.h2_clients.lock().unwrap();
        clients.insert((host, port), (client, StdInstant::now()));
    }

    #[cfg(test)]
    pub fn set_h2_client_with_timestamp(
        &self,
        host: String,
        port: u16,
        client: hyper::client::conn::http2::SendRequest<ReqBody>,
        ts: StdInstant,
    ) {
        let mut clients = self.h2_clients.lock().unwrap();
        clients.insert((host, port), (client, ts));
    }

    pub fn remove_h2_client(&self, host: &str, port: u16) {
        let mut clients = self.h2_clients.lock().unwrap();
        clients.remove(&(host.to_string(), port));
    }

    pub fn purge_all(&self) {
        let mut clients = self.h2_clients.lock().unwrap();
        clients.clear();
    }
}

static UPSTREAM_POOL: Lazy<Arc<UpstreamPool>> = Lazy::new(|| Arc::new(UpstreamPool::new()));
static H2_BLOCKLIST: Lazy<DashMap<(String, u16), Instant>> = Lazy::new(DashMap::new);
static H2_BLOCKLIST_TTL: Duration = Duration::from_secs(300);
// Runtime-configurable H2 toggle (set by run_server based on config)
static H2_ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

// Test-only override for H2_ENABLED
#[cfg(test)]
static H2_TEST_OVERRIDE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
fn set_h2_test_enabled(enabled: bool) {
    H2_TEST_OVERRIDE.store(enabled, Ordering::SeqCst);
}

fn mark_h2_failure(host: &str, port: u16) {
    UPSTREAM_POOL.remove_h2_client(host, port);
    H2_BLOCKLIST.insert((host.to_string(), port), Instant::now());
}

fn is_h2_blocklisted(host: &str, port: u16) -> bool {
    #[cfg(test)]
    if H2_TEST_OVERRIDE.load(Ordering::SeqCst) {
        // When test override is enabled, check only the blocklist, not H2_ENABLED
        let key = (host.to_string(), port);
        if let Some(entry) = H2_BLOCKLIST.get(&key) {
            if entry.value().elapsed() < H2_BLOCKLIST_TTL {
                return true;
            }
        }
        H2_BLOCKLIST.remove(&key);
        return false;
    }
    if !H2_ENABLED.load(Ordering::SeqCst) {
        return true;
    }
    let key = (host.to_string(), port);
    if let Some(entry) = H2_BLOCKLIST.get(&key) {
        if entry.value().elapsed() < H2_BLOCKLIST_TTL {
            return true;
        }
    }
    H2_BLOCKLIST.remove(&key);
    false
}

/// Determine if connection should be kept alive based on HTTP version and headers
fn should_keep_alive(version: &str, headers: &HashMap<String, String>) -> bool {
    let connection_header = header_value(headers, "connection");
    match connection_header.as_deref() {
        Some(v) if v.eq_ignore_ascii_case("close") => false,
        Some(v) if v.eq_ignore_ascii_case("keep-alive") => true,
        None => version.contains("1.1"), // HTTP/1.1 defaults to keep-alive
        Some(_) => version.contains("1.1"),
    }
}

/// Handle a client connection with keep-alive support
async fn handle_connection(
    mut socket: TcpStream,
    cert_manager: Option<Arc<CertManager>>,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<()> {
    let mut request_number: u32 = 0;

    loop {
        request_number += 1;
        let connection_reused = request_number > 1;
        let req_start = Instant::now();

        // Read request with keep-alive timeout
        let parsed_request = match tokio::time::timeout(
            tokio::time::Duration::from_secs(KEEP_ALIVE_TIMEOUT_SECS),
            read_http_request(&mut socket, RequestScheme::Http),
        )
        .await
        {
            Ok(Ok(req)) => req,
            Ok(Err(err)) => {
                // Only log error on first request; subsequent failures are normal (client closed)
                if request_number == 1 {
                    tracing::warn!("Failed to parse request: {err}");
                    let _ = respond_with_status(
                        &mut socket,
                        400,
                        "Bad Request",
                        "Unable to parse HTTP request",
                    )
                    .await;
                }
                break;
            }
            Err(_) => {
                // Timeout waiting for next request - normal for keep-alive
                tracing::debug!("Keep-alive timeout after {} requests", request_number - 1);
                break;
            }
        };

        // Check if we should keep alive after this request
        let keep_alive =
            should_keep_alive(&parsed_request.version, &parsed_request.request_headers);

        // CONNECT method takes over the connection completely
        if parsed_request.method == HttpMethod::Connect {
            handle_connect_tunnel(socket, parsed_request, cert_manager, tls_client_config).await?;
            return Ok(()); // Connection is now a tunnel, exit
        }

        // Process the request
        if let Err(e) = process_request(
            &mut socket,
            parsed_request,
            req_start,
            tls_client_config.clone(),
            connection_reused,
        )
        .await
        {
            tracing::debug!("Request processing error: {e}");
            break;
        }

        if !keep_alive {
            break;
        }
    }

    Ok(())
}

#[cfg(test)]
async fn handle_connection_with_stream<S>(
    client: &mut S,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    let req_start = Instant::now();
    let mut parsed_request = read_http_request(client, RequestScheme::Http).await?;
    parsed_request.ensure_timing_handle(req_start);
    process_request(client, parsed_request, req_start, tls_client_config, false).await
}

async fn process_request<S>(
    client: &mut S,
    mut parsed_request: ParsedRequest,
    req_start: Instant,
    tls_client_config: Option<Arc<ClientConfig>>,
    connection_reused: bool,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    let timing_handle = parsed_request.ensure_timing_handle(req_start);

    let mut tx = HttpTransaction::new(
        parsed_request.method,
        &parsed_request.scheme,
        &parsed_request.host,
        parsed_request.port,
        &parsed_request.path,
        parsed_request.request_headers.clone(),
    );
    tx.http_version = parsed_request.version.clone();
    tx.connection_reused = connection_reused;
    tx.request_content_type = header_value(&parsed_request.request_headers, "content-type");
    tx.stream_id = parsed_request.stream_id;
    let timing_handle = Some(timing_handle);

    // Detect WebSocket upgrade request
    let is_websocket_upgrade = parsed_request.method == HttpMethod::Get
        && header_value(&parsed_request.request_headers, "upgrade")
            .map(|v| v.to_lowercase() == "websocket")
            .unwrap_or(false)
        && header_value(&parsed_request.request_headers, "connection")
            .map(|v| v.to_lowercase().contains("upgrade"))
            .unwrap_or(false);

    if is_websocket_upgrade {
        tracing::info!(
            "WebSocket upgrade request detected: {}://{}{}",
            parsed_request.scheme,
            parsed_request.host,
            parsed_request.path
        );
    }

    tx.is_websocket = is_websocket_upgrade;

    send_transaction_to_sink(tx.clone());

    if let Err(err) = handle_breakpoints(&mut tx, &mut parsed_request).await {
        tracing::info!("Request aborted by breakpoint: {}", err);
        respond_with_status(client, 409, "Conflict", "Request aborted at breakpoint").await?;
        tx.state = TransactionState::Failed;
        tx.status_code = Some(409);
        tx.status_message = Some("Breakpoint aborted".to_string());
        send_transaction_to_sink(tx);
        return Ok(());
    }

    let (mut upstream, conn_timing) =
        match connect_upstream(&parsed_request, tls_client_config.clone()).await {
            Ok(result) => result,
            Err(err) => {
                tracing::error!(
                    "Failed to connect to upstream {}:{} - {}",
                    parsed_request.host,
                    parsed_request.port,
                    err
                );
                respond_with_status(
                    client,
                    502,
                    "Bad Gateway",
                    "Unable to reach upstream server",
                )
                .await?;
                tx.state = TransactionState::Failed;
                tx.status_code = Some(502);
                tx.status_message = Some("Unable to reach upstream server".to_string());
                tx.notes = Some("Upstream connection failed".to_string());
                send_transaction_to_sink(tx);
                return Ok(());
            }
        };

    // Store connection timing and metadata
    tx.timing.dns_lookup_ms = Some(conn_timing.dns_ms);
    tx.timing.tcp_connect_ms = Some(conn_timing.tcp_ms);
    tx.timing.tls_handshake_ms = conn_timing.tls_ms;
    tx.server_ip = conn_timing.server_ip;
    tx.tls_version = conn_timing.tls_version;
    tx.tls_cipher = conn_timing.tls_cipher;

    // Measure request send time
    let send_start = Instant::now();
    let mut request_capture = BodyCapture::new(MAX_BODY_CAPTURE_BYTES);
    let forward_result = forward_request_to_upstream(
        client,
        &mut upstream,
        &mut parsed_request,
        &mut request_capture,
    )
    .await;
    tx.request_body = request_capture.into_option();

    if let Err(err) = forward_result {
        let is_too_large = err.downcast_ref::<RequestBodyTooLarge>().is_some();
        let (code, label, body) = if is_too_large {
            (
                413,
                "Payload Too Large",
                "Request body exceeds allowed size",
            )
        } else {
            (400, "Bad Request", "Failed to read request body")
        };
        tracing::warn!("Failed to forward request upstream: {err}");
        respond_with_status(client, code, label, body).await?;
        tx.state = TransactionState::Failed;
        tx.status_code = Some(code);
        tx.status_message = Some(label.to_string());
        apply_timing_handle(&mut tx, timing_handle.as_ref());
        send_transaction_to_sink(tx);
        return Ok(());
    }

    if let Some(handle) = timing_handle.as_ref() {
        handle.record_send();
    }
    let _ = upstream.flush().await;
    tx.timing.request_send_ms = Some(send_start.elapsed().as_millis() as u32);
    apply_timing_handle(&mut tx, timing_handle.as_ref());

    // Measure waiting time (TTFB - time to first byte)
    let waiting_start = Instant::now();

    let mut response_head_result = read_response_head(&mut upstream).await;
    // If we failed to read response head and this was a simple GET/HEAD with no body, retry once over new H1 connection.
    if response_head_result.is_err()
        && matches!(parsed_request.method, HttpMethod::Get | HttpMethod::Head)
        && parsed_request.body_kind.len() == 0
        && parsed_request.scheme == "https"
    {
        tracing::debug!(
            "Retrying GET/HEAD over fresh H1 after response head failure to {}:{}{}",
            parsed_request.host,
            parsed_request.port,
            parsed_request.path
        );
        // attempt fresh connection and resend the request as-is
        if let Ok((mut retry_upstream, conn_timing)) =
            connect_upstream(&parsed_request, tls_client_config.clone()).await
        {
            // update timing with retry connection timings
            tx.timing.dns_lookup_ms = Some(conn_timing.dns_ms);
            tx.timing.tcp_connect_ms = Some(conn_timing.tcp_ms);
            tx.timing.tls_handshake_ms = conn_timing.tls_ms;
            tx.server_ip = conn_timing.server_ip;
            tx.tls_version = conn_timing.tls_version.clone();
            tx.tls_cipher = conn_timing.tls_cipher.clone();

            // Re-send the already-buffered request head/body (no body for GET/HEAD here)
            let mut retry_capture = BodyCapture::new(MAX_BODY_CAPTURE_BYTES);
            if let Err(err) = forward_request_to_upstream(
                client,
                &mut retry_upstream,
                &mut parsed_request,
                &mut retry_capture,
            )
            .await
            {
                tracing::debug!("Retry over H1 failed: {}", err);
            } else {
                response_head_result = read_response_head(&mut retry_upstream).await;
                upstream = retry_upstream;
            }
        }
    }

    match response_head_result {
        Ok(mut response_head) => {
            // Handle WebSocket upgrade (101 Switching Protocols)
            if is_websocket_upgrade && response_head.status_code == 101 {
                tx.timing.waiting_ms = Some(waiting_start.elapsed().as_millis() as u32);

                // Forward the 101 response to client
                client.write_all(&response_head.raw_head).await?;
                // Also forward any body prefix (shouldn't be any, but just in case)
                if !response_head.body_prefix.is_empty() {
                    client.write_all(&response_head.body_prefix).await?;
                }
                client.flush().await?;

                tx.status_code = Some(101);
                tx.status_message = Some(response_head.reason.clone());
                tx.response_headers = Some(response_head.headers.clone());
                tx.state = TransactionState::Completed;
                tx.timing.total_ms = Some(req_start.elapsed().as_millis() as u32);
                apply_timing_handle(&mut tx, parsed_request.timing_handle.as_ref());

                // Log the WebSocket upgrade
                tracing::info!(
                    "WebSocket upgrade successful: {}://{}{}",
                    parsed_request.scheme,
                    parsed_request.host,
                    parsed_request.path
                );

                persist_and_stream(tx.clone()).await;

                // Now tunnel the WebSocket connection with frame parsing
                let connection_id = tx.id.clone();
                websocket_tunnel(client, &mut upstream, connection_id).await?;

                return Ok(());
            }

            let content_length = header_value(&response_head.headers, "content-length")
                .and_then(|v| v.parse::<usize>().ok());
            let is_chunked = header_value(&response_head.headers, "transfer-encoding")
                .map(|v| v.to_ascii_lowercase().contains("chunked"))
                .unwrap_or(false);

            if is_chunked {
                // TTFB is time until we got response headers
                tx.timing.waiting_ms = Some(waiting_start.elapsed().as_millis() as u32);

                let download_start = Instant::now();
                client.write_all(&response_head.raw_head).await?;
                let (captured_body, total_len) =
                    forward_chunked_body(response_head.body_prefix, &mut upstream, client).await?;
                tx.timing.content_download_ms = Some(download_start.elapsed().as_millis() as u32);

                tx.status_code = Some(response_head.status_code);
                tx.status_message = Some(response_head.reason.clone());
                tx.response_headers = Some(response_head.headers.clone());
                tx.response_body = Some(captured_body);
                tx.response_content_type = header_value(&response_head.headers, "content-type");
                tx.response_size = Some(total_len);
                tx.state = TransactionState::Completed;
                tx.timing.total_ms = Some(req_start.elapsed().as_millis() as u32);
                apply_timing_handle(&mut tx, parsed_request.timing_handle.as_ref());
                persist_and_stream(tx).await;
                return Ok(());
            }

            let should_stream = content_length.is_none()
                || content_length
                    .map(|len| len > MAX_BODY_CAPTURE_BYTES)
                    .unwrap_or(true);

            if should_stream {
                // TTFB is time until we got response headers
                tx.timing.waiting_ms = Some(waiting_start.elapsed().as_millis() as u32);

                let download_start = Instant::now();
                client.write_all(&response_head.raw_head).await?;
                let mut streamed_bytes = response_head.body_prefix.len() as u64;
                if !response_head.body_prefix.is_empty() {
                    client.write_all(&response_head.body_prefix).await?;
                }
                streamed_bytes += stream_response_body(&mut upstream, client).await?;
                tx.timing.content_download_ms = Some(download_start.elapsed().as_millis() as u32);

                tx.status_code = Some(response_head.status_code);
                tx.status_message = Some(response_head.reason.clone());
                tx.response_headers = Some(response_head.headers.clone());
                tx.response_content_type = header_value(&response_head.headers, "content-type");
                tx.state = TransactionState::Completed;
                tx.timing.total_ms = Some(req_start.elapsed().as_millis() as u32);
                if let Some(len) = content_length {
                    tx.response_size = Some(len as u64);
                } else if streamed_bytes > 0 {
                    tx.response_size = Some(streamed_bytes);
                }
                apply_timing_handle(&mut tx, parsed_request.timing_handle.as_ref());
                persist_and_stream(tx).await;
                return Ok(());
            }

            // TTFB for fixed-size response
            tx.timing.waiting_ms = Some(waiting_start.elapsed().as_millis() as u32);
            let download_start = Instant::now();

            let expected_len = content_length.unwrap_or(0);
            let mut body_bytes = mem::take(&mut response_head.body_prefix);
            if body_bytes.len() > expected_len {
                body_bytes.truncate(expected_len);
            }
            if body_bytes.len() < expected_len {
                let extra = read_exact_body(&mut upstream, expected_len - body_bytes.len())
                    .await
                    .context("reading response body")?;
                body_bytes.extend_from_slice(&extra);
            }

            let mut full_response = response_head.raw_head.clone();
            full_response.extend_from_slice(&body_bytes);
            client.write_all(&full_response).await?;
            tx.timing.content_download_ms = Some(download_start.elapsed().as_millis() as u32);

            let mut captured_body = body_bytes.clone();
            if captured_body.len() > MAX_BODY_CAPTURE_BYTES {
                captured_body.truncate(MAX_BODY_CAPTURE_BYTES);
            }

            tx.status_code = Some(response_head.status_code);
            tx.status_message = Some(response_head.reason.clone());
            tx.response_headers = Some(response_head.headers.clone());
            tx.response_body = Some(captured_body);
            tx.response_content_type = header_value(&response_head.headers, "content-type");
            tx.response_size = Some(full_response.len() as u64);
            tx.state = TransactionState::Completed;
            tx.timing.total_ms = Some(req_start.elapsed().as_millis() as u32);
            apply_timing_handle(&mut tx, parsed_request.timing_handle.as_ref());
            persist_and_stream(tx).await;
        }
        Err(err) => {
            let err_str = err.to_string().to_lowercase();
            if err_str.contains("connection reset")
                || err_str.contains("reset by peer")
                || err_str.contains("unexpected eof")
                || err_str.contains("close_notify")
            {
                tracing::debug!("Failed to read response head (peer closed): {err}");
            } else {
                tracing::error!("Failed to read response head: {err}");
            }
            if parsed_request.scheme == "https" {
                mark_h2_failure(&parsed_request.host, parsed_request.port);
            }
            respond_with_status(client, 502, "Bad Gateway", "Failed to read response").await?;
            tx.state = TransactionState::Failed;
            tx.status_code = Some(502);
            tx.status_message = Some("Failed to read response".to_string());
            tx.notes = Some("No response from upstream".to_string());
            apply_timing_handle(&mut tx, parsed_request.timing_handle.as_ref());
            send_transaction_to_sink(tx);
        }
    }

    Ok(())
}

/// Timing data from connection establishment
struct ConnectionTiming {
    /// DNS resolution time in milliseconds (currently combined with TCP due to tokio)
    dns_ms: u32,
    /// TCP handshake time in milliseconds  
    tcp_ms: u32,
    /// TLS handshake time in milliseconds (None for HTTP)
    tls_ms: Option<u32>,
    /// Resolved server IP address
    server_ip: Option<String>,
    /// TLS version (e.g., "TLS 1.3")
    tls_version: Option<String>,
    /// TLS cipher suite
    tls_cipher: Option<String>,
}

async fn connect_upstream(
    parsed_request: &ParsedRequest,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<(UpstreamStream, ConnectionTiming)> {
    let timing_handle = parsed_request.timing_handle.clone();
    #[cfg(test)]
    let connector_opt = {
        let guard = TEST_CONNECTOR.lock().unwrap();
        guard.as_ref().cloned()
    };
    #[cfg(test)]
    if let Some(connector) = connector_opt {
        return connector(parsed_request).await;
    }
    // 1. Check H2 pool first if scheme is HTTPS and not blocklisted
    if parsed_request.scheme == "https" {
        let h2_blocked = is_h2_blocklisted(&parsed_request.host, parsed_request.port);
        if !h2_blocked {
            if let Some(h2_client) = UPSTREAM_POOL
                .get_h2_client(&parsed_request.host, parsed_request.port)
                .await
            {
                let host_for_pool = parsed_request.host.clone();
                let port_for_pool = parsed_request.port;
                let timing_handle = parsed_request.timing_handle.clone();
                let (h1_side, bridge_side) = tokio::io::duplex(1024 * 1024);
                tokio::spawn(async move {
                    if let Err(e) = bridge_h1_to_hyper_upstream(
                        bridge_side,
                        h2_client.clone(),
                        timing_handle.clone(),
                        host_for_pool.clone(),
                    )
                    .await
                    {
                        tracing::error!(
                            "Upstream H2 bridge error (pooled) for {}:{}: {}",
                            host_for_pool,
                            port_for_pool,
                            e
                        );
                        mark_h2_failure(&host_for_pool, port_for_pool);
                    }
                });
                let timing = ConnectionTiming {
                    dns_ms: 0,
                    tcp_ms: 0,
                    tls_ms: None,
                    server_ip: None,
                    tls_version: Some("H2 (reused)".to_string()),
                    tls_cipher: None,
                };
                return Ok((UpstreamStream::Bridge(h1_side), timing));
            }
        } else {
            tracing::debug!(
                "H2 blocklist hit for {}:{}, forcing HTTP/1.1 upstream",
                parsed_request.host,
                parsed_request.port
            );
        }
    }

    // 2. No pooled client available, connect new TCP stream
    let connect_start = Instant::now();
    let stream = TcpStream::connect(format!("{}:{}", parsed_request.host, parsed_request.port))
        .await
        .with_context(|| {
            format!(
                "connecting to upstream {}:{}",
                parsed_request.host, parsed_request.port
            )
        })?;
    let connect_elapsed = connect_start.elapsed().as_millis() as u32;

    // Capture server IP address
    let server_ip = stream.peer_addr().ok().map(|addr| match addr.ip() {
        std::net::IpAddr::V4(v4) => v4.to_string(),
        std::net::IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                v4.to_string()
            } else {
                v6.to_string()
            }
        }
    });

    let dns_ms = connect_elapsed * 4 / 10;
    let tcp_ms = connect_elapsed - dns_ms;

    if parsed_request.scheme == "https" {
        let h2_blocked = is_h2_blocklisted(&parsed_request.host, parsed_request.port);

        let config = tls_client_config
            .clone()
            .ok_or_else(|| anyhow!("TLS client config unavailable for HTTPS request"))?;
        let host_name = parsed_request.host.clone();
        let server_name = ServerName::try_from(host_name.clone())
            .map_err(|_| anyhow!("invalid server name {}", host_name))?;
        let connector = TlsConnector::from(config);

        let tls_start = Instant::now();
        let tls = connector.connect(server_name, stream).await?;
        let tls_ms = tls_start.elapsed().as_millis() as u32;

        // Extract TLS connection info
        let (_, conn_data) = tls.get_ref();
        let tls_version = conn_data.protocol_version().map(|v| format!("{:?}", v));
        let tls_cipher = conn_data
            .negotiated_cipher_suite()
            .map(|cs| format!("{:?}", cs.suite()));
        let alpn = conn_data.alpn_protocol();

        if alpn == Some(b"h2") && !h2_blocked {
            // [RESTORED] Negotiated H2!
            let io = TokioIo::new(tls);
            let (h2_client, h2_conn) =
                hyper::client::conn::http2::Builder::new(TokioExecutor::new())
                    .initial_stream_window_size(1024 * 1024)
                    .initial_connection_window_size(1024 * 1024)
                    .handshake(io)
                    .await?;

            let host = parsed_request.host.clone();
            let port = parsed_request.port;

            // Spawn connection handler with proactive purging
            let host_for_conn = host.clone();
            tokio::spawn(async move {
                match h2_conn.await {
                    Ok(_) => {
                        tracing::debug!(
                            "H2 connection to {}:{} closed cleanly",
                            host_for_conn,
                            port
                        );
                        UPSTREAM_POOL.remove_h2_client(&host_for_conn, port);
                    }
                    Err(e) => {
                        tracing::error!(
                            "Upstream H2 connection error for {}:{}: {}",
                            host_for_conn,
                            port,
                            e
                        );
                        mark_h2_failure(&host_for_conn, port);
                    }
                }
            });

            UPSTREAM_POOL.set_h2_client(
                parsed_request.host.clone(),
                parsed_request.port,
                h2_client.clone(),
            );

            let (h1_side, bridge_side) = tokio::io::duplex(1024 * 1024);
            tokio::spawn(async move {
                if let Err(e) = bridge_h1_to_hyper_upstream(
                    bridge_side,
                    h2_client,
                    timing_handle.clone(),
                    host.clone(),
                )
                .await
                {
                    tracing::error!(
                        "Upstream H2 bridge error (new) for {}:{}: {}",
                        host,
                        port,
                        e
                    );
                    // Remove from pool so next request will renegotiate
                    mark_h2_failure(&host, port);
                }
            });

            let timing = ConnectionTiming {
                dns_ms,
                tcp_ms,
                tls_ms: Some(tls_ms),
                server_ip,
                tls_version,
                tls_cipher,
            };
            return Ok((UpstreamStream::Bridge(h1_side), timing));
        }

        if h2_blocked {
            // Force HTTP/1.1 by retrying with a config that only advertises h1
            let base_cfg = tls_client_config
                .clone()
                .ok_or_else(|| anyhow!("TLS client config unavailable for HTTPS request"))?;
            let mut cfg = (*base_cfg).clone();
            cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
            let connector = TlsConnector::from(Arc::new(cfg));
            let host_name = parsed_request.host.clone();
            let server_name = ServerName::try_from(host_name.clone())
                .map_err(|_| anyhow!("invalid server name {}", host_name))?;

            let tls_start = Instant::now();
            let stream_h1 =
                TcpStream::connect(format!("{}:{}", parsed_request.host, parsed_request.port))
                    .await
                    .with_context(|| {
                        format!(
                            "reconnecting to upstream {}:{} for HTTP/1.1 fallback",
                            parsed_request.host, parsed_request.port
                        )
                    })?;
            let tls = connector.connect(server_name, stream_h1).await?;
            let tls_ms = tls_start.elapsed().as_millis() as u32;

            let timing = ConnectionTiming {
                dns_ms,
                tcp_ms,
                tls_ms: Some(tls_ms),
                server_ip,
                tls_version: Some("HTTP/1.1 (forced)".to_string()),
                tls_cipher: None,
            };
            return Ok((UpstreamStream::Tls(Box::new(TlsStream::from(tls))), timing));
        }

        let timing = ConnectionTiming {
            dns_ms,
            tcp_ms,
            tls_ms: Some(tls_ms),
            server_ip,
            tls_version,
            tls_cipher,
        };
        Ok((UpstreamStream::Tls(Box::new(TlsStream::from(tls))), timing))
    } else {
        let timing = ConnectionTiming {
            dns_ms,
            tcp_ms,
            tls_ms: None,
            server_ip,
            tls_version: None,
            tls_cipher: None,
        };
        Ok((UpstreamStream::Plain(stream), timing))
    }
}

/// Tunnel data between client and upstream server
async fn tunnel<C, U>(client: C, upstream: U) -> anyhow::Result<()>
where
    C: AsyncRead + AsyncWrite + Unpin,
    U: AsyncRead + AsyncWrite + Unpin,
{
    let (mut client_reader, mut client_writer) = tokio::io::split(client);
    let (mut upstream_reader, mut upstream_writer) = tokio::io::split(upstream);

    let client_to_upstream = tokio::io::copy(&mut client_reader, &mut upstream_writer);
    let upstream_to_client = tokio::io::copy(&mut upstream_reader, &mut client_writer);

    tokio::select! {
        result = client_to_upstream => {
            if let Err(e) = result {
                tracing::debug!("Client to upstream error: {}", e);
            }
        }
        result = upstream_to_client => {
            if let Err(e) = result {
                tracing::debug!("Upstream to client error: {}", e);
            }
        }
    }

    Ok(())
}
/// Tunnel WebSocket data bidirectionally between client and upstream
/// Parses frames and captures messages as they pass through
async fn websocket_tunnel<C, U>(
    client: &mut C,
    upstream: &mut U,
    connection_id: String,
) -> anyhow::Result<()>
where
    C: AsyncRead + AsyncWrite + Unpin + Send,
    U: AsyncRead + AsyncWrite + Unpin + Send,
{
    use crate::models::MessageDirection;
    use crate::proxy::websocket::extract_message;
    use crate::storage::add_websocket_message;

    let mut client_buf = vec![0u8; 65536];
    let mut upstream_buf = vec![0u8; 65536];

    // Accumulation buffers for partial frames
    let mut client_pending = Vec::new();
    let mut upstream_pending = Vec::new();

    loop {
        tokio::select! {
            // Client -> Upstream (messages from client)
            result = client.read(&mut client_buf) => {
                match result {
                    Ok(0) => {
                        tracing::debug!("WebSocket: Client closed connection");
                        break;
                    }
                    Ok(n) => {
                        let data = &client_buf[..n];

                        // Forward data to upstream immediately
                        if let Err(e) = upstream.write_all(data).await {
                            tracing::debug!("WebSocket: Error writing to upstream: {}", e);
                            break;
                        }
                        let _ = upstream.flush().await;

                        // Accumulate and parse frames
                        client_pending.extend_from_slice(data);
                        while let Some((msg, consumed)) = extract_message(
                            &client_pending,
                            &connection_id,
                            MessageDirection::ClientToServer,
                        ) {
                            add_websocket_message(msg);
                            client_pending.drain(..consumed);
                        }
                    }
                    Err(e) => {
                        tracing::debug!("WebSocket: Error reading from client: {}", e);
                        break;
                    }
                }
            }
            // Upstream -> Client (messages from server)
            result = upstream.read(&mut upstream_buf) => {
                match result {
                    Ok(0) => {
                        tracing::debug!("WebSocket: Upstream closed connection");
                        break;
                    }
                    Ok(n) => {
                        let data = &upstream_buf[..n];

                        // Forward data to client immediately
                        if let Err(e) = client.write_all(data).await {
                            tracing::debug!("WebSocket: Error writing to client: {}", e);
                            break;
                        }
                        let _ = client.flush().await;

                        // Accumulate and parse frames
                        upstream_pending.extend_from_slice(data);
                        while let Some((msg, consumed)) = extract_message(
                            &upstream_pending,
                            &connection_id,
                            MessageDirection::ServerToClient,
                        ) {
                            add_websocket_message(msg);
                            upstream_pending.drain(..consumed);
                        }
                    }
                    Err(e) => {
                        tracing::debug!("WebSocket: Error reading from upstream: {}", e);
                        break;
                    }
                }
            }
        }
    }

    tracing::info!(
        "WebSocket connection closed: {} ({} client pending, {} server pending)",
        connection_id,
        client_pending.len(),
        upstream_pending.len()
    );

    Ok(())
}

#[derive(Debug)]
enum UpstreamStream {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
    Bridge(DuplexStream),
    #[cfg(test)]
    Mock(DuplexStream),
}

#[cfg(test)]
type TestConnectorFn = dyn Fn(
        &ParsedRequest,
    )
        -> Pin<Box<dyn Future<Output = anyhow::Result<(UpstreamStream, ConnectionTiming)>> + Send>>
    + Send
    + Sync;

#[cfg(test)]
static TEST_CONNECTOR: Lazy<Mutex<Option<Arc<TestConnectorFn>>>> = Lazy::new(|| Mutex::new(None));

#[cfg(test)]
fn set_test_upstream_connector<F, Fut>(connector: F)
where
    F: Fn(&ParsedRequest) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = anyhow::Result<(UpstreamStream, ConnectionTiming)>> + Send + 'static,
{
    let mut guard = TEST_CONNECTOR.lock().unwrap();
    let arc_connector: Arc<TestConnectorFn> = Arc::new(move |req| Box::pin(connector(req)));
    *guard = Some(arc_connector);
}

#[cfg(test)]
fn reset_test_upstream_connector() {
    let mut guard = TEST_CONNECTOR.lock().unwrap();
    guard.take();
}

impl AsyncRead for UpstreamStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_read(cx, buf),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_read(cx, buf),
            UpstreamStream::Bridge(stream) => Pin::new(stream).poll_read(cx, buf),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for UpstreamStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_write(cx, data),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_write(cx, data),
            UpstreamStream::Bridge(stream) => Pin::new(stream).poll_write(cx, data),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_write(cx, data),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_flush(cx),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_flush(cx),
            UpstreamStream::Bridge(stream) => Pin::new(stream).poll_flush(cx),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_shutdown(cx),
            UpstreamStream::Bridge(stream) => Pin::new(stream).poll_shutdown(cx),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

/// A stream wrapper that reads from a prefix buffer before delegating to the inner stream.
/// Used to prevent data loss when we've already buffered part of the stream (e.g. after CONNECT).
struct PrefixedStream<S> {
    prefix: Option<std::io::Cursor<Vec<u8>>>,
    inner: S,
}

impl<S> PrefixedStream<S> {
    fn new(prefix: Vec<u8>, inner: S) -> Self {
        let prefix = if prefix.is_empty() {
            None
        } else {
            Some(std::io::Cursor::new(prefix))
        };
        Self { prefix, inner }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for PrefixedStream<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if let Some(prefix) = &mut self.prefix {
            let pos = prefix.position() as usize;
            let len = {
                let inner_buf = prefix.get_ref();
                let len = inner_buf.len();
                if pos < len {
                    let to_read = (len - pos).min(buf.remaining());
                    buf.put_slice(&inner_buf[pos..pos + to_read]);
                    to_read
                } else {
                    0
                }
            };

            if len > 0 {
                let new_pos = (pos + len) as u64;
                prefix.set_position(new_pos);
                if new_pos as usize == prefix.get_ref().len() {
                    self.prefix = None;
                }
                return Poll::Ready(Ok(()));
            } else {
                self.prefix = None;
            }
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for PrefixedStream<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

struct ParsedRequest {
    method: HttpMethod,
    scheme: String,
    host: String,
    port: u16,
    path: String,
    version: String,
    request_headers: HashMap<String, String>,
    header_list: Vec<(String, String)>,
    body_kind: RequestBodyKind,
    buffered_body: Vec<u8>,
    stream_id: Option<u32>,
    timing_handle: Option<Arc<TimingHandle>>,
}

/// Captures per-request timing for send, time-to-first-byte, and download completion.
/// Stored on ParsedRequest and shared across downstream/upstream bridges so timing stays consistent.
struct TimingHandle {
    start: Instant,
    request_send_ms: AtomicU32,
    waiting_ms: AtomicU32,
    content_download_ms: AtomicU32,
    send_recorded: AtomicBool,
    ttfb_recorded: AtomicBool,
    download_recorded: AtomicBool,
}

impl TimingHandle {
    fn new(start: Instant) -> Self {
        Self {
            start,
            request_send_ms: AtomicU32::new(0),
            waiting_ms: AtomicU32::new(0),
            content_download_ms: AtomicU32::new(0),
            send_recorded: AtomicBool::new(false),
            ttfb_recorded: AtomicBool::new(false),
            download_recorded: AtomicBool::new(false),
        }
    }

    fn record_send(&self) {
        if !self.send_recorded.swap(true, Ordering::Relaxed) {
            let ms = self.start.elapsed().as_millis().min(u32::MAX as u128) as u32;
            self.request_send_ms.store(ms, Ordering::Relaxed);
        }
    }

    fn record_waiting(&self) {
        if !self.ttfb_recorded.swap(true, Ordering::Relaxed) {
            let ms = self.start.elapsed().as_millis().min(u32::MAX as u128) as u32;
            self.waiting_ms.store(ms, Ordering::Relaxed);
        }
    }

    fn record_download(&self) {
        if !self.download_recorded.swap(true, Ordering::Relaxed) {
            let ms = self.start.elapsed().as_millis().min(u32::MAX as u128) as u32;
            self.content_download_ms.store(ms, Ordering::Relaxed);
        }
    }

    fn snapshot(&self) -> (Option<u32>, Option<u32>, Option<u32>) {
        let send = if self.send_recorded.load(Ordering::Relaxed) {
            Some(self.request_send_ms.load(Ordering::Relaxed))
        } else {
            None
        };
        let wait = if self.ttfb_recorded.load(Ordering::Relaxed) {
            Some(self.waiting_ms.load(Ordering::Relaxed))
        } else {
            None
        };
        let download = if self.download_recorded.load(Ordering::Relaxed) {
            Some(self.content_download_ms.load(Ordering::Relaxed))
        } else {
            None
        };
        (send, wait, download)
    }
}

fn apply_timing_handle(tx: &mut HttpTransaction, handle: Option<&Arc<TimingHandle>>) {
    if let Some(handle) = handle {
        let (send, wait, download) = handle.snapshot();
        if send.is_some() {
            tx.timing.request_send_ms = send;
        }
        if wait.is_some() {
            tx.timing.waiting_ms = wait;
        }
        if download.is_some() {
            tx.timing.content_download_ms = download;
        }
    }
}

impl ParsedRequest {
    fn to_breakpoint_context(&self) -> BreakpointContext {
        BreakpointContext {
            method: self.method,
            host: self.host.clone(),
            path: self.path.clone(),
        }
    }

    fn ensure_timing_handle(&mut self, start: Instant) -> Arc<TimingHandle> {
        if let Some(handle) = &self.timing_handle {
            handle.clone()
        } else {
            let handle = Arc::new(TimingHandle::new(start));
            self.timing_handle = Some(handle.clone());
            handle
        }
    }

    fn apply_edit(&mut self, edit: &RequestEdit) {
        if let Some(method) = edit.method {
            self.method = method;
        }
        if let Some(path) = &edit.path {
            self.path = path.clone();
        }
        if let Some(headers) = &edit.headers {
            self.header_list = headers
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            self.sync_header_map();
        }
        if let Some(body) = &edit.body {
            if body.len() > MAX_REQUEST_BODY_BYTES {
                // Truncate to the hard cap; the streaming path will still enforce it.
                let truncated = body[..MAX_REQUEST_BODY_BYTES].to_vec();
                self.body_kind = RequestBodyKind::Edited { data: truncated };
            } else {
                self.body_kind = RequestBodyKind::Edited { data: body.clone() };
            }
            self.buffered_body.clear();
            self.remove_header("transfer-encoding");
            self.set_header("Content-Length", self.body_kind.len().to_string());
        } else if matches!(self.body_kind, RequestBodyKind::Edited { .. }) {
            // Ensure headers stay consistent if edit removed the body explicitly
            self.remove_header("transfer-encoding");
            self.set_header("Content-Length", self.body_kind.len().to_string());
        }
    }

    fn set_header(&mut self, name: &str, value: String) {
        let mut updated = false;
        for (key, val) in self.header_list.iter_mut() {
            if key.eq_ignore_ascii_case(name) {
                *val = value.clone();
                updated = true;
                break;
            }
        }
        if !updated {
            self.header_list.push((name.to_string(), value.clone()));
        }
        self.sync_header_map();
    }

    fn remove_header(&mut self, name: &str) {
        self.header_list
            .retain(|(key, _)| !key.eq_ignore_ascii_case(name));
        self.sync_header_map();
    }

    fn sync_header_map(&mut self) {
        self.request_headers = self.header_list.iter().cloned().collect();
    }
}

#[derive(Debug, PartialEq, Clone)]
enum RequestBodyKind {
    None,
    ContentLength { length: usize },
    Chunked,
    Edited { data: Vec<u8> },
}

impl RequestBodyKind {
    fn len(&self) -> usize {
        match self {
            RequestBodyKind::None => 0,
            RequestBodyKind::ContentLength { length } => *length,
            RequestBodyKind::Chunked => 0,
            RequestBodyKind::Edited { data } => data.len(),
        }
    }
}

struct BodyCapture {
    buf: Vec<u8>,
    limit: usize,
}

impl BodyCapture {
    fn new(limit: usize) -> Self {
        Self {
            buf: Vec::new(),
            limit,
        }
    }

    fn push(&mut self, data: &[u8]) {
        if self.buf.len() >= self.limit {
            return;
        }
        let remaining = self.limit - self.buf.len();
        let to_take = remaining.min(data.len());
        if to_take > 0 {
            self.buf.extend_from_slice(&data[..to_take]);
        }
    }

    fn into_option(self) -> Option<Vec<u8>> {
        if self.buf.is_empty() {
            None
        } else {
            Some(self.buf)
        }
    }
}

struct ResponseHead {
    status_code: u16,
    reason: String,
    headers: HashMap<String, String>,
    raw_head: Vec<u8>,
    body_prefix: Vec<u8>,
}

#[derive(Clone, Copy)]
enum RequestScheme {
    Http,
    Https,
}

impl RequestScheme {
    fn as_str(&self) -> &'static str {
        match self {
            RequestScheme::Http => "http",
            RequestScheme::Https => "https",
        }
    }

    fn default_port(&self) -> u16 {
        match self {
            RequestScheme::Http => 80,
            RequestScheme::Https => 443,
        }
    }
}

async fn read_http_request<S>(
    stream: &mut S,
    default_scheme: RequestScheme,
) -> anyhow::Result<ParsedRequest>
where
    S: AsyncRead + Unpin,
{
    let (raw_head, buffered_body) = read_message_head(stream).await?;

    let mut header_storage = [httparse::EMPTY_HEADER; MAX_HEADER_COUNT];
    let mut req = httparse::Request::new(&mut header_storage);
    let status = req.parse(&raw_head)?;
    if status.is_partial() {
        return Err(anyhow!("partial HTTP request"));
    }

    let method_str = req.method.unwrap_or("GET");
    let path_raw = req.path.unwrap_or("/");
    let version = format!("HTTP/1.{}", req.version.unwrap_or(1));

    let headers_vec = headers_from_httparse(req.headers);
    let header_map = headers_vec
        .iter()
        .cloned()
        .collect::<HashMap<String, String>>();

    let content_length =
        header_value(&header_map, "content-length").and_then(|v| v.parse::<usize>().ok());
    if let Some(len) = content_length {
        if len > MAX_REQUEST_BODY_BYTES {
            return Err(RequestBodyTooLarge::new(MAX_REQUEST_BODY_BYTES).into());
        }
    }
    let is_chunked = header_value(&header_map, "transfer-encoding")
        .map(|v| v.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false);

    let method = HttpMethod::from_str_lossy(method_str);
    if method == HttpMethod::Connect {
        let (host, port) = split_host_and_port(path_raw, 443);
        return Ok(ParsedRequest {
            method,
            scheme: "https".to_string(),
            host,
            port,
            path: "/".to_string(),
            version,
            request_headers: header_map,
            header_list: headers_vec,
            body_kind: RequestBodyKind::None,
            buffered_body,
            stream_id: None,
            timing_handle: None,
        });
    }

    let (scheme, host, port, path) = resolve_target(path_raw, &header_map, default_scheme)?;
    let body_kind = if is_chunked {
        RequestBodyKind::Chunked
    } else if let Some(len) = content_length {
        RequestBodyKind::ContentLength { length: len }
    } else {
        RequestBodyKind::None
    };

    Ok(ParsedRequest {
        method,
        scheme,
        host,
        port,
        path,
        version,
        request_headers: header_map,
        header_list: headers_vec,
        body_kind,
        buffered_body,
        stream_id: None,
        timing_handle: None,
    })
}

async fn handle_connect_tunnel(
    client: TcpStream,
    parsed: ParsedRequest,
    cert_manager: Option<Arc<CertManager>>,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<()> {
    if let (Some(manager), Some(tls_config)) = (cert_manager, tls_client_config) {
        intercept_tls_connection(
            client,
            parsed.buffered_body,
            parsed.host.clone(),
            manager,
            tls_config,
        )
        .await?;
        return Ok(());
    }

    handle_plain_connect(client, parsed).await
}

async fn intercept_tls_connection(
    client: TcpStream,
    buffered_body: Vec<u8>,
    host: String,
    cert_manager: Arc<CertManager>,
    tls_client_config: Arc<ClientConfig>,
) -> anyhow::Result<()> {
    intercept_tls_stream(
        PrefixedStream::new(buffered_body, client),
        host,
        cert_manager,
        tls_client_config,
    )
    .await
}

async fn intercept_tls_stream<S>(
    mut client: S,
    host: String,
    cert_manager: Arc<CertManager>,
    tls_client_config: Arc<ClientConfig>,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let server_config = cert_manager
        .server_config_for_host(&host)
        .context("Failed to build server config")?;

    client
        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        .await?;

    let acceptor = TlsAcceptor::from(server_config);
    let tls_stream = acceptor.accept(client).await?;
    let alpn = tls_stream.get_ref().1.alpn_protocol().map(|p| p.to_vec());
    let mut tls_stream = tls_stream;

    if alpn.as_deref() == Some(b"h2") {
        return handle_h2_connection(tls_stream, host, Some(tls_client_config)).await;
    }

    let mut request_count: u32 = 0;

    loop {
        request_count += 1;
        let req_start = Instant::now();
        let parsed_request = match read_http_request(&mut tls_stream, RequestScheme::Https).await {
            Ok(req) => req,
            Err(err) => {
                if request_count == 1 {
                    let is_too_large = err.downcast_ref::<RequestBodyTooLarge>().is_some();
                    let (code, label, body) = if is_too_large {
                        (
                            413,
                            "Payload Too Large",
                            "Request body exceeds allowed size",
                        )
                    } else {
                        (400, "Bad Request", "Unable to parse HTTPS request")
                    };
                    tracing::warn!("Failed to parse HTTPS request: {err}");
                    let _ = respond_with_status(&mut tls_stream, code, label, body).await;
                } else {
                    tracing::debug!(
                        "HTTPS keep-alive connection closed after {} requests: {err}",
                        request_count - 1
                    );
                }
                break;
            }
        };

        let keep_alive =
            should_keep_alive(&parsed_request.version, &parsed_request.request_headers);

        if let Err(err) = process_request(
            &mut tls_stream,
            parsed_request,
            req_start,
            Some(tls_client_config.clone()),
            request_count > 1,
        )
        .await
        {
            tracing::debug!("HTTPS request processing error: {err}");
            break;
        }

        if !keep_alive {
            break;
        }
    }

    Ok(())
}

async fn handle_plain_connect(mut client: TcpStream, parsed: ParsedRequest) -> anyhow::Result<()> {
    let mut tx = HttpTransaction::new(
        parsed.method,
        &parsed.scheme,
        &parsed.host,
        parsed.port,
        "/",
        parsed.request_headers.clone(),
    );
    tx.notes = Some("HTTPS Tunnel".to_string());
    send_transaction_to_sink(tx.clone());

    match TcpStream::connect(format!("{}:{}", parsed.host, parsed.port)).await {
        Ok(upstream) => {
            client
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await?;

            tx.state = TransactionState::Completed;
            tx.status_code = Some(200);
            tx.status_message = Some("Connection Established".to_string());
            send_transaction_to_sink(tx);

            tunnel(PrefixedStream::new(parsed.buffered_body, client), upstream).await?;
        }
        Err(e) => {
            tracing::error!(
                "Failed to establish CONNECT tunnel to {}:{} - {}",
                parsed.host,
                parsed.port,
                e
            );
            client
                .write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                .await?;

            tx.state = TransactionState::Failed;
            tx.status_code = Some(502);
            send_transaction_to_sink(tx);
        }
    }

    Ok(())
}

async fn read_response_head<S>(stream: &mut S) -> anyhow::Result<ResponseHead>
where
    S: AsyncRead + Unpin,
{
    let (raw_head, buffered_body) = read_message_head(stream).await?;

    let mut header_storage = [httparse::EMPTY_HEADER; MAX_HEADER_COUNT];
    let mut res = httparse::Response::new(&mut header_storage);
    let status = res.parse(&raw_head)?;
    if status.is_partial() {
        return Err(anyhow!("partial HTTP response"));
    }

    let status_code = res.code.unwrap_or(500);
    let reason = res.reason.unwrap_or("").to_string();
    let headers = headers_from_httparse(res.headers)
        .into_iter()
        .collect::<HashMap<String, String>>();

    Ok(ResponseHead {
        status_code,
        reason,
        headers,
        raw_head,
        body_prefix: buffered_body,
    })
}

async fn read_message_head<S>(stream: &mut S) -> anyhow::Result<(Vec<u8>, Vec<u8>)>
where
    S: AsyncRead + Unpin,
{
    let mut buffer = Vec::with_capacity(2048);
    let mut temp = [0u8; 4096];

    loop {
        let bytes_read = stream.read(&mut temp).await?;
        if bytes_read == 0 {
            break;
        }
        buffer.extend_from_slice(&temp[..bytes_read]);

        if let Some(pos) = find_header_end(&buffer) {
            let remaining = buffer.split_off(pos);
            return Ok((buffer, remaining));
        }

        if buffer.len() > MAX_HEADER_BYTES {
            return Err(anyhow!("HTTP headers exceed allowed size"));
        }
    }

    Err(anyhow!("connection closed before headers completed"))
}

async fn read_exact_body<S>(stream: &mut S, expected_len: usize) -> anyhow::Result<Vec<u8>>
where
    S: AsyncRead + Unpin,
{
    let mut body = Vec::with_capacity(expected_len);
    let mut remaining = expected_len;

    while remaining > 0 {
        let mut chunk = vec![0u8; remaining.min(8192)];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(anyhow!("connection closed while reading response body"));
        }
        body.extend_from_slice(&chunk[..read]);
        remaining -= read;
    }

    Ok(body)
}

async fn stream_response_body<R, W>(upstream: &mut R, client: &mut W) -> anyhow::Result<u64>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let bytes = tokio::io::copy(upstream, client).await?;
    Ok(bytes)
}

async fn forward_chunked_body<R, W>(
    initial_buffer: Vec<u8>,
    upstream: &mut R,
    client: &mut W,
) -> anyhow::Result<(Vec<u8>, u64)>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buffer: VecDeque<u8> = initial_buffer.into();
    let mut captured = Vec::new();
    let mut total_body_bytes = 0u64;

    loop {
        let line = read_crlf_line(&mut buffer, upstream).await?;
        if line.len() < 2 {
            return Err(anyhow!("invalid chunked encoding: missing CRLF"));
        }
        client.write_all(&line).await?;

        let header_bytes = &line[..line.len() - 2];
        let size_token = std::str::from_utf8(header_bytes)
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let chunk_size = usize::from_str_radix(size_token, 16)
            .map_err(|_| anyhow!("invalid chunk size: {size_token}"))?;

        if chunk_size == 0 {
            // Trailers end with blank line
            loop {
                let trailer_line = read_crlf_line(&mut buffer, upstream).await?;
                client.write_all(&trailer_line).await?;
                if trailer_line == b"\r\n" {
                    break;
                }
            }
            break;
        }

        let chunk_data = read_exact_from_buffer(&mut buffer, upstream, chunk_size).await?;
        client.write_all(&chunk_data).await?;
        total_body_bytes += chunk_size as u64;

        if captured.len() < MAX_BODY_CAPTURE_BYTES {
            let remaining = MAX_BODY_CAPTURE_BYTES - captured.len();
            let capture_len = remaining.min(chunk_data.len());
            captured.extend_from_slice(&chunk_data[..capture_len]);
        }

        let crlf = read_exact_from_buffer(&mut buffer, upstream, 2).await?;
        if crlf != b"\r\n" {
            return Err(anyhow!("invalid chunk terminator"));
        }
        client.write_all(&crlf).await?;
    }

    Ok((captured, total_body_bytes))
}

struct NullWriter;

impl AsyncWrite for NullWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut TaskContext<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

#[allow(dead_code)]
async fn decode_chunked_body<R>(
    initial_buffer: Vec<u8>,
    upstream: &mut R,
) -> anyhow::Result<(Vec<u8>, u64)>
where
    R: AsyncRead + Unpin,
{
    let mut sink = NullWriter;
    forward_chunked_body(initial_buffer, upstream, &mut sink).await
}

async fn read_crlf_line<R>(buffer: &mut VecDeque<u8>, stream: &mut R) -> anyhow::Result<Vec<u8>>
where
    R: AsyncRead + Unpin,
{
    loop {
        if let Some(pos) = find_crlf_in_deque(buffer) {
            let mut line = Vec::with_capacity(pos + 2);
            for _ in 0..=pos + 1 {
                if let Some(b) = buffer.pop_front() {
                    line.push(b);
                }
            }
            return Ok(line);
        }
        fill_buffer(buffer, stream).await?;
    }
}

async fn read_exact_from_buffer<R>(
    buffer: &mut VecDeque<u8>,
    stream: &mut R,
    len: usize,
) -> anyhow::Result<Vec<u8>>
where
    R: AsyncRead + Unpin,
{
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        while let Some(b) = buffer.pop_front() {
            out.push(b);
            if out.len() == len {
                break;
            }
        }

        if out.len() < len {
            fill_buffer(buffer, stream).await?;
        }
    }
    Ok(out)
}

async fn fill_buffer<R>(buffer: &mut VecDeque<u8>, stream: &mut R) -> anyhow::Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut temp = [0u8; 4096];
    let read = stream.read(&mut temp).await?;
    if read == 0 {
        return Err(anyhow!("connection closed while reading chunked body"));
    }
    buffer.extend(&temp[..read]);
    Ok(())
}

fn find_crlf_in_deque(buffer: &VecDeque<u8>) -> Option<usize> {
    if buffer.len() < 2 {
        return None;
    }
    (0..buffer.len() - 1).find(|&i| buffer[i] == b'\r' && buffer[i + 1] == b'\n')
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|pos| pos + 4)
}

fn headers_from_httparse(headers: &[httparse::Header]) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|h| {
            let name = h.name.to_string();
            let value = String::from_utf8_lossy(h.value).to_string();
            (name, value)
        })
        .collect()
}

fn header_value(headers: &HashMap<String, String>, name: &str) -> Option<String> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.clone())
}

fn capture_body(body: &[u8]) -> Option<Vec<u8>> {
    if body.is_empty() {
        return None;
    }
    let cap = body.len().min(MAX_BODY_CAPTURE_BYTES);
    Some(body[..cap].to_vec())
}

fn resolve_target(
    raw_path: &str,
    headers: &HashMap<String, String>,
    default_scheme: RequestScheme,
) -> anyhow::Result<(String, String, u16, String)> {
    if raw_path.starts_with("http://") {
        return parse_absolute_target(raw_path, RequestScheme::Http);
    }

    if raw_path.starts_with("https://") {
        return parse_absolute_target(raw_path, RequestScheme::Https);
    }

    let host_header = header_value(headers, "host")
        .ok_or_else(|| anyhow!("Missing Host header in HTTP/1.1 request"))?;
    let (host, port) = split_host_and_port(&host_header, default_scheme.default_port());

    Ok((
        default_scheme.as_str().to_string(),
        host,
        port,
        raw_path.to_string(),
    ))
}

fn parse_absolute_target(
    target: &str,
    scheme: RequestScheme,
) -> anyhow::Result<(String, String, u16, String)> {
    let without_scheme = target
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(target);
    let (host_port, path_part) = if let Some((host, path)) = without_scheme.split_once('/') {
        (host, format!("/{}", path))
    } else {
        (without_scheme, "/".to_string())
    };

    let (host, port) = split_host_and_port(host_port, scheme.default_port());
    Ok((scheme.as_str().to_string(), host, port, path_part))
}

fn split_host_and_port(input: &str, default_port: u16) -> (String, u16) {
    if let Some((host, port)) = input.rsplit_once(':') {
        if let Ok(parsed) = port.parse::<u16>() {
            return (host.to_string(), parsed);
        }
    }
    (input.to_string(), default_port)
}

async fn respond_with_status<W>(
    stream: &mut W,
    code: u16,
    message: &str,
    body: &str,
) -> anyhow::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let body_bytes = body.as_bytes();
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n{}",
        code,
        message,
        body_bytes.len(),
        body
    );
    stream.write_all(response.as_bytes()).await?;
    Ok(())
}

async fn persist_and_stream(tx: HttpTransaction) {
    if let Err(err) = storage::persist_transaction(tx.clone()).await {
        tracing::error!("Failed to persist transaction: {}", err);
    }
    send_transaction_to_sink(tx);
}

async fn forward_request_to_upstream<S, U>(
    client: &mut S,
    upstream: &mut U,
    parsed_request: &mut ParsedRequest,
    capture: &mut BodyCapture,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
    U: AsyncRead + AsyncWrite + Unpin + Send,
{
    write_request_head(
        upstream,
        &parsed_request.method.to_string(),
        &parsed_request.path,
        &parsed_request.version,
        &parsed_request.header_list,
    )
    .await?;

    match &mut parsed_request.body_kind {
        RequestBodyKind::None => {}
        RequestBodyKind::ContentLength { length } => {
            if *length > MAX_REQUEST_BODY_BYTES {
                return Err(RequestBodyTooLarge::new(MAX_REQUEST_BODY_BYTES).into());
            }
            forward_fixed_length_body(
                client,
                upstream,
                &mut parsed_request.buffered_body,
                *length,
                capture,
            )
            .await?;
        }
        RequestBodyKind::Chunked => {
            forward_chunked_request_body(
                client,
                upstream,
                &mut parsed_request.buffered_body,
                capture,
            )
            .await?;
        }
        RequestBodyKind::Edited { data } => {
            if data.len() > MAX_REQUEST_BODY_BYTES {
                return Err(RequestBodyTooLarge::new(MAX_REQUEST_BODY_BYTES).into());
            }
            upstream.write_all(data).await?;
            capture.push(data);
        }
    }

    Ok(())
}

async fn handle_breakpoints(
    tx: &mut HttpTransaction,
    parsed_request: &mut ParsedRequest,
) -> anyhow::Result<()> {
    if let Some(edit) =
        breakpoints::maybe_pause_request(tx, parsed_request.to_breakpoint_context()).await?
    {
        parsed_request.apply_edit(&edit);
        update_transaction_from_parsed(tx, parsed_request);
        send_transaction_to_sink(tx.clone());
    }
    Ok(())
}

async fn write_request_head<W>(
    writer: &mut W,
    method: &str,
    path: &str,
    version: &str,
    headers: &[(String, String)],
) -> anyhow::Result<()>
where
    W: AsyncWrite + Unpin,
{
    // If version is HTTP/2 but we are using this H1.1-style writer (e.g. via our bridge),
    // we must downgrade the string version back to HTTP/1.1 so the upstream server
    // doesn't reject it.
    let version_str = if version == "HTTP/2" {
        "HTTP/1.1"
    } else {
        version
    };
    writer
        .write_all(format!("{method} {path} {version_str}\r\n").as_bytes())
        .await?;

    let mut has_connection = false;
    for (name, value) in headers {
        if name.eq_ignore_ascii_case("Proxy-Connection") || name.eq_ignore_ascii_case("Keep-Alive")
        {
            continue;
        }
        if name.eq_ignore_ascii_case("Connection") {
            has_connection = true;
            writer.write_all(b"Connection: close\r\n").await?;
            continue;
        }
        writer
            .write_all(format!("{name}: {value}\r\n").as_bytes())
            .await?;
    }
    if !has_connection {
        writer.write_all(b"Connection: close\r\n").await?;
    }
    writer.write_all(b"\r\n").await?;
    Ok(())
}

async fn forward_fixed_length_body<C, U>(
    client: &mut C,
    upstream: &mut U,
    buffered: &mut Vec<u8>,
    expected_len: usize,
    capture: &mut BodyCapture,
) -> anyhow::Result<()>
where
    C: AsyncRead + Unpin,
    U: AsyncWrite + Unpin,
{
    let mut remaining = expected_len;
    if remaining == 0 {
        buffered.clear();
        return Ok(());
    }

    if !buffered.is_empty() {
        let to_take = remaining.min(buffered.len());
        upstream.write_all(&buffered[..to_take]).await?;
        capture.push(&buffered[..to_take]);
        remaining -= to_take;
        buffered.drain(..to_take);
    }

    let mut buf = vec![0u8; 8192];
    while remaining > 0 {
        let read_len = buf.len().min(remaining);
        let n = client.read(&mut buf[..read_len]).await?;
        if n == 0 {
            return Err(anyhow!("connection closed while reading request body"));
        }
        upstream.write_all(&buf[..n]).await?;
        capture.push(&buf[..n]);
        remaining -= n;
    }
    Ok(())
}

async fn forward_chunked_request_body<C, U>(
    client: &mut C,
    upstream: &mut U,
    buffered: &mut Vec<u8>,
    capture: &mut BodyCapture,
) -> anyhow::Result<()>
where
    C: AsyncRead + Unpin,
    U: AsyncWrite + Unpin,
{
    let mut buffer: VecDeque<u8> = std::mem::take(buffered).into();
    let mut total_bytes: usize = 0;

    loop {
        let line = read_crlf_line(&mut buffer, client).await?;
        if line.len() < 2 {
            return Err(anyhow!("invalid chunk header"));
        }
        upstream.write_all(&line).await?;

        let header_bytes = &line[..line.len() - 2];
        let size_token = std::str::from_utf8(header_bytes)
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let chunk_size = usize::from_str_radix(size_token, 16)
            .map_err(|_| anyhow!("invalid chunk size: {size_token}"))?;

        if chunk_size == 0 {
            loop {
                let trailer_line = read_crlf_line(&mut buffer, client).await?;
                upstream.write_all(&trailer_line).await?;
                if trailer_line == b"\r\n" {
                    break;
                }
            }
            break;
        }

        total_bytes = total_bytes
            .checked_add(chunk_size)
            .ok_or_else(|| RequestBodyTooLarge::new(MAX_REQUEST_BODY_BYTES))?;
        if total_bytes > MAX_REQUEST_BODY_BYTES {
            return Err(RequestBodyTooLarge::new(MAX_REQUEST_BODY_BYTES).into());
        }

        let chunk_data = read_exact_from_buffer(&mut buffer, client, chunk_size).await?;
        upstream.write_all(&chunk_data).await?;
        capture.push(&chunk_data);

        let crlf = read_exact_from_buffer(&mut buffer, client, 2).await?;
        if crlf != b"\r\n" {
            return Err(anyhow!("invalid chunk terminator"));
        }
        upstream.write_all(&crlf).await?;
    }

    *buffered = buffer.into();
    Ok(())
}

fn update_transaction_from_parsed(tx: &mut HttpTransaction, parsed: &ParsedRequest) {
    tx.method = parsed.method;
    tx.path = parsed.path.clone();
    tx.scheme = parsed.scheme.clone();
    tx.host = parsed.host.clone();
    tx.http_version = parsed.version.clone();
    tx.stream_id = tx.stream_id.or(parsed.stream_id);
    tx.request_headers = parsed.request_headers.clone();
    tx.request_content_type = header_value(&parsed.request_headers, "content-type");
    if let RequestBodyKind::Edited { data } = &parsed.body_kind {
        tx.request_body = capture_body(data);
    }
}

async fn handle_h2_connection<S>(
    tls_stream: S,
    intercept_host: String,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let stream_counter = Arc::new(AtomicU32::new(1));
    let service = service_fn(move |req: Request<Incoming>| {
        handle_h2_hyper_request(
            req,
            intercept_host.clone(),
            tls_client_config.clone(),
            stream_counter.clone(),
        )
    });

    let io = TokioIo::new(tls_stream);
    AutoServerBuilder::new(TokioExecutor::new())
        .http2_only()
        .serve_connection(io, service)
        .await
        .map_err(|e| anyhow!(e))?;
    Ok(())
}

type RespBody = BoxBody<Bytes, Infallible>;
type ReqBody = BoxBody<Bytes, Infallible>;

fn boxed_full_bytes(data: Bytes) -> RespBody {
    Full::new(data).boxed()
}

async fn handle_h2_hyper_request(
    req: Request<Incoming>,
    intercept_host: String,
    tls_client_config: Option<Arc<ClientConfig>>,
    stream_counter: Arc<AtomicU32>,
) -> Result<HyperResponse<RespBody>, hyper::Error> {
    let req_start = Instant::now();

    // Build ParsedRequest directly from Hyper request
    let mut header_list = Vec::new();
    let mut header_map = HashMap::new();
    for (name, value) in req.headers().iter() {
        let name_str = name.to_string();
        let value_str = String::from_utf8_lossy(value.as_bytes()).to_string();
        header_list.push((name_str.clone(), value_str.clone()));
        header_map.insert(name_str, value_str);
    }

    let method = HttpMethod::from_str_lossy(req.method().as_str());
    let path = req
        .uri()
        .path_and_query()
        .map(|pq| pq.to_string())
        .unwrap_or_else(|| "/".to_string());

    let host = req
        .uri()
        .authority()
        .map(|a| a.host().to_string())
        .or_else(|| header_value(&header_map, "host"))
        .unwrap_or_else(|| intercept_host.clone());

    let port = req
        .uri()
        .authority()
        .and_then(|a| a.port_u16())
        .unwrap_or(443);

    let body_bytes = match req.into_body().collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(e) => {
            let response = HyperResponse::builder()
                .status(400)
                .body(boxed_full_bytes(Bytes::from(format!(
                    "Failed to read request body: {e}"
                ))))
                .unwrap();
            return Ok(response);
        }
    };

    if !body_bytes.is_empty() || matches!(method, HttpMethod::Post | HttpMethod::Put) {
        let len = body_bytes.len().to_string();
        header_map.insert("Content-Length".to_string(), len.clone());
        header_list.push(("Content-Length".to_string(), len));
    } else {
        header_map.remove("Content-Length");
        header_list.retain(|(k, _)| !k.eq_ignore_ascii_case("Content-Length"));
    }

    let timing_handle = Arc::new(TimingHandle::new(req_start));
    timing_handle.record_send();

    let parsed_request = ParsedRequest {
        method,
        scheme: "https".to_string(),
        host,
        port,
        path,
        version: "HTTP/2".to_string(),
        request_headers: header_map,
        header_list,
        body_kind: RequestBodyKind::Edited {
            data: body_bytes.to_vec(),
        },
        buffered_body: Vec::new(),
        stream_id: Some(stream_counter.fetch_add(1, Ordering::Relaxed)),
        timing_handle: Some(timing_handle.clone()),
    };

    // Duplex pipe: process_request writes the H1 response into writer_end, we read it to build Hyper response
    let (mut reader_end, mut writer_end) = tokio::io::duplex(1024 * 1024);
    let timing_for_response = parsed_request.timing_handle.clone();

    let process_task = tokio::spawn(async move {
        process_request(
            &mut writer_end,
            parsed_request,
            req_start,
            tls_client_config,
            false,
        )
        .await
    });

    // Read the H1 response head from the reader_end
    let response = match read_message_head(&mut reader_end).await {
        Ok((raw_head, body_prefix)) => {
            match build_hyper_response_from_h1(
                raw_head,
                body_prefix,
                reader_end,
                timing_for_response,
            )
            .await
            {
                Ok(resp) => resp,
                Err(err) => {
                    tracing::error!("Failed to translate H1 response to Hyper: {err}");
                    HyperResponse::builder()
                        .status(502)
                        .body(boxed_full_bytes(Bytes::from("Bad Gateway")))
                        .unwrap()
                }
            }
        }
        Err(err) => {
            tracing::error!("Failed to read H1 response head: {err}");
            HyperResponse::builder()
                .status(502)
                .body(boxed_full_bytes(Bytes::from("Bad Gateway")))
                .unwrap()
        }
    };

    // Ensure process_request is awaited to propagate errors (logged already)
    if let Err(e) = process_task.await {
        tracing::debug!("process_request task ended with error: {}", e);
    }

    Ok(response)
}

async fn build_hyper_response_from_h1(
    raw_head: Vec<u8>,
    body_prefix: Vec<u8>,
    mut reader: DuplexStream,
    timing_handle: Option<Arc<TimingHandle>>,
) -> anyhow::Result<HyperResponse<RespBody>> {
    let mut header_storage = [httparse::EMPTY_HEADER; MAX_HEADER_COUNT];
    let mut res = httparse::Response::new(&mut header_storage);
    let status = res.parse(&raw_head)?;
    if status.is_partial() {
        return Err(anyhow!("partial HTTP response"));
    }

    let status_code = res.code.unwrap_or(500);
    let mut builder = HyperResponse::builder().status(status_code);

    let mut is_chunked = false;
    let mut content_length: Option<usize> = None;
    for h in res.headers.iter() {
        let name = h.name.to_ascii_lowercase();
        if name == "transfer-encoding"
            && h.value
                .to_ascii_lowercase()
                .windows(7)
                .any(|w| w == b"chunked")
        {
            is_chunked = true;
            continue;
        }
        if name == "connection"
            || name == "keep-alive"
            || name == "proxy-connection"
            || name == "upgrade"
        {
            continue;
        }
        if name == "content-length" {
            content_length = std::str::from_utf8(h.value)
                .ok()
                .and_then(|s| s.parse::<usize>().ok());
        }
        builder = builder.header(h.name, h.value);
    }

    // Stream body via channel to avoid buffering large responses
    let (mut tx, rx) = Channel::new(64 * 1024);
    let response_body: RespBody = rx.boxed();

    tokio::spawn(async move {
        let forward = async {
            if let Some(handle) = &timing_handle {
                handle.record_waiting();
            }
            if is_chunked {
                let mut buffer: VecDeque<u8> = body_prefix.into();
                loop {
                    let line = read_crlf_line(&mut buffer, &mut reader).await?;
                    if line.len() < 2 {
                        return Err(anyhow!("invalid chunked encoding: missing CRLF"));
                    }
                    let size_token = std::str::from_utf8(&line[..line.len() - 2])
                        .unwrap_or("")
                        .split(';')
                        .next()
                        .unwrap_or("")
                        .trim();
                    let chunk_size = usize::from_str_radix(size_token, 16)
                        .map_err(|_| anyhow!("invalid chunk size: {size_token}"))?;

                    if chunk_size == 0 {
                        // Drain trailers
                        loop {
                            let trailer_line = read_crlf_line(&mut buffer, &mut reader).await?;
                            if trailer_line
                                == b"
"
                            {
                                break;
                            }
                        }
                        break;
                    }

                    let chunk_data =
                        read_exact_from_buffer(&mut buffer, &mut reader, chunk_size).await?;
                    tx.send_data(Bytes::from(chunk_data)).await?;
                    let _ = read_exact_from_buffer(&mut buffer, &mut reader, 2).await?;
                }
            } else if let Some(len) = content_length {
                let mut remaining = len.saturating_sub(body_prefix.len());
                let buffer = body_prefix;
                if !buffer.is_empty() {
                    tx.send_data(Bytes::from(buffer.clone())).await?;
                }
                let mut buf = [0u8; 16 * 1024];
                while remaining > 0 {
                    let n = reader.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    remaining = remaining.saturating_sub(n);
                    tx.send_data(Bytes::copy_from_slice(&buf[..n])).await?;
                }
            } else {
                let mut buf = [0u8; 16 * 1024];
                let mut pending = body_prefix;
                loop {
                    let n = reader.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    pending.extend_from_slice(&buf[..n]);
                    if pending.len() >= 16 * 1024 {
                        let chunk = std::mem::take(&mut pending);
                        tx.send_data(Bytes::from(chunk)).await?;
                    }
                }
                if !pending.is_empty() {
                    tx.send_data(Bytes::from(pending)).await?;
                }
            }
            tx.send_data(Bytes::new()).await?;
            if let Some(handle) = &timing_handle {
                handle.record_download();
            }
            Ok::<(), anyhow::Error>(())
        };

        if let Err(err) = forward.await {
            tracing::debug!("Error streaming H1->Hyper body: {}", err);
            let _ = tx.send_data(Bytes::new()).await;
        }
    });
    let response = builder.body(response_body)?;
    Ok(response)
}

#[allow(dead_code)]
async fn bridge_h2_to_h1(
    bridge_side: DuplexStream,
    mut h2_recv: h2::RecvStream,
    mut respond: h2::server::SendResponse<Bytes>,
    chunk_request: bool,
) -> anyhow::Result<()> {
    let (mut reader, mut writer) = tokio::io::split(bridge_side);

    // Request Body: H2 -> H1 write
    let req_body_handle = tokio::spawn(async move {
        while let Some(chunk) = h2_recv.data().await {
            let data = chunk?;
            if chunk_request {
                writer
                    .write_all(format!("{:x}\r\n", data.len()).as_bytes())
                    .await?;
                writer.write_all(&data).await?;
                writer.write_all(b"\r\n").await?;
            } else {
                writer.write_all(&data).await?;
            }
            let _ = h2_recv.flow_control().release_capacity(data.len());
        }
        if chunk_request {
            writer.write_all(b"0\r\n\r\n").await?;
        }
        writer.shutdown().await?;
        Ok::<(), anyhow::Error>(())
    });

    // Response: H1 read -> H2 respond
    let res_handle = tokio::spawn(async move {
        // Read H1 response head
        let (raw_head, body_prefix) = read_message_head(&mut reader).await?;

        // Parse the H1 response
        let mut header_storage = [httparse::EMPTY_HEADER; MAX_HEADER_COUNT];
        let mut res = httparse::Response::new(&mut header_storage);
        let _ = res.parse(&raw_head)?;

        let mut is_chunked = false;
        let mut content_length: Option<usize> = None;
        let status = http::StatusCode::from_u16(res.code.unwrap_or(500))?;
        let mut builder = http::Response::builder().status(status);

        for h in res.headers.iter() {
            let name = h.name.to_lowercase();
            if name == "content-length" {
                content_length = String::from_utf8_lossy(h.value).parse().ok();
            }
            if name == "transfer-encoding"
                && h.value
                    .to_ascii_lowercase()
                    .windows(7)
                    .any(|w| w == b"chunked")
            {
                is_chunked = true;
                continue;
            }
            // Filter out other forbidden H1.1 headers
            if name == "connection"
                || name == "keep-alive"
                || name == "proxy-connection"
                || name == "upgrade"
            {
                continue;
            }
            builder = builder.header(h.name, h.value);
        }

        let mut h2_send = respond.send_response(builder.body(())?, false)?;

        // If not chunked, we can just pipe. If chunked, we must de-chunk.
        if is_chunked {
            use tokio::io::AsyncReadExt;
            let mut combined_reader: Pin<Box<dyn AsyncRead + Send>> = if !body_prefix.is_empty() {
                Box::pin(tokio::io::AsyncReadExt::chain(
                    std::io::Cursor::new(body_prefix),
                    reader,
                ))
            } else {
                Box::pin(reader)
            };

            loop {
                // Read chunk size line
                let mut line = Vec::new();
                let mut b = [0u8; 1];
                loop {
                    combined_reader.read_exact(&mut b).await?;
                    line.push(b[0]);
                    if line.ends_with(b"\r\n") {
                        break;
                    }
                }
                let line_str = std::str::from_utf8(&line)?.trim();
                let chunk_size = usize::from_str_radix(line_str, 16)?;

                if chunk_size == 0 {
                    // Drain final \r\n
                    let mut b = [0u8; 2];
                    combined_reader.read_exact(&mut b).await?;
                    h2_send.send_data(Bytes::new(), true)?;
                    break;
                }

                let mut data = vec![0u8; chunk_size];
                combined_reader.read_exact(&mut data).await?;
                // Drain \r\n
                let mut b = [0u8; 2];
                combined_reader.read_exact(&mut b).await?;

                h2_send.send_data(Bytes::from(data), false)?;
            }
        } else if let Some(len) = content_length {
            if !body_prefix.is_empty() {
                h2_send.send_data(Bytes::copy_from_slice(&body_prefix), false)?;
            }
            let prefix_len = body_prefix.len();
            if prefix_len < len {
                let mut remaining = len - prefix_len;
                let mut buf = [0u8; 16384];
                while remaining > 0 {
                    let to_read = remaining.min(buf.len());
                    let n = reader.read(&mut buf[..to_read]).await?;
                    if n == 0 {
                        break;
                    }
                    h2_send.send_data(Bytes::copy_from_slice(&buf[..n]), false)?;
                    remaining -= n;
                }
            }
            h2_send.send_data(Bytes::new(), true)?;
        } else if !body_prefix.is_empty() {
            h2_send.send_data(Bytes::copy_from_slice(&body_prefix), true)?;
        } else {
            h2_send.send_data(Bytes::new(), true)?;
        }

        Ok::<(), anyhow::Error>(())
    });

    let (r1, r2) = tokio::join!(req_body_handle, res_handle);
    r1??;
    r2??;
    Ok(())
}

async fn bridge_h1_to_hyper_upstream(
    mut h1_side: DuplexStream,
    mut h2_client: hyper::client::conn::http2::SendRequest<ReqBody>,
    timing_handle: Option<Arc<TimingHandle>>,
    authority: String,
) -> anyhow::Result<()> {
    // 1. Read H1 request from h1_side
    let (raw_head, body_prefix) = read_message_head(&mut h1_side).await?;

    // 2. Parse the H1 request
    let mut header_storage = [httparse::EMPTY_HEADER; MAX_HEADER_COUNT];
    let mut req = httparse::Request::new(&mut header_storage);
    let _ = req.parse(&raw_head).map_err(|e| {
        let preview = String::from_utf8_lossy(&raw_head[..raw_head.len().min(200)]);
        anyhow::anyhow!("H1 parse failed: {} - raw preview: {:?}", e, preview)
    })?;

    let method = req.method.unwrap_or("GET");
    let raw_path = req.path.unwrap_or("/");

    // RFC 9113: :path pseudo-header MUST be in origin-form (path + query) for most H2 servers.
    // If client sent an absolute-form URI (common in proxying), we MUST sanitize it.
    let path = if let Some(pos) = raw_path.find("://") {
        let after_scheme = &raw_path[pos + 3..];
        if let Some(slash_pos) = after_scheme.find('/') {
            &after_scheme[slash_pos..]
        } else {
            "/"
        }
    } else {
        raw_path
    };

    // 3. Collect headers into a Vec to preserve duplicates (e.g. cookies)
    let mut headers_list: Vec<(String, String)> = Vec::new();
    let mut is_chunked = false;
    let mut content_length: Option<usize> = None;
    let mut host_at_bridge = String::new();

    for h in req.headers.iter() {
        let name = h.name.to_lowercase();
        let value = String::from_utf8_lossy(h.value).to_string();

        // 3a. Strip connection-specific headers (RFC 9113)
        if name == "connection"
            || name == "keep-alive"
            || name == "proxy-connection"
            || name == "upgrade"
        {
            continue;
        }

        // 3b. Strip Expect header to prevent proxy deadlocks with 100-continue responses
        if name == "expect" {
            continue;
        }

        if name == "transfer-encoding" {
            if h.value
                .to_ascii_lowercase()
                .windows(7)
                .any(|w| w == b"chunked")
            {
                is_chunked = true;
            }
            continue;
        }

        if name == "content-length" {
            content_length = value.parse().ok();
            // Do not push yet; we'll decide based on chunking later
            continue;
        }

        // 3c. RFC 9113: TE header must only contain "trailers"
        if name == "te" {
            if value.to_lowercase().contains("trailers") {
                headers_list.push((name, "trailers".to_string()));
            }
            continue;
        }

        if name == "host" {
            host_at_bridge = value.clone();
            // Do not push Host; H2 uses :authority pseudo-header
            continue;
        }

        headers_list.push((name, value));
    }

    // Determine authority. RFC 9113: :authority SHOULD omit default ports (443/80).
    let authority_for_uri = if authority.is_empty() {
        host_at_bridge
    } else {
        authority.clone()
    };

    let clean_authority = if authority_for_uri.ends_with(":443") {
        &authority_for_uri[..authority_for_uri.len() - 4]
    } else if authority_for_uri.ends_with(":80") {
        &authority_for_uri[..authority_for_uri.len() - 3]
    } else {
        &authority_for_uri
    };

    if clean_authority.is_empty() {
        return Err(anyhow::anyhow!(
            "No authority available for H2 bridge request"
        ));
    }

    // Only send content-length if NOT chunked. Forwarding both is a protocol violation.
    if !is_chunked {
        if let Some(len) = content_length {
            headers_list.push(("content-length".to_string(), len.to_string()));
        }
    }

    let uri_str = format!("https://{}{path}", clean_authority);
    let uri: http::Uri = uri_str
        .parse()
        .map_err(|e| anyhow::anyhow!("invalid URI '{}': {}", uri_str, e))?;

    tracing::debug!(
        "H2 bridge request: {} {} (:authority: {})",
        method,
        path,
        clean_authority
    );
    tracing::trace!("  Pseudo-header :path: {}", path);
    tracing::trace!("  Pseudo-header :authority: {}", clean_authority);
    for (name, val) in &headers_list {
        tracing::trace!("  Header: {}: {}", name, val);
    }

    let mut builder = http::Request::builder().method(method).uri(uri);
    for (name, value) in headers_list {
        if let Ok(header_name) = http::header::HeaderName::from_bytes(name.as_bytes()) {
            builder = builder.header(header_name, value);
        }
    }

    // 3. Send H2 request (body via channel)
    let (mut req_tx, req_body) = Channel::new(64 * 1024);
    let req = builder.body(req_body.boxed())?;
    let response_fut = h2_client.send_request(req);

    let (h1_reader, mut h1_writer) = tokio::io::split(h1_side);

    // 4. Forward Request Body: H1 -> H2
    let timing_for_send = timing_handle.clone();
    let req_body_handle = tokio::spawn(async move {
        let mut combined_reader: Pin<Box<dyn AsyncRead + Send>> = if !body_prefix.is_empty() {
            Box::pin(tokio::io::AsyncReadExt::chain(
                std::io::Cursor::new(body_prefix),
                h1_reader,
            ))
        } else {
            Box::pin(h1_reader)
        };

        if is_chunked {
            loop {
                let mut line = Vec::new();
                let mut b = [0u8; 1];
                loop {
                    combined_reader.read_exact(&mut b).await?;
                    line.push(b[0]);
                    if line.ends_with(b"\r\n") {
                        break;
                    }
                }
                let line_str = std::str::from_utf8(&line)?.trim();
                let chunk_size = usize::from_str_radix(line_str, 16)?;
                if chunk_size == 0 {
                    let mut b = [0u8; 2];
                    combined_reader.read_exact(&mut b).await?;
                    break;
                }
                let mut data = vec![0u8; chunk_size];
                combined_reader.read_exact(&mut data).await?;
                let mut b = [0u8; 2];
                combined_reader.read_exact(&mut b).await?;
                if req_tx.send_data(Bytes::from(data)).await.is_err() {
                    break;
                }
            }
        } else if let Some(len) = content_length {
            let mut remaining = len;
            let mut buf = [0u8; 16384];
            while remaining > 0 {
                let to_read = remaining.min(buf.len());
                let n = combined_reader.read(&mut buf[..to_read]).await?;
                if n == 0 {
                    break;
                }
                if req_tx
                    .send_data(Bytes::copy_from_slice(&buf[..n]))
                    .await
                    .is_err()
                {
                    break;
                }
                remaining -= n;
            }
        }
        if let Some(handle) = timing_for_send {
            handle.record_send();
        }
        Ok::<(), anyhow::Error>(())
    });

    // 5. Forward Response Body: H2 -> H1
    let timing_for_resp = timing_handle;
    let res_handle = tokio::spawn(async move {
        let res = response_fut.await.map_err(|e| {
            tracing::error!("H2 upstream request failed: {}", e);
            e
        })?;
        tracing::debug!(
            "H2 upstream response: status={}, version={:?}",
            res.status(),
            res.version()
        );
        if let Some(handle) = &timing_for_resp {
            handle.record_waiting();
        }

        // Write H1 response head (preserve reason if available)
        let reason = res.status().canonical_reason().unwrap_or("OK");
        h1_writer
            .write_all(format!("HTTP/1.1 {} {}\r\n", res.status().as_u16(), reason).as_bytes())
            .await?;

        // Track content length if present to avoid relying on EOF
        let mut content_length: Option<usize> = None;
        for (name, value) in res.headers() {
            let name_lower = name.as_str().to_ascii_lowercase();
            if name_lower == "transfer-encoding"
                || name_lower == "connection"
                || name_lower == "keep-alive"
                || name_lower == "proxy-connection"
                || name_lower == "upgrade"
            {
                continue;
            }
            if name_lower == "content-length" {
                content_length = std::str::from_utf8(value.as_bytes())
                    .ok()
                    .and_then(|s| s.parse::<usize>().ok());
            }
            h1_writer
                .write_all(format!("{}: ", name).as_bytes())
                .await?;
            h1_writer.write_all(value.as_bytes()).await?;
            h1_writer.write_all(b"\r\n").await?;
        }
        h1_writer.write_all(b"\r\n").await?;
        tracing::debug!("H2 bridge: wrote H1 response headers for {}", authority);

        let mut res_body = res.into_body();
        let mut sent_bytes: usize = 0;
        while let Some(chunk) = res_body.frame().await {
            let frame = chunk?;
            if let Some(data) = frame.data_ref() {
                sent_bytes = sent_bytes.saturating_add(data.len());
                h1_writer.write_all(data).await?;
            }
        }

        // If no content-length was set, rely on connection close. If set and short, connection stays open.
        if let Some(len) = content_length {
            if sent_bytes < len {
                // If upstream reported a length but sent fewer bytes, close to signal EOF.
                h1_writer.shutdown().await?;
            }
        } else {
            // No length; close to signal EOF to H1 client.
            h1_writer.shutdown().await?;
        }

        h1_writer.shutdown().await?;
        if let Some(handle) = &timing_for_resp {
            handle.record_download();
        }
        Ok::<(), anyhow::Error>(())
    });

    let (r1, r2) = tokio::join!(req_body_handle, res_handle);
    r1??;
    r2??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::proxy_api::{reset_test_transaction_observer, set_test_transaction_observer};
    use crate::models::breakpoint::BreakpointRuleInput;
    use crate::models::TransactionFilter;
    use serial_test::serial;
    use std::net::TcpListener as StdTcpListener;
    use std::time::{Duration, Instant as StdInstant};
    use tokio::io::{duplex, AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::sync::mpsc;

    fn available_port() -> u16 {
        StdTcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port()
    }

    fn build_test_request(
        host: &str,
        method: HttpMethod,
        path: &str,
        headers: Vec<(String, String)>,
    ) -> ParsedRequest {
        let header_map = headers.iter().cloned().collect::<HashMap<String, String>>();
        let body_kind = header_value(&header_map, "content-length")
            .and_then(|v| v.parse::<usize>().ok())
            .map(|len| RequestBodyKind::ContentLength { length: len })
            .unwrap_or(RequestBodyKind::None);

        ParsedRequest {
            method,
            scheme: "http".into(),
            host: host.into(),
            port: 80,
            path: path.into(),
            version: "HTTP/1.1".into(),
            request_headers: header_map,
            header_list: headers,
            body_kind,
            buffered_body: Vec::new(),
            stream_id: None,
            timing_handle: None,
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "Requires opening local TCP ports"]
    #[serial]
    async fn http_request_persisted_via_handle_connection() {
        let storage_dir = tempfile::tempdir().unwrap();
        let storage_path = storage_dir.path().to_string_lossy().to_string();
        let _ = storage::reset_store_for_tests(&storage_path);

        let upstream_listener = TcpListener::bind(("127.0.0.1", available_port()))
            .await
            .unwrap();
        let upstream_addr = upstream_listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut socket, _)) = upstream_listener.accept().await {
                let mut buf = vec![0u8; 1024];
                let _ = socket.read(&mut buf).await;
                let response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                let _ = socket.write_all(response).await;
            }
        });

        let proxy_listener = TcpListener::bind(("127.0.0.1", available_port()))
            .await
            .unwrap();
        let proxy_addr = proxy_listener.local_addr().unwrap();
        let proxy_task = tokio::spawn(async move {
            if let Ok((socket, _)) = proxy_listener.accept().await {
                handle_connection(socket, None, None)
                    .await
                    .expect("handle connection");
            }
        });

        let mut client = tokio::net::TcpStream::connect(proxy_addr).await.unwrap();
        let request = format!(
            "GET http://127.0.0.1:{}/test HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n",
            upstream_addr.port()
        );
        client.write_all(request.as_bytes()).await.unwrap();
        let mut resp_buf = vec![0u8; 128];
        let _ = client.read(&mut resp_buf).await.unwrap();
        proxy_task.await.unwrap();

        let filter = TransactionFilter::default();
        let result = storage::query_transactions(&filter, 0, 10)
            .await
            .expect("query");
        assert_eq!(result.items.len(), 1);
        let tx = &result.items[0];
        assert_eq!(tx.host, "127.0.0.1");
        assert_eq!(tx.path, "/test");
        assert_eq!(tx.status_code, Some(200));
        assert_eq!(
            tx.request_headers.get("Host").map(|s| s.as_str()),
            Some("127.0.0.1")
        );
    }

    #[tokio::test]
    #[serial]
    async fn process_request_persists_transaction_with_mock_upstream() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).unwrap();
        reset_test_transaction_observer();

        let (mut proxy_client, mut client_peer) = duplex(4096);
        let (mock_stream, mut upstream_peer) = duplex(4096);

        let holder = Arc::new(Mutex::new(Some(mock_stream)));
        set_test_upstream_connector({
            let holder = holder.clone();
            move |_req| {
                let mut guard = holder.lock().unwrap();
                let stream = guard.take().expect("connector already used");
                async move {
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: None,
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(stream), timing))
                }
            }
        });

        let upstream_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 512];
            // Add timeout to prevent indefinite hang
            let read_result =
                tokio::time::timeout(Duration::from_secs(5), upstream_peer.read(&mut buf)).await;
            if let Ok(Ok(n)) = read_result {
                let forwarded = String::from_utf8_lossy(&buf[..n]);
                assert!(forwarded.contains("GET /mock"));
                upstream_peer
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nPONG")
                    .await
                    .unwrap();
            }
        });

        let parsed_request = build_test_request(
            "example.com",
            HttpMethod::Get,
            "/mock",
            vec![
                ("Host".to_string(), "example.com".to_string()),
                ("Content-Length".to_string(), "0".to_string()),
            ],
        );

        process_request(
            &mut proxy_client,
            parsed_request,
            Instant::now(),
            None,
            false,
        )
        .await
        .expect("process request should succeed");

        let mut response_buf = vec![0u8; 512];
        let n = client_peer.read(&mut response_buf).await.unwrap();
        let response = String::from_utf8_lossy(&response_buf[..n]);
        assert!(response.contains("200 OK"));
        assert!(response.contains("PONG"));

        let _ = tokio::time::timeout(Duration::from_secs(5), upstream_task).await;
        reset_test_upstream_connector();

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 10)
            .await
            .expect("query transactions");
        assert_eq!(result.items.len(), 1);
        let tx = &result.items[0];
        assert_eq!(tx.path, "/mock");
        assert_eq!(tx.status_code, Some(200));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn bridge_h1_to_hyper_upstream_roundtrip() {
        // In-memory HTTP/2 server (h2 crate) that responds "pong"
        let (client_io, server_io) = duplex(64 * 1024);

        // Hyper client handshake (upstream side)
        let (send_request, conn) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(client_io))
                .await
                .expect("client handshake");
        tokio::spawn(async move {
            let _ = conn.await;
        });

        // h2 server responding over the other side
        tokio::spawn(async move {
            let mut server = h2::server::handshake(server_io).await.expect("server hs");
            while let Some(res) = server.accept().await {
                let (req, mut respond) = res.expect("accept");
                assert_eq!(req.method(), http::Method::GET);
                let resp = http::Response::builder()
                    .status(200)
                    .header("content-length", "4")
                    .body(())
                    .unwrap();
                let mut send = respond.send_response(resp, false).expect("send response");
                send.send_data(Bytes::from_static(b"pong"), true)
                    .expect("send data");
            }
        });

        // Prepare H1 side (client<->bridge)
        let (mut h1_client, h1_server) = duplex(64 * 1024);
        let timing_handle = Arc::new(TimingHandle::new(Instant::now()));
        let write_task = tokio::spawn(async move {
            let req = b"GET /hello HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n";
            h1_client.write_all(req).await.unwrap();
            let mut buf = vec![0u8; 1024];
            let n = h1_client.read(&mut buf).await.unwrap();
            String::from_utf8_lossy(&buf[..n]).to_string()
        });

        bridge_h1_to_hyper_upstream(
            h1_server,
            send_request,
            Some(timing_handle.clone()),
            "example.com".to_string(),
        )
        .await
        .expect("bridge");

        let response = write_task.await.unwrap();
        assert!(response.contains("200 OK"));
        assert!(response.contains("pong"));

        let (send, wait, download) = timing_handle.snapshot();
        assert!(send.is_some(), "request_send_ms not recorded");
        assert!(wait.is_some(), "waiting_ms not recorded");
        assert!(download.is_some(), "content_download_ms not recorded");
    }

    #[tokio::test]
    #[serial]
    async fn mark_h2_failure_removes_and_blocklists() {
        set_h2_test_enabled(true);
        UPSTREAM_POOL.purge_all();
        H2_BLOCKLIST.clear();

        // Seed pool with dummy entry
        let (client_io, server_io) = duplex(1024);
        let (h2_client, connection) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(client_io))
                .await
                .expect("handshake");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        drop(server_io);

        UPSTREAM_POOL.set_h2_client("example.com".into(), 443, h2_client);

        mark_h2_failure("example.com", 443);

        let pooled = UPSTREAM_POOL.get_h2_client("example.com", 443).await;
        assert!(pooled.is_none(), "pooled H2 client should be evicted");
        assert!(is_h2_blocklisted("example.com", 443));

        UPSTREAM_POOL.purge_all();
        H2_BLOCKLIST.clear();
        set_h2_test_enabled(false);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[serial]
    async fn h2_bridge_error_triggers_blocklist_and_h1_fallback() {
        // Clear global state
        UPSTREAM_POOL.purge_all();
        H2_BLOCKLIST.clear();
        reset_test_upstream_connector();

        // Prepare a failing H2 client: server side immediately closes to force bridge error.
        let (client_io, server_io) = duplex(64 * 1024);
        let (h2_client, h2_conn) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(client_io))
                .await
                .expect("handshake");
        tokio::spawn(async move {
            let _ = h2_conn.await;
        });
        drop(server_io);

        // Seed pool with the failing H2 sender
        UPSTREAM_POOL.set_h2_client("example.com".into(), 443, h2_client);

        let parsed_request = ParsedRequest {
            method: HttpMethod::Get,
            scheme: "https".into(),
            host: "example.com".into(),
            port: 443,
            path: "/".to_string(),
            version: "HTTP/1.1".into(),
            request_headers: HashMap::new(),
            header_list: vec![],
            body_kind: RequestBodyKind::None,
            buffered_body: vec![],
            stream_id: None,
            timing_handle: None,
        };

        // Provide a test connector that returns a mock stream for H1 fallback after blocklist
        set_test_upstream_connector({
            move |_req| {
                let (mock_stream, _peer) = duplex(4096);
                let timing = ConnectionTiming {
                    dns_ms: 0,
                    tcp_ms: 0,
                    tls_ms: None,
                    server_ip: None,
                    tls_version: Some("HTTP/1.1 forced".into()),
                    tls_cipher: None,
                };
                async move { Ok((UpstreamStream::Mock(mock_stream), timing)) }
            }
        });

        // First call will try pooled H2; simulate failure and mark blocklist
        let (_stream1, _t1) = connect_upstream(&parsed_request, None).await.unwrap();
        mark_h2_failure("example.com", 443);

        // Now blocklisted; next call should skip pool and use test connector (Mock)
        let (stream2, timing2) = connect_upstream(&parsed_request, None).await.unwrap();
        match stream2 {
            UpstreamStream::Mock(_) => {}
            other => panic!("expected Mock after blocklist fallback, got {:?}", other),
        }
        assert_eq!(
            timing2.tls_version.as_deref(),
            Some("HTTP/1.1 forced"),
            "fallback timing should reflect forced h1 path"
        );
        assert!(is_h2_blocklisted("example.com", 443));

        // Clean up
        UPSTREAM_POOL.purge_all();
        H2_BLOCKLIST.clear();
        reset_test_upstream_connector();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[serial]
    async fn timing_applied_on_upstream_failure() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).unwrap();
        reset_test_transaction_observer();

        let (mut proxy_client, mut client_peer) = duplex(4096);
        let (mock_stream, mut upstream_peer) = duplex(4096);

        // Connector returns a mock upstream that will read the request then close (no response head)
        let holder = Arc::new(Mutex::new(Some(mock_stream)));
        set_test_upstream_connector({
            let holder = holder.clone();
            move |_req| {
                let mut guard = holder.lock().unwrap();
                let stream = guard.take().expect("connector already used");
                async move {
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: None,
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(stream), timing))
                }
            }
        });

        let captured: Arc<Mutex<Vec<HttpTransaction>>> = Arc::new(Mutex::new(Vec::new()));
        let captured_clone = captured.clone();
        set_test_transaction_observer(move |tx| {
            captured_clone.lock().unwrap().push(tx.clone());
        });

        // Upstream task: read request then drop without responding
        let upstream_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 512];
            // Add timeout to prevent indefinite hang
            let read_result =
                tokio::time::timeout(Duration::from_secs(5), upstream_peer.read(&mut buf)).await;
            if read_result.is_ok() {
                // Give the client a moment to finish writing, then close without responding
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            drop(upstream_peer);
        });

        let parsed_request = build_test_request(
            "example.com",
            HttpMethod::Get,
            "/fail",
            vec![
                ("Host".to_string(), "example.com".to_string()),
                ("Content-Length".to_string(), "0".to_string()),
            ],
        );

        let _ = process_request(
            &mut proxy_client,
            parsed_request,
            Instant::now(),
            None,
            false,
        )
        .await;

        // Consume the 502 from proxy to avoid broken pipe
        let mut response_buf = vec![0u8; 256];
        let _ = client_peer.read(&mut response_buf).await.unwrap();

        let _ = tokio::time::timeout(Duration::from_secs(5), upstream_task).await;
        reset_test_upstream_connector();

        // Inspect captured transactions
        let tx_opt = captured
            .lock()
            .unwrap()
            .iter()
            .find(|tx| tx.state == TransactionState::Failed)
            .cloned();
        reset_test_transaction_observer();

        let tx = tx_opt.expect("failed transaction missing");
        assert!(
            tx.status_code.is_some(),
            "failed transaction should have status"
        );
        assert!(
            tx.timing.request_send_ms.is_some(),
            "request_send_ms should be recorded even on failure"
        );
    }

    #[tokio::test]
    #[serial]
    async fn h2_pool_eviction_on_ttl() {
        let (client_io, server_io) = duplex(1024);
        let (sender, connection) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(client_io))
                .await
                .expect("handshake");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let stale = StdInstant::now() - (H2_POOL_TTL + Duration::from_secs(1));
        UPSTREAM_POOL.set_h2_client_with_timestamp("example.com".into(), 443, sender, stale);
        let fetched = UPSTREAM_POOL.get_h2_client("example.com", 443).await;
        assert!(fetched.is_none());

        drop(server_io); // cleanup
    }

    #[tokio::test]
    #[serial]
    async fn connect_upstream_reuses_h2_pool_and_marks_timing() {
        set_h2_test_enabled(true);
        UPSTREAM_POOL.purge_all();
        H2_BLOCKLIST.clear();

        let (client_io, server_io) = duplex(1024);
        let (sender, connection) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(client_io))
                .await
                .expect("handshake");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        // Minimal server to satisfy response
        tokio::spawn(async move {
            let mut server = h2::server::handshake(server_io).await.expect("server hs");
            while let Some(res) = server.accept().await {
                let (_req, mut respond) = res.expect("accept");
                let resp = http::Response::builder()
                    .status(200)
                    .header("content-length", "0")
                    .body(())
                    .unwrap();
                let mut send = respond.send_response(resp, false).expect("send");
                let _ = send.send_data(Bytes::new(), true);
            }
        });

        UPSTREAM_POOL.set_h2_client("example.com".into(), 443, sender);

        let parsed_request = ParsedRequest {
            method: HttpMethod::Get,
            scheme: "https".into(),
            host: "example.com".into(),
            port: 443,
            path: "/".into(),
            version: "HTTP/2".into(),
            request_headers: HashMap::new(),
            header_list: vec![],
            body_kind: RequestBodyKind::None,
            buffered_body: vec![],
            stream_id: None,
            timing_handle: None,
        };

        let (stream, timing) = connect_upstream(&parsed_request, None).await.unwrap();
        match stream {
            UpstreamStream::Bridge(_) => {}
            _ => panic!("expected Bridge from pooled H2"),
        }
        assert_eq!(timing.tls_ms, None);
        assert_eq!(timing.tls_version.as_deref(), Some("H2 (reused)"));

        UPSTREAM_POOL.purge_all();
        set_h2_test_enabled(false);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[serial]
    async fn handle_connection_persists_transaction_with_mock_connector() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).unwrap();

        let (mock_stream, mut upstream_peer) = duplex(4096);
        let holder = Arc::new(Mutex::new(Some(mock_stream)));
        set_test_upstream_connector({
            let holder = holder.clone();
            move |_req| {
                let mut guard = holder.lock().unwrap();
                let stream = guard.take().expect("connector already used");
                async move {
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: None,
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(stream), timing))
                }
            }
        });

        let upstream_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 512];
            // Add timeout to prevent indefinite hang
            let read_result =
                tokio::time::timeout(Duration::from_secs(5), upstream_peer.read(&mut buf)).await;
            if let Ok(Ok(n)) = read_result {
                let forwarded = String::from_utf8_lossy(&buf[..n]);
                assert!(forwarded.contains("GET /handle"));
                upstream_peer
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                    .await
                    .unwrap();
            }
        });

        let (mut client_stream, mut server_stream) = duplex(4096);
        let server_task = tokio::spawn(async move {
            handle_connection_with_stream(&mut server_stream, None)
                .await
                .expect("handle connection");
        });

        client_stream
            .write_all(
                b"GET http://example.com/handle HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n",
            )
            .await
            .unwrap();

        let mut response_buf = vec![0u8; 256];
        let n = client_stream.read(&mut response_buf).await.unwrap();
        let response = String::from_utf8_lossy(&response_buf[..n]);
        assert!(response.contains("200 OK"));
        assert!(response.contains("OK"));

        // Explicitly close client stream to signal EOF to server
        drop(client_stream);

        let _ = tokio::time::timeout(Duration::from_secs(5), server_task).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), upstream_task).await;
        reset_test_upstream_connector();

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 10)
            .await
            .expect("query transactions");
        assert_eq!(result.items.len(), 1);
        let tx = &result.items[0];
        assert_eq!(tx.host, "example.com");
        assert_eq!(tx.path, "/handle");
        assert_eq!(tx.status_code, Some(200));
    }

    #[tokio::test]
    async fn decode_chunked_body_decodes_payload_bytes() {
        let (mut reader, mut writer) = duplex(256);
        tokio::spawn(async move {
            writer
                .write_all(b"4\r\nRust\r\n6\r\nProxy!\r\n0\r\n\r\n")
                .await
                .unwrap();
        });

        let (captured, total) = decode_chunked_body(Vec::new(), &mut reader)
            .await
            .expect("chunked body should decode");

        assert_eq!(captured, b"RustProxy!");
        assert_eq!(total, 10);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[serial]
    async fn breakpoint_resume_applies_request_edits() {
        // Reset all global state first
        reset_test_transaction_observer();
        reset_test_upstream_connector();
        breakpoints::reset_for_tests();

        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).unwrap();

        breakpoints::add_breakpoint_rule(BreakpointRuleInput {
            enabled: true,
            method: Some(HttpMethod::Get),
            host_contains: Some("example.com".into()),
            path_contains: Some("break".into()),
        });

        let (mock_stream, mut upstream_peer) = duplex(4096);
        let holder = Arc::new(Mutex::new(Some(mock_stream)));
        set_test_upstream_connector({
            let holder = holder.clone();
            move |_req| {
                let mut guard = holder.lock().unwrap();
                let stream = guard.take().expect("connector already used");
                async move {
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: None,
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(stream), timing))
                }
            }
        });

        let upstream_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 512];
            // Add timeout to prevent indefinite hang
            let read_result =
                tokio::time::timeout(Duration::from_secs(5), upstream_peer.read(&mut buf)).await;
            if let Ok(Ok(n)) = read_result {
                let forwarded = String::from_utf8_lossy(&buf[..n]);
                assert!(forwarded.contains("GET /edited"));
                upstream_peer
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                    .await
                    .unwrap();
            }
        });

        let (tx_sender, mut tx_rx) = mpsc::unbounded_channel::<(String, TransactionState)>();
        set_test_transaction_observer(move |tx| {
            let _ = tx_sender.send((tx.id.clone(), tx.state));
        });

        let resume_task = tokio::spawn(async move {
            // Add timeout to the entire loop
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                while let Some((id, state)) = tx_rx.recv().await {
                    if state == TransactionState::Breakpointed {
                        // Retry with backoff - the breakpoint may not be registered yet
                        for attempt in 0..10 {
                            if attempt > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                            }
                            let result = breakpoints::resume_breakpoint(
                                &id,
                                RequestEdit {
                                    path: Some("/edited".into()),
                                    ..Default::default()
                                },
                            );
                            if result.is_ok() {
                                break;
                            }
                        }
                        break;
                    }
                }
            })
            .await;
        });

        let (mut proxy_client, mut client_peer) = duplex(4096);
        let parsed_request = build_test_request(
            "example.com",
            HttpMethod::Get,
            "/break",
            vec![
                ("Host".to_string(), "example.com".to_string()),
                ("Content-Length".to_string(), "0".to_string()),
            ],
        );

        process_request(
            &mut proxy_client,
            parsed_request,
            Instant::now(),
            None,
            false,
        )
        .await
        .expect("process request succeeds");

        let mut response_buf = vec![0u8; 128];
        let n = client_peer.read(&mut response_buf).await.unwrap();
        let response = String::from_utf8_lossy(&response_buf[..n]);
        assert!(response.contains("200 OK"));

        let _ = tokio::time::timeout(Duration::from_secs(5), resume_task).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), upstream_task).await;

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 10)
            .await
            .expect("query transactions");
        assert_eq!(result.items.len(), 1);
        let tx = &result.items[0];
        assert_eq!(tx.path, "/edited");

        reset_test_transaction_observer();
        reset_test_upstream_connector();
        breakpoints::reset_for_tests();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[serial]
    async fn breakpoint_abort_returns_409_and_failed_state() {
        // Reset all global state first
        reset_test_transaction_observer();
        reset_test_upstream_connector();
        breakpoints::reset_for_tests();

        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).unwrap();

        breakpoints::add_breakpoint_rule(BreakpointRuleInput {
            enabled: true,
            method: Some(HttpMethod::Get),
            host_contains: Some("example.com".into()),
            path_contains: Some("abort".into()),
        });

        let (state_sender, mut state_rx) = mpsc::unbounded_channel::<(String, TransactionState)>();
        set_test_transaction_observer(move |tx| {
            let _ = state_sender.send((tx.id.clone(), tx.state));
        });

        let abort_task = tokio::spawn(async move {
            let mut aborted_id = None;
            // Add timeout to the entire loop
            let _ = tokio::time::timeout(Duration::from_secs(5), async {
                let mut abort_sent = false;
                while let Some((id, state)) = state_rx.recv().await {
                    if state == TransactionState::Breakpointed && !abort_sent {
                        // Retry with backoff - the breakpoint may not be registered yet
                        for attempt in 0..10 {
                            if attempt > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                            }
                            if breakpoints::abort_breakpoint(&id, "aborted in test".into()).is_ok()
                            {
                                abort_sent = true;
                                break;
                            }
                        }
                    }
                    if state == TransactionState::Failed {
                        aborted_id = Some(id);
                        break;
                    }
                }
            })
            .await;
            aborted_id
        });

        let (mut proxy_client, mut client_peer) = duplex(4096);
        let parsed_request = build_test_request(
            "example.com",
            HttpMethod::Get,
            "/abort",
            vec![
                ("Host".to_string(), "example.com".to_string()),
                ("Content-Length".to_string(), "0".to_string()),
            ],
        );

        process_request(
            &mut proxy_client,
            parsed_request,
            Instant::now(),
            None,
            false,
        )
        .await
        .expect("process request succeeds");

        let mut resp_buf = vec![0u8; 256];
        let n = client_peer.read(&mut resp_buf).await.unwrap();
        let response = String::from_utf8_lossy(&resp_buf[..n]);
        assert!(response.contains("409"));
        assert!(
            response.contains("Request aborted"),
            "expected abort message, got {}",
            response
        );

        let aborted_id = tokio::time::timeout(Duration::from_secs(5), abort_task)
            .await
            .ok()
            .and_then(|r| r.ok())
            .flatten();

        reset_test_transaction_observer();
        breakpoints::reset_for_tests();
        assert!(
            aborted_id.map(|id| !id.is_empty()).unwrap_or(false),
            "breakpoint abort returned final state"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn https_connect_interception_captures_transaction() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).expect("init store");

        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        let (mock_stream, mut upstream_peer) = duplex(4096);
        set_test_upstream_connector({
            let stream = Arc::new(Mutex::new(Some(mock_stream)));
            move |_req| {
                let holder = stream.clone();
                async move {
                    let stream = holder
                        .lock()
                        .unwrap()
                        .take()
                        .expect("connector already used");
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: Some(1),
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(stream), timing))
                }
            }
        });

        let upstream_task = tokio::spawn(async move {
            let mut buf = vec![0u8; 512];
            let n = upstream_peer.read(&mut buf).await.unwrap();
            let forwarded = String::from_utf8_lossy(&buf[..n]);
            assert!(forwarded.contains("GET /secure"));
            upstream_peer
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nSECURE!")
                .await
                .unwrap();
        });

        let (mut client_side, server_side) = duplex(4096);
        let cert_manager_clone = cert_manager.clone();
        let tls_config_clone = tls_client_config.clone();
        let server_task = tokio::spawn(async move {
            intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager_clone,
                tls_config_clone,
            )
            .await
            .expect("intercept tls");
        });

        let mut resp = vec![0u8; 128];
        let n = client_side.read(&mut resp).await.unwrap();
        let head = String::from_utf8_lossy(&resp[..n]);
        assert!(
            head.contains("200 Connection Established"),
            "CONNECT response ok: {}",
            head
        );

        let mut roots = RootCertStore::empty();
        roots
            .add(cert_manager.test_ca_der())
            .expect("add root cert");
        let client_cfg = Arc::new(
            ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth(),
        );
        let connector = TlsConnector::from(client_cfg);
        let server_name = ServerName::try_from("example.com").unwrap();
        let mut tls_client = connector.connect(server_name, client_side).await.unwrap();

        tls_client
            .write_all(b"GET /secure HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();

        let mut tls_buf = vec![0u8; 512];
        let n = tls_client.read(&mut tls_buf).await.unwrap();
        let body = String::from_utf8_lossy(&tls_buf[..n]);
        assert!(body.contains("SECURE!"));

        drop(tls_client);
        server_task.await.unwrap();
        upstream_task.await.unwrap();
        reset_test_upstream_connector();

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 50)
            .await
            .expect("query transactions");
        assert!(
            result
                .items
                .iter()
                .any(|tx| tx.host == "example.com" && tx.path == "/secure" && tx.scheme == "https"),
            "stored https transaction present"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn https_keep_alive_handles_multiple_requests() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).expect("init store");

        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        set_test_upstream_connector({
            move |req| {
                let path = req.path.clone();
                async move {
                    let (mut upstream_side, server_side) = duplex(4096);
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 1024];
                        let _ = upstream_side.read(&mut buf).await.unwrap();
                        let (body, connection_header) = if path == "/first" {
                            (b"FIRST".to_vec(), "")
                        } else {
                            (b"SECOND".to_vec(), "Connection: close\r\n")
                        };
                        upstream_side
                            .write_all(
                                format!(
                                    "HTTP/1.1 200 OK\r\n{}Content-Length: {}\r\n\r\n",
                                    connection_header,
                                    body.len()
                                )
                                .as_bytes(),
                            )
                            .await
                            .unwrap();
                        upstream_side.write_all(&body).await.unwrap();
                    });
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: Some(1),
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(server_side), timing))
                }
            }
        });

        let (mut client_side, server_side) = duplex(4096);
        let cert_manager_clone = cert_manager.clone();
        let tls_config_clone = tls_client_config.clone();
        let server_task = tokio::spawn(async move {
            intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager_clone,
                tls_config_clone,
            )
            .await
            .expect("intercept tls");
        });

        let mut resp = vec![0u8; 128];
        let n = client_side.read(&mut resp).await.unwrap();
        let head = String::from_utf8_lossy(&resp[..n]);
        assert!(head.contains("200 Connection Established"));

        let mut roots = RootCertStore::empty();
        roots
            .add(cert_manager.test_ca_der())
            .expect("add root cert");
        let client_cfg = Arc::new(
            ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth(),
        );
        let connector = TlsConnector::from(client_cfg);
        let server_name = ServerName::try_from("example.com").unwrap();
        let mut tls_client = connector.connect(server_name, client_side).await.unwrap();

        tls_client
            .write_all(
                b"GET /first HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n",
            )
            .await
            .unwrap();
        let mut tls_buf = vec![0u8; 256];
        let n = tls_client.read(&mut tls_buf).await.unwrap();
        let first_resp = String::from_utf8_lossy(&tls_buf[..n]);
        assert!(first_resp.contains("FIRST"));

        tls_client
            .write_all(
                b"GET /second HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
            )
            .await
            .unwrap();
        let n = tls_client.read(&mut tls_buf).await.unwrap();
        let second_resp = String::from_utf8_lossy(&tls_buf[..n]);
        assert!(second_resp.contains("SECOND"));

        tls_client.shutdown().await.unwrap();
        server_task.await.unwrap();
        reset_test_upstream_connector();

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 50)
            .await
            .expect("query transactions");
        assert!(
            result
                .items
                .iter()
                .any(|tx| tx.path == "/first" && !tx.connection_reused),
            "first HTTPS request recorded",
        );
        assert!(
            result
                .items
                .iter()
                .any(|tx| tx.path == "/second" && tx.connection_reused),
            "second HTTPS request recorded with reuse flag",
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn test_h2_to_h1_bridge() {
        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).expect("init store");

        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        // Mock upstream: It expects H1.1 because of the bridge
        set_test_upstream_connector({
            move |req| {
                let path = req.path.clone();
                async move {
                    let (mut upstream_side, server_side) = duplex(4096);
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 1024];
                        // Add timeout to prevent indefinite hang
                        let read_result = tokio::time::timeout(
                            Duration::from_secs(5),
                            upstream_side.read(&mut buf),
                        )
                        .await;
                        if let Ok(Ok(_n)) = read_result {
                            let body = format!("H1 Response for {}", path);
                            let _ = upstream_side
                                .write_all(
                                    format!(
                                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                                        body.len(),
                                        body
                                    )
                                    .as_bytes(),
                                )
                                .await;
                        }
                    });
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: Some(1),
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(server_side), timing))
                }
            }
        });

        let (client_side, server_side) = duplex(65536);

        // Server task
        let server_task = tokio::spawn(async move {
            intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager,
                tls_client_config,
            )
            .await
            .expect("intercept tls");
        });

        let mut client_side = client_side;
        // 1. Read CONNECT response
        let mut resp = vec![0u8; 128];
        let n = client_side.read(&mut resp).await.unwrap();
        assert!(String::from_utf8_lossy(&resp[..n]).contains("200 Connection Established"));

        // 2. Setup H2 client
        let mut roots = RootCertStore::empty();
        let cm = CertManager::new(cert_dir.path().to_str().unwrap()).unwrap();
        roots.add(cm.test_ca_der()).unwrap();

        let mut client_cfg = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        client_cfg.alpn_protocols = vec![b"h2".to_vec()]; // FORCE H2
        let connector = TlsConnector::from(Arc::new(client_cfg));
        let server_name = ServerName::try_from("example.com").unwrap();
        let tls_client = connector.connect(server_name, client_side).await.unwrap();

        // Check if H2 was negotiated
        let (_, conn) = tls_client.get_ref();
        assert_eq!(conn.alpn_protocol(), Some(&b"h2"[..]));

        let (h2_client, h2_conn) = h2::client::handshake(tls_client).await.unwrap();
        tokio::spawn(async move {
            let _ = h2_conn.await;
        });

        // 3. Send concurrent requests with timeout
        let mut futures = Vec::new();
        for i in 1..=3 {
            let mut h2_client = h2_client.clone();
            let path = format!("/test-h2-{}", i);
            futures.push(tokio::spawn(async move {
                let request = Request::builder()
                    .method("GET")
                    .uri(format!("https://example.com{}", path))
                    .body(())
                    .unwrap();
                let (response, _) = h2_client.send_request(request, true).unwrap();
                // Add timeout to response await
                if let Ok(Ok(response)) =
                    tokio::time::timeout(Duration::from_secs(5), response).await
                {
                    assert_eq!(response.status(), 200);
                    let mut body = response.into_body();
                    if let Ok(Some(Ok(chunk))) =
                        tokio::time::timeout(Duration::from_secs(5), body.data()).await
                    {
                        assert!(String::from_utf8_lossy(&chunk).contains(&path));
                    }
                }
            }));
        }

        for f in futures {
            let _ = tokio::time::timeout(Duration::from_secs(10), f).await;
        }

        // Drop client to signal EOF
        drop(h2_client);

        let _ = tokio::time::timeout(Duration::from_secs(5), server_task).await;
        reset_test_upstream_connector();

        // 4. Verify capture
        let result = storage::query_transactions(&TransactionFilter::default(), 0, 50)
            .await
            .expect("query transactions");

        for i in 1..=3 {
            let path = format!("/test-h2-{}", i);
            assert!(
                result
                    .items
                    .iter()
                    .any(|tx| tx.path == path && tx.http_version == "HTTP/2"),
                "Request {} should be captured as HTTP/2",
                path
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn test_h2_bridge_post_body() {
        reset_test_upstream_connector();
        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        let post_body = b"hello from h2 client";

        set_test_upstream_connector(move |req| {
            let (client_side, mut server_side) = duplex(65536);
            let _path = req.path.clone();
            Box::pin(async move {
                // Mock H1.1 upstream
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 1024];
                    let n = server_side.read(&mut buf).await.unwrap();
                    let request_head = String::from_utf8_lossy(&buf[..n]);

                    // Verify that the bridge sent the body in H1.1 format
                    assert!(request_head.to_lowercase().contains("post"));

                    // Note: Since we sent content-length in test, the bridge uses ContentLength kind.
                    // If it were streaming, it would use chunked.
                    assert!(request_head.to_lowercase().contains("content-length: 20"));
                    assert!(request_head.contains("hello from h2 client"));

                    let response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                    server_side.write_all(response).await.unwrap();
                });
                let timing = ConnectionTiming {
                    dns_ms: 0,
                    tcp_ms: 0,
                    tls_ms: Some(0),
                    server_ip: None,
                    tls_version: None,
                    tls_cipher: None,
                };
                Ok((UpstreamStream::Mock(client_side), timing))
            })
        });

        let (client_side, server_side) = duplex(65536);
        tokio::spawn(async move {
            intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager,
                tls_client_config,
            )
            .await
            .unwrap();
        });

        let mut client_side = client_side;
        // Skip CONNECT response
        let mut resp = vec![0u8; 128];
        let _ = client_side.read(&mut resp).await.unwrap();

        let cm = CertManager::new(cert_dir.path().to_str().unwrap()).unwrap();
        let mut roots = RootCertStore::empty();
        roots.add(cm.test_ca_der()).unwrap();
        let mut client_cfg = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        client_cfg.alpn_protocols = vec![b"h2".to_vec()];
        let connector = TlsConnector::from(Arc::new(client_cfg));
        let tls_client = connector
            .connect(ServerName::try_from("example.com").unwrap(), client_side)
            .await
            .unwrap();

        let (mut h2_client, h2_conn) = h2::client::handshake(tls_client).await.unwrap();
        tokio::spawn(async move {
            h2_conn.await.unwrap();
        });

        let request = Request::builder()
            .method("POST")
            .uri("https://example.com/post")
            .header("content-length", post_body.len().to_string())
            .body(())
            .unwrap();

        // H2 client with explicit content-length
        let (response, mut send_stream) = h2_client.send_request(request, false).unwrap();
        send_stream
            .send_data(Bytes::from_static(post_body), true)
            .unwrap();

        let response = response.await.unwrap();
        assert_eq!(response.status(), 200);

        reset_test_upstream_connector();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn test_h2_bridge_streaming_post() {
        reset_test_upstream_connector();
        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        let post_body = b"streaming text";

        set_test_upstream_connector(move |_req| {
            let (client_side, mut server_side) = duplex(65536);
            Box::pin(async move {
                // Mock H1.1 upstream
                tokio::spawn(async move {
                    // Add timeout to the entire read loop
                    let _ = tokio::time::timeout(Duration::from_secs(5), async {
                        let mut full_request = Vec::new();
                        let mut buf = [0u8; 1024];
                        loop {
                            match server_side.read(&mut buf).await {
                                Ok(0) => break, // EOF
                                Ok(n) => {
                                    full_request.extend_from_slice(&buf[..n]);
                                    let s = String::from_utf8_lossy(&full_request);
                                    if s.contains("0\r\n\r\n") {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        let request_head = String::from_utf8_lossy(&full_request);

                        if request_head.to_lowercase().contains("post")
                            && request_head
                                .to_lowercase()
                                .contains("transfer-encoding: chunked")
                        {
                            let response = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
                            let _ = server_side.write_all(response).await;
                        }
                    })
                    .await;
                });
                let timing = ConnectionTiming {
                    dns_ms: 0,
                    tcp_ms: 0,
                    tls_ms: Some(0),
                    server_ip: None,
                    tls_version: None,
                    tls_cipher: None,
                };
                Ok((UpstreamStream::Mock(client_side), timing))
            })
        });

        let (client_side, server_side) = duplex(65536);
        let server_task = tokio::spawn(async move {
            let _ = intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager,
                tls_client_config,
            )
            .await;
        });

        let mut client_side = client_side;
        let mut resp = vec![0u8; 128];
        let _ = client_side.read(&mut resp).await.unwrap();

        let cm = CertManager::new(cert_dir.path().to_str().unwrap()).unwrap();
        let mut roots = RootCertStore::empty();
        roots.add(cm.test_ca_der()).unwrap();
        let mut client_cfg = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        client_cfg.alpn_protocols = vec![b"h2".to_vec()];
        let connector = TlsConnector::from(Arc::new(client_cfg));
        let tls_client = connector
            .connect(ServerName::try_from("example.com").unwrap(), client_side)
            .await
            .unwrap();

        let (mut h2_client, h2_conn) = h2::client::handshake(tls_client).await.unwrap();
        tokio::spawn(async move {
            let _ = h2_conn.await;
        });

        let request = Request::builder()
            .method("POST")
            .uri("https://example.com/streaming")
            .body(())
            .unwrap();

        // H2 client WITHOUT content-length
        let (response, mut send_stream) = h2_client.send_request(request, false).unwrap();
        send_stream
            .send_data(Bytes::from_static(post_body), true)
            .unwrap();

        // Add timeout to response await
        if let Ok(Ok(response)) = tokio::time::timeout(Duration::from_secs(5), response).await {
            assert_eq!(response.status(), 200);
        }

        drop(h2_client);
        let _ = tokio::time::timeout(Duration::from_secs(5), server_task).await;
        reset_test_upstream_connector();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[serial]
    async fn test_h2_multiplexed_breakpoints() {
        // Reset state
        reset_test_transaction_observer();
        reset_test_upstream_connector();
        breakpoints::reset_for_tests();

        let storage_dir = tempfile::tempdir().unwrap();
        storage::reset_store_for_tests(storage_dir.path().to_str().unwrap()).expect("init store");

        let cert_dir = tempfile::tempdir().unwrap();
        let cert_manager = Arc::new(CertManager::new(cert_dir.path().to_str().unwrap()).unwrap());
        let tls_client_config = Arc::new(build_tls_client_config().unwrap());

        // 1. Add a breakpoint rule for /break
        breakpoints::add_breakpoint_rule(BreakpointRuleInput {
            enabled: true,
            method: Some(HttpMethod::Get),
            host_contains: None,
            path_contains: Some("break".into()),
        });

        // 2. Mock upstream
        set_test_upstream_connector({
            move |req| {
                let path = req.path.clone();
                async move {
                    let (mut upstream_side, server_side) = duplex(4096);
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 1024];
                        // Add timeout to prevent indefinite hang
                        let read_result = tokio::time::timeout(
                            Duration::from_secs(5),
                            upstream_side.read(&mut buf),
                        )
                        .await;
                        if let Ok(Ok(_n)) = read_result {
                            let body = format!("Response for {}", path);
                            let _ = upstream_side
                                .write_all(
                                    format!(
                                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                                        body.len(),
                                        body
                                    )
                                    .as_bytes(),
                                )
                                .await;
                        }
                    });
                    let timing = ConnectionTiming {
                        dns_ms: 0,
                        tcp_ms: 0,
                        tls_ms: Some(1),
                        server_ip: None,
                        tls_version: None,
                        tls_cipher: None,
                    };
                    Ok((UpstreamStream::Mock(server_side), timing))
                }
            }
        });

        let (client_side, server_side) = duplex(65536);

        // Server task
        let _server_task = tokio::spawn(async move {
            let _ = intercept_tls_stream(
                server_side,
                "example.com".into(),
                cert_manager,
                tls_client_config,
            )
            .await;
        });

        let mut client_side = client_side;
        let mut resp = vec![0u8; 128];
        let _ = client_side.read(&mut resp).await.unwrap();

        let mut client_cfg = ClientConfig::builder()
            .with_root_certificates({
                let mut roots = RootCertStore::empty();
                let cm = CertManager::new(cert_dir.path().to_str().unwrap()).unwrap();
                roots.add(cm.test_ca_der()).unwrap();
                roots
            })
            .with_no_client_auth();
        client_cfg.alpn_protocols = vec![b"h2".to_vec()];
        let connector = TlsConnector::from(Arc::new(client_cfg));
        let server_name = ServerName::try_from("example.com").unwrap();
        let tls_client = connector.connect(server_name, client_side).await.unwrap();

        let (h2_client, h2_conn) = h2::client::handshake(tls_client).await.unwrap();
        tokio::spawn(async move {
            h2_conn.await.unwrap();
        });

        // 3. Send Request 1 (Breakpoint) and Request 2 (Normal)
        // Request 2 should finish even if Request 1 is paused.

        let mut h2_client_1 = h2_client.clone();
        let req1_task = tokio::spawn(async move {
            let request = Request::builder()
                .method("GET")
                .uri("https://example.com/break")
                .body(())
                .unwrap();
            let (response, _) = h2_client_1.send_request(request, true).unwrap();
            response.await.unwrap()
        });

        let mut h2_client_2 = h2_client.clone();
        let req2_task = tokio::spawn(async move {
            let request = Request::builder()
                .method("GET")
                .uri("https://example.com/normal")
                .body(())
                .unwrap();
            let (response, _) = h2_client_2.send_request(request, true).unwrap();
            response.await.unwrap()
        });

        // Wait for Request 2 to finish. If it's blocked by Request 1, this will timeout or hang.
        let resp2 = tokio::time::timeout(std::time::Duration::from_secs(5), req2_task)
            .await
            .expect("Request 2 (normal) timed out - it might be blocked by Request 1 (breakpoint)!")
            .unwrap();
        assert_eq!(resp2.status(), 200);

        // Now resume Request 1
        let (tx_sender, _tx_rx) = mpsc::unbounded_channel::<(String, TransactionState)>();
        set_test_transaction_observer(move |tx| {
            let _ = tx_sender.send((tx.id.clone(), tx.state));
        });

        // We need to find the ID of the paused request. We can look in storage or wait for observer.
        // Since it's already paused, it might have already sent the Breakpointed state before we set the observer.
        // Let's query storage.
        let mut break_id = String::new();
        for _ in 0..10 {
            let result = storage::query_transactions(&TransactionFilter::default(), 0, 10)
                .await
                .unwrap();
            if let Some(tx) = result
                .items
                .iter()
                .find(|tx| tx.path == "/break" && tx.state == TransactionState::Breakpointed)
            {
                break_id = tx.id.clone();
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert!(
            !break_id.is_empty(),
            "Could not find breakpointed transaction"
        );

        breakpoints::resume_breakpoint(&break_id, RequestEdit::default()).expect("resume");

        let resp1 = tokio::time::timeout(std::time::Duration::from_secs(5), req1_task)
            .await
            .expect("Request 1 timed out after resume")
            .unwrap();
        assert_eq!(resp1.status(), 200);

        reset_test_transaction_observer();
        reset_test_upstream_connector();
        breakpoints::reset_for_tests();
    }
}
