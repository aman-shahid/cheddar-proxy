//! Request replay functionality
//!
//! This module provides the ability to replay HTTP requests that have been
//! previously captured by the proxy.

use crate::api::proxy_api::{get_proxy_status, send_transaction_to_sink};
use crate::models::{HttpMethod, HttpTransaction, TransactionState, TransactionTiming};
use crate::storage::{get_transaction_by_id, persist_transaction};
use std::collections::HashMap;
use std::time::Instant;
use uuid::Uuid;

/// Parameters for replaying a request
#[derive(Debug, Clone, Default)]
pub struct ReplayParams {
    /// Override the HTTP method
    pub method: Option<HttpMethod>,
    /// Override the request path
    pub path: Option<String>,
    /// Override specific headers (merged with original)
    pub headers: Option<HashMap<String, String>>,
    /// Override the request body
    pub body: Option<Vec<u8>>,
    /// Allow invalid TLS certificates (defaults to false)
    pub accept_invalid_certs: bool,
}

/// Result of a replay operation
#[derive(Debug, Clone)]
pub struct ReplayResult {
    /// ID of the new transaction created by the replay
    pub transaction_id: String,
    /// HTTP status code of the response
    pub status_code: Option<u16>,
    /// Whether the replay was successful
    pub success: bool,
    /// Error message if replay failed
    pub error: Option<String>,
}

/// Replay a previously captured HTTP request
///
/// This function:
/// 1. Retrieves the original transaction by ID
/// 2. Applies any overrides from params
/// 3. Makes an HTTP request using reqwest
/// 4. Captures the response as a new transaction
/// 5. Returns the result
pub async fn replay_request(
    transaction_id: &str,
    params: ReplayParams,
) -> Result<ReplayResult, String> {
    let ReplayParams {
        method,
        path,
        headers: header_overrides,
        body,
        accept_invalid_certs,
    } = params;

    // Get the original transaction
    let original = get_transaction_by_id(transaction_id)
        .await
        .map_err(|e| format!("Failed to get transaction: {}", e))?
        .ok_or_else(|| format!("Transaction not found: {}", transaction_id))?;

    // Build the request URL
    let scheme = &original.scheme;
    let host = &original.host;
    let port = original.port;
    let path = path.as_deref().unwrap_or(&original.path);

    let url = if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
        format!("{}://{}{}", scheme, host, path)
    } else {
        format!("{}://{}:{}{}", scheme, host, port, path)
    };

    // Determine method
    let method = method.unwrap_or(original.method);

    // Build headers - start with original, then apply overrides
    let mut headers = original.request_headers.clone();
    if let Some(override_headers) = header_overrides {
        for (k, v) in override_headers {
            headers.insert(k, v);
        }
    }

    // Remove headers that shouldn't be forwarded
    headers.remove("host");
    headers.remove("Host");
    headers.remove("content-length");
    headers.remove("Content-Length");
    headers.remove("transfer-encoding");
    headers.remove("Transfer-Encoding");

    // Determine body
    let body = body.or_else(|| original.request_body.clone());

    // Create a new transaction for tracking
    let new_id = Uuid::new_v4().to_string();
    let start_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    let mut new_tx = HttpTransaction::new(method, scheme, host, port, path, headers.clone());
    new_tx.id = new_id.clone();
    new_tx.timing.start_time = start_time;
    new_tx.request_body = body.clone();
    new_tx.notes = Some(format!("Replayed from {}", transaction_id));

    // Send initial state to UI
    send_transaction_to_sink(new_tx.clone());

    // Make the HTTP request
    let request_start = Instant::now();
    let mut client_builder = reqwest::Client::builder();
    // Route through our proxy if running so timing is captured consistently.
    if let Ok(status) = std::panic::catch_unwind(get_proxy_status) {
        if status.is_running {
            let proxy_url = format!("http://127.0.0.1:{}", status.port);
            if let Ok(proxy) = reqwest::Proxy::all(&proxy_url) {
                // Route through our proxy; disable env/system proxies to avoid loops.
                client_builder = client_builder.no_proxy().proxy(proxy);
                // Trust our MITM cert for replay traffic (reqwest doesn't use OS trust on macOS/Windows).
                client_builder = client_builder.danger_accept_invalid_certs(true);
            }
        }
    }
    if accept_invalid_certs {
        client_builder = client_builder.danger_accept_invalid_certs(true);
    }
    let client = client_builder
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let reqwest_method = match method {
        HttpMethod::Get => reqwest::Method::GET,
        HttpMethod::Post => reqwest::Method::POST,
        HttpMethod::Put => reqwest::Method::PUT,
        HttpMethod::Patch => reqwest::Method::PATCH,
        HttpMethod::Delete => reqwest::Method::DELETE,
        HttpMethod::Head => reqwest::Method::HEAD,
        HttpMethod::Options => reqwest::Method::OPTIONS,
        HttpMethod::Connect => reqwest::Method::CONNECT,
        HttpMethod::Trace => reqwest::Method::TRACE,
    };

    let mut request_builder = client.request(reqwest_method, &url);

    // Add headers
    for (key, value) in &headers {
        if let Ok(header_name) = reqwest::header::HeaderName::try_from(key.as_str()) {
            if let Ok(header_value) = reqwest::header::HeaderValue::from_str(value) {
                request_builder = request_builder.header(header_name, header_value);
            }
        }
    }

    // Add body if present
    if let Some(body_bytes) = body {
        request_builder = request_builder.body(body_bytes);
    }

    // Execute request
    // Measure time until headers are received (TTFB)
    let response_result = request_builder.send().await;
    let ttfb = request_start.elapsed();
    let ttfb_ms = ttfb.as_millis() as u32;

    match response_result {
        Ok(response) => {
            let status = response.status().as_u16();
            let status_text = response.status().canonical_reason().map(String::from);

            // Collect response headers
            let response_headers: HashMap<String, String> = response
                .headers()
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string()))
                .collect();

            let content_type = response_headers.get("content-type").cloned();

            // Get response body
            // Measure download time
            let download_start = Instant::now();
            let response_body = response
                .bytes()
                .await
                .map(|b| b.to_vec())
                .unwrap_or_default();
            let download_ms = download_start.elapsed().as_millis() as u32;
            let response_size = response_body.len() as u64;

            // Total time is start to finish
            let total_ms = request_start.elapsed().as_millis() as u32;

            // Update transaction with response
            new_tx.status_code = Some(status);
            new_tx.status_message = status_text;
            new_tx.response_headers = Some(response_headers);
            new_tx.response_body = Some(response_body);
            new_tx.response_content_type = content_type;
            new_tx.response_size = Some(response_size);
            new_tx.state = TransactionState::Completed;

            // Populate timing breakdown
            // waiting_ms = TTFB (includes DNS/TCP/TLS since we can't separate them with high-level reqwest)
            new_tx.timing = TransactionTiming {
                start_time,
                waiting_ms: Some(ttfb_ms),
                content_download_ms: Some(download_ms),
                total_ms: Some(total_ms),
                ..Default::default()
            };

            // Send updated state to UI
            send_transaction_to_sink(new_tx.clone());

            // Persist to storage
            let _ = persist_transaction(new_tx).await;

            Ok(ReplayResult {
                transaction_id: new_id,
                status_code: Some(status),
                success: true,
                error: None,
            })
        }
        Err(e) => {
            // Update transaction with error
            // If request failed, use ttfb as total duration (time until failure)
            new_tx.state = TransactionState::Failed;
            new_tx.notes = Some(format!("Replay failed: {}", e));
            new_tx.timing = TransactionTiming {
                start_time,
                total_ms: Some(ttfb_ms),
                ..Default::default()
            };

            // Send updated state to UI
            send_transaction_to_sink(new_tx.clone());

            // Persist to storage
            let _ = persist_transaction(new_tx).await;

            Ok(ReplayResult {
                transaction_id: new_id,
                status_code: None,
                success: false,
                error: Some(e.to_string()),
            })
        }
    }
}

