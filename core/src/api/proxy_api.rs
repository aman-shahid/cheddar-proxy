//! Proxy API for Flutter
//!
//! This module provides the main API for controlling the proxy from Flutter.

use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(test)]
use std::sync::Arc;
use std::sync::{Mutex, RwLock};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tokio::task;

use crate::frb_generated::StreamSink;
use crate::mcp::auth::McpAuthTokenManager;
use crate::mcp::manager::{self, McpRuntimeConfig, McpRuntimeStatus};
use crate::models::breakpoint::{BreakpointRule, BreakpointRuleInput, RequestEdit};
use crate::models::{
    HttpMethod, HttpTransaction, PaginatedTransactions, TransactionFilter, TransactionState,
};
use crate::platform::{self, CertTrustStatus};
use crate::proxy::breakpoints;
use crate::storage::{self, TransactionFilterExt};
use std::collections::HashMap;
use std::path::PathBuf;

// Global traffic stream sink
static TRAFFIC_SINK: Mutex<Option<StreamSink<HttpTransaction>>> = Mutex::new(None);
static STREAM_FILTER: Lazy<RwLock<TransactionFilter>> =
    Lazy::new(|| RwLock::new(TransactionFilter::default()));
static MCP_TRANSACTION_CHANNEL: Lazy<broadcast::Sender<HttpTransaction>> = Lazy::new(|| {
    let (tx, _rx) = broadcast::channel(512);
    tx
});
// Global proxy state
static PROXY_RUNNING: AtomicBool = AtomicBool::new(false);
static ACTIVE_SERVER_TASK: AtomicU64 = AtomicU64::new(0);

/// Current running proxy config (port, bind_address)
static CURRENT_PROXY_CONFIG: Lazy<RwLock<(u16, String)>> =
    Lazy::new(|| RwLock::new((9090, "127.0.0.1".to_string())));

#[cfg(test)]
type TestTransactionObserver = dyn Fn(&HttpTransaction) + Send + Sync;

#[cfg(test)]
static TEST_TRANSACTION_OBSERVER: Lazy<Mutex<Option<Arc<TestTransactionObserver>>>> =
    Lazy::new(|| Mutex::new(None));

/// Get the version of the Cheddar Proxy core library
#[frb(sync)]
pub fn get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Initialize the core library (call once at startup)
/// `storage_path` is used to store log files in release mode
#[allow(unused_variables)]
pub fn init_core(storage_path: Option<String>) -> Result<bool, String> {
    if std::env::var_os("RUST_LOG").is_none() {
        std::env::set_var("RUST_LOG", "info");
    }

    // Initialize tracing/logging based on build mode
    #[cfg(debug_assertions)]
    {
        // Debug mode: log to console (stderr)
        let level = resolve_log_level();
        let _ = tracing_subscriber::fmt().with_max_level(level).try_init();
    }

    #[cfg(not(debug_assertions))]
    {
        // Release mode: log to file
        let level = resolve_log_level();

        let log_dir = storage_path
            .as_ref()
            .map(|p| std::path::PathBuf::from(p).join("logs"))
            .unwrap_or_else(|| std::path::PathBuf::from("logs"));

        // Create logs directory if it doesn't exist (fail fast if we can't)
        std::fs::create_dir_all(&log_dir).map_err(|e| {
            format!(
                "Failed to create log directory {}: {}",
                log_dir.display(),
                e
            )
        })?;
        let file_appender = tracing_appender::rolling::daily(&log_dir, "cheddarproxy_core");
        let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

        // Keep the guard alive for the lifetime of the program
        // We leak it intentionally since logging should last until program exit
        std::mem::forget(_guard);

        // If logging is already set elsewhere (e.g., MCP runtime re-entry), don't treat it as fatal.
        let _ = tracing_subscriber::fmt()
            .with_max_level(level)
            .with_writer(non_blocking)
            .try_init();
    }

    tracing::info!(
        "Cheddar Proxy core initialized v{}",
        env!("CARGO_PKG_VERSION")
    );
    Ok(true)
}

