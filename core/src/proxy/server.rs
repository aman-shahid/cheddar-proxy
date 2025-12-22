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
#[cfg(test)]
use once_cell::sync::Lazy;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore};
use std::collections::{HashMap, VecDeque};
#[cfg(test)]
use std::future::Future;
use std::io;
use std::mem;
use std::pin::Pin;
use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;
use std::task::{Context as TaskContext, Poll};
use thiserror::Error;
#[cfg(test)]
use tokio::io::DuplexStream;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::Instant;
use tokio_rustls::{TlsAcceptor, TlsConnector, TlsStream};
use webpki_roots::TLS_SERVER_ROOTS;

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_HEADER_COUNT: usize = 128;
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
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
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
    /// Certificate storage root
    pub storage_path: String,
}

/// Run the proxy server
pub async fn run_server(config: ProxyConfig) -> anyhow::Result<()> {
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
    let parsed_request = read_http_request(client, RequestScheme::Http).await?;
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
        match connect_upstream(&parsed_request, tls_client_config).await {
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
        send_transaction_to_sink(tx);
        return Ok(());
    }

    let _ = upstream.flush().await;
    tx.timing.request_send_ms = Some(send_start.elapsed().as_millis() as u32);

    // Measure waiting time (TTFB - time to first byte)
    let waiting_start = Instant::now();

    match read_response_head(&mut upstream).await {
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
            persist_and_stream(tx).await;
        }
        Err(err) => {
            tracing::error!("Failed to read response head: {err}");
            respond_with_status(client, 502, "Bad Gateway", "Failed to read response").await?;
            tx.state = TransactionState::Failed;
            tx.status_code = Some(502);
            tx.status_message = Some("Failed to read response".to_string());
            tx.notes = Some("No response from upstream".to_string());
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
    #[cfg(test)]
    let connector_opt = {
        let guard = TEST_CONNECTOR.lock().unwrap();
        guard.as_ref().cloned()
    };
    #[cfg(test)]
    if let Some(connector) = connector_opt {
        return connector(parsed_request).await;
    }
    // Note: tokio::net::TcpStream::connect does DNS resolution internally,
    // so we can't measure DNS and TCP separately without using lookup_host.
    // For now, we measure them together and split the time roughly.
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

    // Capture server IP address, preferring IPv4 representation
    let server_ip = stream.peer_addr().ok().map(|addr| {
        match addr.ip() {
            std::net::IpAddr::V4(v4) => v4.to_string(),
            std::net::IpAddr::V6(v6) => {
                // Convert IPv6-mapped IPv4 (e.g., ::ffff:127.0.0.1) to IPv4
                if let Some(v4) = v6.to_ipv4_mapped() {
                    v4.to_string()
                } else {
                    v6.to_string()
                }
            }
        }
    });

    // Estimate DNS vs TCP split (rough heuristic: DNS ~40% of connect time)
    let dns_ms = connect_elapsed * 4 / 10;
    let tcp_ms = connect_elapsed - dns_ms;

    if parsed_request.scheme == "https" {
        let config = tls_client_config
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

        let timing = ConnectionTiming {
            dns_ms,
            tcp_ms,
            tls_ms: Some(tls_ms),
            server_ip,
            tls_version,
            tls_cipher,
        };
        Ok((UpstreamStream::Tls(TlsStream::from(tls)), timing))
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
async fn tunnel(mut client: TcpStream, mut upstream: TcpStream) -> anyhow::Result<()> {
    let (mut client_reader, mut client_writer) = client.split();
    let (mut upstream_reader, mut upstream_writer) = upstream.split();

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

#[allow(clippy::large_enum_variant)]
enum UpstreamStream {
    Plain(TcpStream),
    Tls(TlsStream<TcpStream>),
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
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_write(cx, data),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_flush(cx),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_flush(cx),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            UpstreamStream::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            UpstreamStream::Tls(stream) => Pin::new(stream).poll_shutdown(cx),
            #[cfg(test)]
            UpstreamStream::Mock(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

/// Parsed HTTP request with metadata required for forwarding/capture.
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
}

impl ParsedRequest {
    fn to_breakpoint_context(&self) -> BreakpointContext {
        BreakpointContext {
            method: self.method,
            host: self.host.clone(),
            path: self.path.clone(),
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

#[derive(Debug)]
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

    let method = method_str
        .parse::<HttpMethod>()
        .unwrap_or_else(|_| HttpMethod::from_str_lossy(method_str));
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
    })
}

async fn handle_connect_tunnel(
    client: TcpStream,
    parsed: ParsedRequest,
    cert_manager: Option<Arc<CertManager>>,
    tls_client_config: Option<Arc<ClientConfig>>,
) -> anyhow::Result<()> {
    if let (Some(manager), Some(tls_config)) = (cert_manager, tls_client_config) {
        intercept_tls_connection(client, parsed.host.clone(), manager, tls_config).await?;
        return Ok(());
    }

    handle_plain_connect(client, parsed).await
}

async fn intercept_tls_connection(
    client: TcpStream,
    host: String,
    cert_manager: Arc<CertManager>,
    tls_client_config: Arc<ClientConfig>,
) -> anyhow::Result<()> {
    intercept_tls_stream(client, host, cert_manager, tls_client_config).await
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
    let mut tls_stream = TlsStream::from(tls_stream);

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

            tunnel(client, upstream).await?;
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
    writer
        .write_all(format!("{method} {path} {version}\r\n").as_bytes())
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
    tx.request_headers = parsed.request_headers.clone();
    tx.request_content_type = header_value(&parsed.request_headers, "content-type");
    if let RequestBodyKind::Edited { data } = &parsed.body_kind {
        tx.request_body = capture_body(data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::proxy_api::{reset_test_transaction_observer, set_test_transaction_observer};
    use crate::models::breakpoint::BreakpointRuleInput;
    use crate::models::TransactionFilter;
    use serial_test::serial;
    use std::net::TcpListener as StdTcpListener;
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
            let n = upstream_peer.read(&mut buf).await.unwrap();
            let forwarded = String::from_utf8_lossy(&buf[..n]);
            assert!(forwarded.contains("GET /mock"));
            upstream_peer
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nPONG")
                .await
                .unwrap();
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

        upstream_task.await.unwrap();
        reset_test_upstream_connector();

        let result = storage::query_transactions(&TransactionFilter::default(), 0, 10)
            .await
            .expect("query transactions");
        assert_eq!(result.items.len(), 1);
        let tx = &result.items[0];
        assert_eq!(tx.path, "/mock");
        assert_eq!(tx.status_code, Some(200));
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
            let n = upstream_peer.read(&mut buf).await.unwrap();
            let forwarded = String::from_utf8_lossy(&buf[..n]);
            assert!(forwarded.contains("GET /handle"));
            upstream_peer
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                .await
                .unwrap();
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

        server_task.await.unwrap();
        upstream_task.await.unwrap();
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
            let n = upstream_peer.read(&mut buf).await.unwrap();
            let forwarded = String::from_utf8_lossy(&buf[..n]);
            assert!(forwarded.contains("GET /edited"));
            upstream_peer
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                .await
                .unwrap();
        });

        let (tx_sender, mut tx_rx) = mpsc::unbounded_channel::<(String, TransactionState)>();
        set_test_transaction_observer(move |tx| {
            let _ = tx_sender.send((tx.id.clone(), tx.state));
        });

        let resume_task = tokio::spawn(async move {
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

        resume_task.await.unwrap();
        upstream_task.await.unwrap();

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
            let mut abort_sent = false;
            while let Some((id, state)) = state_rx.recv().await {
                if state == TransactionState::Breakpointed && !abort_sent {
                    // Retry with backoff - the breakpoint may not be registered yet
                    for attempt in 0..10 {
                        if attempt > 0 {
                            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                        }
                        if breakpoints::abort_breakpoint(&id, "aborted in test".into()).is_ok() {
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

        let aborted_id = abort_task.await.unwrap().expect("abort triggered");

        reset_test_transaction_observer();
        breakpoints::reset_for_tests();
        assert!(
            !aborted_id.is_empty(),
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
}