/// Parameters for sending a direct (new) HTTP request
#[derive(Debug, Clone)]
pub struct DirectRequestParams {
    /// The full URL (including scheme, host, port if non-standard, path, query)
    pub url: String,
    /// HTTP method as string (GET, POST, etc.)
    pub method: String,
    /// Request headers
    pub headers: HashMap<String, String>,
    /// Request body (optional)
    pub body: Option<Vec<u8>>,
}

/// Send a new HTTP request directly (not a replay of existing transaction)
///
/// This function:
/// 1. Parses the URL to extract host, path, scheme, port
/// 2. Creates a new transaction for tracking
/// 3. Makes the HTTP request
/// 4. Returns the result
pub async fn send_direct_request(params: DirectRequestParams) -> Result<ReplayResult, String> {
    let DirectRequestParams {
        url,
        method,
        headers,
        body,
    } = params;

    // Parse the URL
    let parsed_url =
        reqwest::Url::parse(&url).map_err(|e| format!("Invalid URL '{}': {}", url, e))?;

    let scheme = parsed_url.scheme().to_string();
    let host = parsed_url.host_str().ok_or("URL has no host")?.to_string();
    let port = parsed_url
        .port()
        .unwrap_or(if scheme == "https" { 443 } else { 80 });
    let path = if let Some(q) = parsed_url.query() {
        format!("{}?{}", parsed_url.path(), q)
    } else {
        parsed_url.path().to_string()
    };

    // Parse method
    let http_method = match method.to_uppercase().as_str() {
        "GET" => HttpMethod::Get,
        "POST" => HttpMethod::Post,
        "PUT" => HttpMethod::Put,
        "PATCH" => HttpMethod::Patch,
        "DELETE" => HttpMethod::Delete,
        "HEAD" => HttpMethod::Head,
        "OPTIONS" => HttpMethod::Options,
        "CONNECT" => HttpMethod::Connect,
        "TRACE" => HttpMethod::Trace,
        _ => return Err(format!("Unsupported HTTP method: {}", method)),
    };

    // Clean headers (remove hop-by-hop headers)
    let mut clean_headers = headers.clone();
    clean_headers.remove("host");
    clean_headers.remove("Host");
    clean_headers.remove("content-length");
    clean_headers.remove("Content-Length");
    clean_headers.remove("transfer-encoding");
    clean_headers.remove("Transfer-Encoding");

    // Create a new transaction for tracking
    let new_id = Uuid::new_v4().to_string();
    let start_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;

    let mut new_tx = HttpTransaction::new(
        http_method,
        &scheme,
        &host,
        port,
        &path,
        clean_headers.clone(),
    );
    new_tx.id = new_id.clone();
    new_tx.timing.start_time = start_time;
    new_tx.request_body = body.clone();
    new_tx.notes = Some("Direct request from Composer".to_string());

    // Send initial state to UI
    send_transaction_to_sink(new_tx.clone());

    // Make the HTTP request
    let request_start = Instant::now();
    let mut client_builder = reqwest::Client::builder();
    // Route through our proxy if running so timing is captured consistently.
    if let Ok(status) = std::panic::catch_unwind(get_proxy_status) {
        if status.is_running {
            let proxy_url = format!("http://127.0.0.1:{}", status.port);
            if let Ok(proxy) = reqwest::Proxy::all(&proxy_url) {
                // Route through our proxy; disable env/system proxies to avoid loops.
                client_builder = client_builder.no_proxy().proxy(proxy);
                // Trust our MITM cert for composer traffic as well.
                client_builder = client_builder.danger_accept_invalid_certs(true);
            }
        }
    }

    let client = client_builder
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let reqwest_method = match http_method {
        HttpMethod::Get => reqwest::Method::GET,
        HttpMethod::Post => reqwest::Method::POST,
        HttpMethod::Put => reqwest::Method::PUT,
        HttpMethod::Patch => reqwest::Method::PATCH,
        HttpMethod::Delete => reqwest::Method::DELETE,
        HttpMethod::Head => reqwest::Method::HEAD,
        HttpMethod::Options => reqwest::Method::OPTIONS,
        HttpMethod::Connect => reqwest::Method::CONNECT,
        HttpMethod::Trace => reqwest::Method::TRACE,
    };

    let mut request_builder = client.request(reqwest_method, &url);

    // Add headers
    for (key, value) in &clean_headers {
        if let Ok(header_name) = reqwest::header::HeaderName::try_from(key.as_str()) {
            if let Ok(header_value) = reqwest::header::HeaderValue::from_str(value) {
                request_builder = request_builder.header(header_name, header_value);
            }
        }
    }

    // Add body if present
    if let Some(body_bytes) = body {
        request_builder = request_builder.body(body_bytes);
    }

    // Execute request
    // Measure time until headers are received (TTFB)
    let response_result = request_builder.send().await;
    let ttfb = request_start.elapsed();
    let ttfb_ms = ttfb.as_millis() as u32;

    match response_result {
        Ok(response) => {
            let status = response.status().as_u16();
            let status_text = response.status().canonical_reason().map(String::from);

            // Collect response headers
            let response_headers: HashMap<String, String> = response
                .headers()
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string()))
                .collect();

            let content_type = response_headers.get("content-type").cloned();

            // Get response body
            // Measure download time
            let download_start = Instant::now();
            let response_body = response
                .bytes()
                .await
                .map(|b| b.to_vec())
                .unwrap_or_default();
            let download_ms = download_start.elapsed().as_millis() as u32;
            let response_size = response_body.len() as u64;

            // Total time is start to finish
            let total_ms = request_start.elapsed().as_millis() as u32;

            // Update transaction with response
            new_tx.status_code = Some(status);
            new_tx.status_message = status_text;
            new_tx.response_headers = Some(response_headers);
            new_tx.response_body = Some(response_body);
            new_tx.response_content_type = content_type;
            new_tx.response_size = Some(response_size);
            new_tx.state = TransactionState::Completed;

            // Populate timing breakdown
            new_tx.timing = TransactionTiming {
                start_time,
                waiting_ms: Some(ttfb_ms),
                content_download_ms: Some(download_ms),
                total_ms: Some(total_ms),
                ..Default::default()
            };

            // Send updated state to UI
            send_transaction_to_sink(new_tx.clone());

            // Persist to storage
            let _ = persist_transaction(new_tx).await;

            Ok(ReplayResult {
                transaction_id: new_id,
                status_code: Some(status),
                success: true,
                error: None,
            })
        }
        Err(e) => {
            // Update transaction with error
            new_tx.state = TransactionState::Failed;
            new_tx.notes = Some(format!("Request failed: {}", e));
            new_tx.timing = TransactionTiming {
                start_time,
                total_ms: Some(ttfb_ms),
                ..Default::default()
            };

            // Send updated state to UI
            send_transaction_to_sink(new_tx.clone());

            // Persist to storage
            let _ = persist_transaction(new_tx).await;

            Ok(ReplayResult {
                transaction_id: new_id,
                status_code: None,
                success: false,
                error: Some(e.to_string()),
            })
        }
    }
}