fn resolve_log_level() -> tracing::level_filters::LevelFilter {
    use tracing::level_filters::LevelFilter;

    match std::env::var("RUST_LOG") {
        Ok(val) => match val.to_lowercase().as_str() {
            "trace" => LevelFilter::TRACE,
            "debug" => LevelFilter::DEBUG,
            "info" => LevelFilter::INFO,
            "warn" | "warning" => LevelFilter::WARN,
            "error" => LevelFilter::ERROR,
            _ => LevelFilter::INFO,
        },
        Err(_) => LevelFilter::INFO,
    }
}

/// Proxy configuration
#[frb]
pub struct ProxyConfig {
    /// Port to listen on
    pub port: u16,
    /// Bind address (e.g., "127.0.0.1")
    pub bind_address: String,
    /// Whether to enable HTTPS interception
    pub enable_https: bool,
    /// Whether to enable HTTP/2 support for upstream connections
    pub enable_h2: bool,
    /// Path to store certificates (e.g. CA)
    pub storage_path: String,
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            port: 9090,
            bind_address: "127.0.0.1".to_string(),
            enable_https: false,
            enable_h2: false,
            storage_path: "./".to_string(),
        }
    }
}

#[frb(sync)]
pub fn create_default_config() -> ProxyConfig {
    ProxyConfig::default()
}

/// Proxy status information
#[frb]
pub struct ProxyStatus {
    /// Whether the proxy is running
    pub is_running: bool,
    /// Current port
    pub port: u16,
    /// Bind address
    pub bind_address: String,
    /// Number of active connections
    pub active_connections: u32,
    /// Total requests processed
    pub total_requests: u64,
}

#[frb]
pub struct McpServerStatus {
    pub is_running: bool,
    pub socket_path: Option<String>,
    pub last_error: Option<String>,
    /// "sdk" or "custom" - indicates which MCP implementation is being used
    pub implementation: String,
    pub allow_writes: bool,
    pub require_approval: bool,
}

impl From<McpRuntimeStatus> for McpServerStatus {
    fn from(value: McpRuntimeStatus) -> Self {
        Self {
            is_running: value.is_running,
            socket_path: value.socket_path,
            last_error: value.last_error,
            implementation: "sdk".to_string(),
            allow_writes: value.allow_writes,
            require_approval: value.require_approval,
        }
    }
}

/// Get current proxy status
#[frb(sync)]
pub fn get_proxy_status() -> ProxyStatus {
    let (port, bind_address) = {
        let config = CURRENT_PROXY_CONFIG.read().unwrap();
        (config.0, config.1.clone())
    };
    ProxyStatus {
        is_running: PROXY_RUNNING.load(Ordering::SeqCst),
        port,
        bind_address,
        active_connections: 0,
        total_requests: 0,
    }
}

#[frb]
pub async fn get_mcp_server_status() -> McpServerStatus {
    manager::current_status().await.into()
}

#[frb]
pub async fn enable_mcp_server(
    storage_path: String,
    auto_start_proxy: bool,
    allow_writes: Option<bool>,
    require_approval: Option<bool>,
) -> Result<McpServerStatus, String> {
    tracing::info!(
        "MCP enable requested (storage_path={}, auto_start_proxy={}, allow_writes={:?}, require_approval={:?})",
        storage_path,
        auto_start_proxy,
        allow_writes,
        require_approval
    );
    if storage_path.trim().is_empty() {
        return Err("storage_path cannot be empty".to_string());
    }
    let config = McpRuntimeConfig {
        storage_path: PathBuf::from(storage_path),
        auto_start_proxy,
        allow_writes: allow_writes.unwrap_or(false),
        require_approval: require_approval.unwrap_or(true),
        socket_path: None,
    };
    manager::start_runtime(config)
        .await
        .map(|status| {
            let result = McpServerStatus::from(status);
            tracing::info!(
                "MCP runtime started: running={} socket={:?} implementation={}",
                result.is_running,
                result.socket_path,
                result.implementation
            );
            result
        })
        .map_err(|e| {
            tracing::error!("MCP enable failed: {}", e);
            e.to_string()
        })
}

#[frb]
pub async fn disable_mcp_server() -> Result<McpServerStatus, String> {
    tracing::info!("MCP disable requested");
    manager::stop_runtime()
        .await
        .map(|status| {
            tracing::info!(
                "MCP runtime stop result: running={} socket={:?} error={:?}",
                status.is_running,
                status.socket_path,
                status.last_error
            );
            McpServerStatus::from(status)
        })
        .map_err(|e| {
            tracing::error!("MCP disable failed: {}", e);
            e.to_string()
        })
}

#[frb]
pub async fn get_mcp_auth_token(storage_path: String, regenerate: bool) -> Result<String, String> {
    if storage_path.trim().is_empty() {
        return Err("storage_path cannot be empty".to_string());
    }
    task::spawn_blocking(move || {
        let manager = McpAuthTokenManager::new(PathBuf::from(storage_path));
        if regenerate {
            manager.regenerate_token()
        } else {
            manager.ensure_token()
        }
    })
    .await
    .map_err(|e| e.to_string())?
    .map(|token| {
        if regenerate {
            crate::mcp::manager::notify_token_rotated();
        }
        token
    })
    .map_err(|e| e.to_string())
}

/// Initialize the traffic stream
#[frb(sync)]
pub fn create_traffic_stream(sink: StreamSink<HttpTransaction>) -> Result<(), String> {
    let mut guard = TRAFFIC_SINK.lock().map_err(|e| e.to_string())?;
    *guard = Some(sink);
    tracing::info!("Traffic stream initialized");
    Ok(())
}

/// Update the live stream filter to reduce UI load
#[frb(sync)]
pub fn update_stream_filter(filter: Option<TransactionFilter>) -> Result<bool, String> {
    set_stream_filter(filter);
    Ok(true)
}

/// Internal helper to check if proxy should keep running
pub fn is_running_internal() -> bool {
    PROXY_RUNNING.load(Ordering::SeqCst)
}

#[cfg(test)]
pub fn set_test_transaction_observer<F>(observer: F)
where
    F: Fn(&HttpTransaction) + Send + Sync + 'static,
{
    let mut guard = TEST_TRANSACTION_OBSERVER.lock().unwrap();
    *guard = Some(Arc::new(observer));
}

#[cfg(test)]
pub fn reset_test_transaction_observer() {
    let mut guard = TEST_TRANSACTION_OBSERVER.lock().unwrap();
    guard.take();
}

/// Internal helper to send transaction to sink
pub fn send_transaction_to_sink(tx: HttpTransaction) {
    #[cfg(test)]
    let observer = {
        let guard = TEST_TRANSACTION_OBSERVER.lock().unwrap();
        guard.as_ref().cloned()
    };
    #[cfg(test)]
    if let Some(callback) = observer {
        callback(&tx);
    }

    let _ = MCP_TRANSACTION_CHANNEL.send(tx.clone());

    if !stream_filter_allows(&tx) {
        return;
    }
    if let Ok(guard) = TRAFFIC_SINK.lock() {
        if let Some(sink) = &*guard {
            // Strip large bodies for the UI stream to save memory (lazy load later)
            let mut light_tx = tx;
            light_tx.request_body = None;
            light_tx.response_body = None;
            let _ = sink.add(light_tx);
        }
    }
}

/// Subscribe to live transactions for non-FRB consumers (e.g., MCP).
#[frb(ignore)]
pub(crate) fn subscribe_transaction_events() -> broadcast::Receiver<HttpTransaction> {
    MCP_TRANSACTION_CHANNEL.subscribe()
}

fn stream_filter_allows(tx: &HttpTransaction) -> bool {
    STREAM_FILTER
        .read()
        .map(|filter| filter.matches(tx))
        .unwrap_or(true)
}

fn set_stream_filter(filter: Option<TransactionFilter>) {
    if let Ok(mut guard) = STREAM_FILTER.write() {
        *guard = filter.unwrap_or_default();
    }
}

/// Start the proxy server
/// Returns Ok(true) if started successfully
pub async fn start_proxy(config: ProxyConfig) -> Result<bool, String> {
    if PROXY_RUNNING.load(Ordering::SeqCst) {
        tracing::info!("Proxy already running");
        return Ok(true);
    }
    // Find an available port starting from the requested one
    let selected_port = find_available_port(&config.bind_address, config.port, 20).await?;

    if selected_port != config.port {
        tracing::warn!(
            "Port {} in use, falling back to {}",
            config.port,
            selected_port
        );
    }

    PROXY_RUNNING.store(true, Ordering::SeqCst);
    // Store current config for status queries
    {
        let mut current = CURRENT_PROXY_CONFIG.write().unwrap();
        *current = (selected_port, config.bind_address.clone());
    }
    tracing::info!(
        "Starting proxy on {}:{}",
        config.bind_address,
        selected_port
    );
    storage::init_transaction_store(&config.storage_path).map_err(|e| e.to_string())?;

    // Spawn the real proxy server
    // We clone the config elements manually because ProxyConfig might not be Clone
    // (It is generated by FRB, usually allows Clone, but let's be safe or modify the struct)
    // Actually ProxyConfig is defined in this file. I should derive Clone.
    let bind_address = config.bind_address.clone();
    let port = selected_port;
    let enable_https = config.enable_https;
    let enable_h2 = config.enable_h2;
    let storage_path = config.storage_path.clone();

    tokio::spawn(async move {
        let server_config = crate::proxy::server::ProxyConfig {
            bind_address,
            port,
            enable_https,
            enable_h2,
            storage_path,
        };

        if let Err(e) = crate::proxy::server::run_server(server_config).await {
            tracing::error!("Proxy server error: {}", e);
        }

        // If server exits, ensure flag is cleared
        PROXY_RUNNING.store(false, Ordering::SeqCst);
        ACTIVE_SERVER_TASK.fetch_sub(1, Ordering::SeqCst);
    });
    ACTIVE_SERVER_TASK.fetch_add(1, Ordering::SeqCst);

    Ok(true)
}

async fn find_available_port(
    bind_address: &str,
    start_port: u16,
    max_tries: u16,
) -> Result<u16, String> {
    use std::io::ErrorKind;

    for offset in 0..max_tries {
        let candidate = start_port.saturating_add(offset);
        match TcpListener::bind((bind_address, candidate)).await {
            Ok(listener) => {
                drop(listener); // release so the real server can bind
                return Ok(candidate);
            }
            Err(err) if err.kind() == ErrorKind::AddrInUse => continue,
            Err(err) => {
                return Err(format!(
                    "Failed to bind to {}:{}: {}",
                    bind_address, candidate, err
                ))
            }
        }
    }

    Err(format!(
        "No available port found in range {}-{}",
        start_port,
        start_port.saturating_add(max_tries.saturating_sub(1))
    ))
}

/// Stop the proxy server
pub async fn stop_proxy() -> Result<bool, String> {
    tracing::info!("Stopping proxy");
    PROXY_RUNNING.store(false, Ordering::SeqCst);
    loop {
        if ACTIVE_SERVER_TASK.load(Ordering::SeqCst) == 0 {
            break;
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }
    Ok(true)
}

/// Ensure Root CA exists (generates if needed)
#[frb(sync)]
pub fn ensure_root_ca(storage_path: String) -> Result<String, String> {
    crate::proxy::cert_manager::CertManager::new(&storage_path)
        .map(|_| "CA initialized".to_string())
        .map_err(|e| e.to_string())
}

/// Get Root CA certificate content (PEM)
#[frb(sync)]
pub fn get_root_ca_pem(storage_path: String) -> Result<String, String> {
    crate::proxy::cert_manager::CertManager::new(&storage_path)
        .map(|cm| cm.ca_cert_pem)
        .map_err(|e| e.to_string())
}

/// Create a mock HTTP transaction for testing
/// This will be replaced with real traffic from the proxy
#[frb(sync)]
pub fn create_mock_transaction(
    method: String,
    host: String,
    path: String,
    status_code: Option<u16>,
) -> HttpTransaction {
    let mut headers = HashMap::new();
    headers.insert("User-Agent".to_string(), "CheddarProxy/1.0".to_string());
    headers.insert("Accept".to_string(), "*/*".to_string());

    let mut tx = HttpTransaction::new(
        method
            .parse::<HttpMethod>()
            .unwrap_or_else(|_| HttpMethod::from_str_lossy(&method)),
        "https",
        &host,
        443,
        &path,
        headers,
    );

    if let Some(code) = status_code {
        tx.status_code = Some(code);
        tx.status_message = Some(match code {
            200 => "OK".to_string(),
            201 => "Created".to_string(),
            204 => "No Content".to_string(),
            301 => "Moved Permanently".to_string(),
            302 => "Found".to_string(),
            400 => "Bad Request".to_string(),
            401 => "Unauthorized".to_string(),
            403 => "Forbidden".to_string(),
            404 => "Not Found".to_string(),
            500 => "Internal Server Error".to_string(),
            _ => "Unknown".to_string(),
        });
        tx.state = TransactionState::Completed;
        tx.timing.total_ms = Some(150);
        tx.response_size = Some(1024);
    }

    tx
}

/// Fetch paginated transactions from storage
#[frb]
pub async fn query_transactions(
    filter: Option<TransactionFilter>,
    page: u32,
    page_size: u32,
) -> Result<PaginatedTransactions, String> {
    let effective_filter = filter.unwrap_or_default();
    let mut result = crate::storage::query_transactions(&effective_filter, page, page_size)
        .await
        .map_err(|e| e.to_string())?;

    // Strip bodies for list view to save memory
    for item in &mut result.items {
        item.request_body = None;
        item.response_body = None;
    }

    Ok(result)
}

/// Fetch a single transaction by ID (full details including body)
/// Fetch a single transaction by ID (full details including body)
#[frb]
pub async fn fetch_transaction(id: String) -> Result<HttpTransaction, String> {
    let res = crate::storage::get_transaction_by_id(&id)
        .await
        .map_err(|e| e.to_string())?;
    res.ok_or_else(|| "Transaction not found".to_string())
}

/// Fetch a transaction with bodies preserved for MCP/detail views.
pub async fn get_transaction_detail(id: &str) -> Result<Option<HttpTransaction>, String> {
    crate::storage::get_transaction_by_id(id)
        .await
        .map_err(|e| e.to_string())
}

/// Fetch paginated transactions from storage with time range bounds (for MCP)
pub async fn query_transactions_with_time_range(
    filter: Option<TransactionFilter>,
    start_time_ms: i64,
    end_time_ms: i64,
    page: u32,
    page_size: u32,
) -> Result<PaginatedTransactions, String> {
    let effective_filter = filter.unwrap_or_default();
    let mut result = crate::storage::query_transactions_with_time_range(
        &effective_filter,
        start_time_ms,
        end_time_ms,
        page,
        page_size,
    )
    .await
    .map_err(|e| e.to_string())?;

    // Strip bodies for list view
    for item in &mut result.items {
        item.request_body = None;
        item.response_body = None;
    }

    Ok(result)
}

/// Export transactions to a HAR file on disk.
#[frb]
pub async fn export_har_file(
    output_path: String,
    filter: Option<TransactionFilter>,
) -> Result<u64, String> {
    let effective_filter = filter.unwrap_or_default();
    let transactions = storage::list_transactions(&effective_filter)
        .await
        .map_err(|e| e.to_string())?;
    let count = storage::export_har_to_path(transactions, &output_path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(count as u64)
}

// List recent transactions (ordered by started_at DESC) up to a limit.
#[frb]
pub async fn list_recent_transactions(limit: u32) -> Result<Vec<HttpTransaction>, String> {
    storage::list_recent_transactions(limit)
        .await
        .map_err(|e| e.to_string())
}

/// List a page of transactions older than the given started_at (ms) threshold.
#[frb]
pub async fn list_transactions_page(
    before_started_at_ms: Option<i64>,
    limit: u32,
) -> Result<Vec<HttpTransaction>, String> {
    storage::list_transactions_page(before_started_at_ms, limit)
        .await
        .map_err(|e| e.to_string())
}

/// Import transactions from a HAR file.
#[frb]
pub async fn import_har_file(input_path: String) -> Result<u64, String> {
    let data = std::fs::read_to_string(&input_path).map_err(|e| e.to_string())?;
    let transactions = storage::import_har_from_str(&data).map_err(|e| e.to_string())?;
    let mut count = 0u64;
    for mut tx in transactions {
        tx.state = TransactionState::Completed;
        storage::persist_transaction(tx.clone())
            .await
            .map_err(|e| e.to_string())?;
        send_transaction_to_sink(tx);
        count += 1;
    }
    Ok(count)
}

/// Prune transactions older than specified days (call on startup)
/// Returns the number of transactions deleted
#[frb]
pub async fn prune_old_transactions(days: Option<u32>) -> Result<u64, String> {
    let prune_days = days.unwrap_or(5); // Default 5 days
    storage::prune_older_than(prune_days)
        .await
        .map_err(|e| e.to_string())
}

/// Clear all transactions from the database (manual wipe)
#[frb]
pub async fn clear_all_transactions() -> Result<u64, String> {
    storage::clear_all_transactions()
        .await
        .map_err(|e| e.to_string())
}

/// Get total transaction count in the database
#[frb]
pub async fn get_transaction_count() -> Result<u64, String> {
    storage::get_transaction_count()
        .await
        .map_err(|e| e.to_string())
}

/// Fetch slowest transactions by total duration (descending), optionally filtered.
pub async fn get_slow_transactions(
    filter: Option<TransactionFilter>,
    threshold_ms: Option<u64>,
    limit: Option<u32>,
) -> Result<Vec<HttpTransaction>, String> {
    let effective_filter = filter.unwrap_or_default();
    let capped_limit = limit.unwrap_or(20).clamp(1, 500);
    let mut results = storage::slowest_transactions(&effective_filter, threshold_ms, capped_limit)
        .await
        .map_err(|e| e.to_string())?;

    // Strip bodies to avoid oversized payloads; callers can fetch detail separately.
    for tx in &mut results {
        tx.request_body = None;
        tx.response_body = None;
    }

    Ok(results)
}

/// Breakpoint rule APIs
#[frb(sync)]
pub fn list_breakpoint_rules() -> Result<Vec<BreakpointRule>, String> {
    Ok(breakpoints::list_breakpoint_rules())
}

#[frb(sync)]
pub fn add_breakpoint_rule(input: BreakpointRuleInput) -> Result<BreakpointRule, String> {
    Ok(breakpoints::add_breakpoint_rule(input))
}

#[frb(sync)]
pub fn remove_breakpoint_rule(id: String) -> Result<bool, String> {
    Ok(breakpoints::remove_breakpoint_rule(&id))
}

#[frb]
pub async fn resume_breakpoint(
    transaction_id: String,
    edit: Option<RequestEdit>,
) -> Result<bool, String> {
    let edits = edit.unwrap_or(RequestEdit {
        method: None,
        path: None,
        headers: None,
        body: None,
    });
    breakpoints::resume_breakpoint(&transaction_id, edits).map_err(|e| e.to_string())?;
    Ok(true)
}

#[frb(sync)]
pub fn abort_breakpoint(transaction_id: String, reason: Option<String>) -> Result<bool, String> {
    breakpoints::abort_breakpoint(&transaction_id, reason.unwrap_or_else(|| "Aborted".into()))
        .map(|_| true)
        .map_err(|e| e.to_string())
}

/// System proxy + certificate helpers
#[frb]
pub async fn enable_system_proxy(host: String, port: u16) -> Result<bool, String> {
    let host_clone = host.clone();
    let result = task::spawn_blocking(move || platform::enable_system_proxy(&host_clone, port))
        .await
        .map_err(|e| e.to_string())?;
    result.map(|_| true).map_err(|e| e.to_string())
}

#[frb]
pub async fn disable_system_proxy() -> Result<bool, String> {
    let result = task::spawn_blocking(move || platform::disable_system_proxy())
        .await
        .map_err(|e| e.to_string())?;
    result.map(|_| true).map_err(|e| e.to_string())
}

#[frb]
pub async fn detect_certificate_trust(common_name: String) -> Result<CertTrustStatus, String> {
    let result = task::spawn_blocking(move || platform::detect_certificate_trust(&common_name))
        .await
        .map_err(|e| e.to_string())?;
    result.map_err(|e| e.to_string())
}

/// Result of a replay operation
#[frb]
pub struct ReplayResult {
    /// ID of the new transaction created by the replay
    pub transaction_id: String,
    /// HTTP status code of the response (if successful)
    pub status_code: Option<u16>,
    /// Whether the replay was successful
    pub success: bool,
    /// Error message if replay failed
    pub error: Option<String>,
}

/// Replay a previously captured HTTP request
///
/// This function retrieves the original transaction, applies any overrides,
/// makes a new HTTP request, and captures the response as a new transaction.
#[frb]
pub async fn replay_request(
    transaction_id: String,
    method_override: Option<String>,
    path_override: Option<String>,
    headers_override: Option<std::collections::HashMap<String, String>>,
    body_override: Option<Vec<u8>>,
) -> Result<ReplayResult, String> {
    use crate::models::HttpMethod;
    use crate::replay::{replay_request as do_replay, ReplayParams};

    // Convert method string to enum if provided
    let method = method_override
        .as_ref()
        .and_then(|m| match m.to_uppercase().as_str() {
            "GET" => Some(HttpMethod::Get),
            "POST" => Some(HttpMethod::Post),
            "PUT" => Some(HttpMethod::Put),
            "PATCH" => Some(HttpMethod::Patch),
            "DELETE" => Some(HttpMethod::Delete),
            "HEAD" => Some(HttpMethod::Head),
            "OPTIONS" => Some(HttpMethod::Options),
            "CONNECT" => Some(HttpMethod::Connect),
            "TRACE" => Some(HttpMethod::Trace),
            _ => None,
        });

    let params = ReplayParams {
        method,
        path: path_override,
        headers: headers_override,
        body: body_override,
        accept_invalid_certs: false,
    };

    let result = do_replay(&transaction_id, params).await?;

    Ok(ReplayResult {
        transaction_id: result.transaction_id,
        status_code: result.status_code,
        success: result.success,
        error: result.error,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// WebSocket message APIs
// ─────────────────────────────────────────────────────────────────────────────

use crate::models::WebSocketMessage;

/// Get all WebSocket messages for a connection
#[frb(sync)]
pub fn get_websocket_messages(connection_id: String) -> Vec<WebSocketMessage> {
    storage::get_websocket_messages(&connection_id)
}

/// Get the count of WebSocket messages for a connection
#[frb(sync)]
pub fn get_websocket_message_count(connection_id: String) -> u64 {
    storage::get_websocket_message_count(&connection_id) as u64
}

/// Clear all WebSocket messages for a connection
#[frb(sync)]
pub fn clear_websocket_messages(connection_id: String) {
    storage::clear_websocket_messages(&connection_id);
}

/// Clear all WebSocket messages
#[frb(sync)]
pub fn clear_all_websocket_messages() {
    storage::clear_all_websocket_messages();
}

/// Send a new HTTP request directly (not a replay)
///
/// This allows the Composer to send requests without needing an existing
/// captured transaction. The request will be tracked as a new transaction.
#[frb]
pub async fn send_direct_request(
    url: String,
    method: String,
    headers: std::collections::HashMap<String, String>,
    body: Option<Vec<u8>>,
) -> Result<ReplayResult, String> {
    use crate::replay::{send_direct_request as do_send, DirectRequestParams};

    let params = DirectRequestParams {
        url,
        method,
        headers,
        body,
    };

    let result = do_send(params).await?;

    Ok(ReplayResult {
        transaction_id: result.transaction_id,
        status_code: result.status_code,
        success: result.success,
        error: result.error,
    })
}
