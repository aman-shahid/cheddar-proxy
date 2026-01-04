//! MCP Server implementation using the official rmcp SDK.
//!
//! This provides a spec-compliant MCP server (protocol version 2025-11-25) using the official SDK.
//! The server exposes tools and resources for controlling the proxy and inspecting traffic.

use std::path::PathBuf;
use std::sync::Arc;

use rmcp::handler::server::tool::{ToolCallContext, ToolRouter};
use rmcp::handler::server::wrapper::{Json, Parameters};
use rmcp::model::*;
use rmcp::service::{RequestContext, RoleServer};
use rmcp::{tool, tool_router, ErrorData as McpError, ServerHandler};
use schemars::JsonSchema;
use serde::Deserialize;
use tokio::sync::Mutex;

use crate::api::proxy_api::{self, ProxyConfig};
use crate::models::breakpoint::{BreakpointRuleInput, RequestEdit};
use crate::models::TransactionFilter;
use crate::platform::{self, CertTrustStatus};
use crate::proxy::breakpoints;

const ROOT_CA_COMMON_NAME: &str = "Cheddar Proxy CA";

// ============================================================================
// Configuration
// ============================================================================

/// Configuration for the MCP server runtime.
#[derive(Debug, Clone)]
pub struct McpServerConfig {
    pub storage_path: PathBuf,
    pub auto_start_proxy: bool,
    pub allow_writes: bool,
    pub require_approval: bool,
}

impl McpServerConfig {
    pub fn ensure_storage_dir(&self) -> std::io::Result<()> {
        if !self.storage_path.exists() {
            std::fs::create_dir_all(&self.storage_path)?;
        }
        Ok(())
    }

    pub fn storage_path_as_string(&self) -> String {
        self.storage_path.to_string_lossy().to_string()
    }
}

impl Default for McpServerConfig {
    fn default() -> Self {
        Self {
            storage_path: PathBuf::from("./cheddarproxy_data"),
            auto_start_proxy: false,
            allow_writes: false,
            require_approval: true,
        }
    }
}

// ============================================================================
// Tool Parameter Types
// Using simple types that implement JsonSchema to avoid frb macro conflicts
// ============================================================================

/// Parameters for starting the proxy
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct ProxyStartParams {
    /// Port to listen on (default: 9090)
    #[serde(default)]
    pub port: Option<u16>,
    /// Address to bind to (default: 127.0.0.1)
    #[serde(default)]
    pub bind_address: Option<String>,
    /// Enable HTTPS interception (default: true)
    #[serde(default)]
    pub enable_https: Option<bool>,
    /// Automatically configure system proxy to route traffic through Cheddar Proxy (default: false)
    #[serde(rename = "enableSystemProxy", default)]
    pub enable_system_proxy: Option<bool>,
}

/// Parameters for querying transactions
/// Note: start_time is REQUIRED to prevent unbounded queries
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct TransactionsQueryParams {
    /// Start time for query range (REQUIRED). Use ISO 8601 format or "today" for current day.
    /// Transactions older than this will not be returned.
    #[serde(rename = "startTime")]
    pub start_time: Option<String>,
    /// End time for query range. Defaults to now if not specified.
    #[serde(rename = "endTime", default)]
    pub end_time: Option<String>,
    /// Filter by HTTP method (e.g., "GET", "POST")
    #[serde(default)]
    pub method: Option<String>,
    /// Filter by host containing this string
    #[serde(default)]
    pub host_contains: Option<String>,
    /// Filter by path containing this string  
    #[serde(default)]
    pub path_contains: Option<String>,
    /// Filter by minimum status code
    #[serde(default)]
    pub status_min: Option<u16>,
    /// Filter by maximum status code
    #[serde(default)]
    pub status_max: Option<u16>,
    /// Page number (0-indexed)
    #[serde(default)]
    pub page: Option<u32>,
    /// Number of items per page (max 100)
    #[serde(rename = "pageSize", default)]
    pub page_size: Option<u32>,
}

const MAX_PAGE_SIZE: u32 = 100;

impl TransactionsQueryParams {
    /// Parse start_time string into milliseconds timestamp
    fn parse_start_time(&self) -> Result<i64, String> {
        let start_str = self
            .start_time
            .as_ref()
            .ok_or_else(|| "startTime is required. Use ISO 8601 format (e.g., '2024-01-01T00:00:00Z') or 'today' for current day.".to_string())?;

        Self::parse_time_string(start_str)
    }

    /// Parse end_time string into milliseconds timestamp, defaults to now
    fn parse_end_time(&self) -> Result<i64, String> {
        match &self.end_time {
            Some(s) => Self::parse_time_string(s),
            None => {
                use std::time::{SystemTime, UNIX_EPOCH};
                Ok(SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as i64)
            }
        }
    }

    fn parse_time_string(s: &str) -> Result<i64, String> {
        use std::time::{SystemTime, UNIX_EPOCH};

        let lower = s.to_lowercase();
        if lower == "today" {
            // Start of current UTC day
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let day_start = (now / 86400) * 86400;
            return Ok((day_start * 1000) as i64);
        }
        if lower == "now" {
            return Ok(SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64);
        }

        // Try parsing as ISO 8601
        chrono::DateTime::parse_from_rfc3339(s)
            .map(|dt| dt.timestamp_millis())
            .map_err(|_| format!("Invalid time format '{}'. Use ISO 8601 (e.g., '2024-01-01T00:00:00Z') or 'today'", s))
    }

    fn to_filter(&self) -> Option<TransactionFilter> {
        use crate::models::HttpMethod;

        if self.method.is_none()
            && self.host_contains.is_none()
            && self.path_contains.is_none()
            && self.status_min.is_none()
            && self.status_max.is_none()
        {
            return None;
        }
        Some(TransactionFilter {
            method: self.method.as_ref().map(|m| {
                m.parse::<HttpMethod>()
                    .unwrap_or_else(|_| HttpMethod::from_str_lossy(m))
            }),
            host_contains: self.host_contains.clone(),
            path_contains: self.path_contains.clone(),
            status_min: self.status_min,
            status_max: self.status_max,
        })
    }
}

/// Parameters for fetching a transaction by ID
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct TransactionDetailParams {
    /// Transaction ID to fetch
    pub id: String,
}

/// Parameters for slow request queries
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct SlowRequestsParams {
    /// Only include requests slower than this threshold (ms)
    #[serde(rename = "thresholdMs", default)]
    pub threshold_ms: Option<u64>,
    /// Maximum number of results (max 500)
    #[serde(default)]
    pub limit: Option<u32>,
    /// Filter by HTTP method (optional)
    #[serde(default)]
    pub method: Option<String>,
    /// Filter by host substring (case-insensitive)
    #[serde(default)]
    pub host_contains: Option<String>,
    /// Filter by path substring (case-insensitive)
    #[serde(default)]
    pub path_contains: Option<String>,
    /// Minimum status code
    #[serde(default)]
    pub status_min: Option<u16>,
    /// Maximum status code
    #[serde(default)]
    pub status_max: Option<u16>,
}

impl SlowRequestsParams {
    fn to_filter(&self) -> Option<TransactionFilter> {
        use crate::models::HttpMethod;

        if self.method.is_none()
            && self.host_contains.is_none()
            && self.path_contains.is_none()
            && self.status_min.is_none()
            && self.status_max.is_none()
        {
            return None;
        }

        Some(TransactionFilter {
            method: self.method.as_ref().map(|m| {
                m.parse::<HttpMethod>()
                    .unwrap_or_else(|_| HttpMethod::from_str_lossy(m))
            }),
            host_contains: self.host_contains.clone(),
            path_contains: self.path_contains.clone(),
            status_min: self.status_min,
            status_max: self.status_max,
        })
    }
}

/// Parameters for adding a breakpoint rule
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct BreakpointAddParams {
    /// Enable the rule (default: true)
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// HTTP method to match (e.g., "GET", "POST") - optional
    #[serde(default)]
    pub method: Option<String>,
    /// Match requests where host contains this string
    #[serde(default)]
    pub host_contains: Option<String>,
    /// Match requests where path contains this string
    #[serde(default)]
    pub path_contains: Option<String>,
}

fn default_true() -> bool {
    true
}

impl BreakpointAddParams {
    fn to_input(&self) -> BreakpointRuleInput {
        use crate::models::HttpMethod;

        BreakpointRuleInput {
            enabled: self.enabled,
            method: self
                .method
                .as_ref()
                .and_then(|m| match m.to_uppercase().as_str() {
                    "GET" => Some(HttpMethod::Get),
                    "POST" => Some(HttpMethod::Post),
                    "PUT" => Some(HttpMethod::Put),
                    "DELETE" => Some(HttpMethod::Delete),
                    "PATCH" => Some(HttpMethod::Patch),
                    "HEAD" => Some(HttpMethod::Head),
                    "OPTIONS" => Some(HttpMethod::Options),
                    "CONNECT" => Some(HttpMethod::Connect),
                    "TRACE" => Some(HttpMethod::Trace),
                    _ => None,
                }),
            host_contains: self.host_contains.clone(),
            path_contains: self.path_contains.clone(),
        }
    }
}

/// Parameters for removing a breakpoint rule
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct BreakpointRemoveParams {
    /// ID of the breakpoint rule to remove
    pub id: String,
}

/// Parameters for resuming a breakpoint
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct BreakpointResumeParams {
    /// Transaction ID to resume
    #[serde(rename = "transactionId")]
    pub transaction_id: String,
    /// Optional: Override the HTTP method
    #[serde(default)]
    pub method: Option<String>,
    /// Optional: Override the request path
    #[serde(default)]
    pub path: Option<String>,
    /// Optional: Override headers (JSON object)
    #[serde(default)]
    pub headers: Option<std::collections::HashMap<String, String>>,
    /// Optional: Override request body (base64 encoded for binary)
    #[serde(default)]
    pub body: Option<String>,
}

impl BreakpointResumeParams {
    fn to_edit(&self) -> RequestEdit {
        use crate::models::HttpMethod;

        RequestEdit {
            method: self
                .method
                .as_ref()
                .and_then(|m| match m.to_uppercase().as_str() {
                    "GET" => Some(HttpMethod::Get),
                    "POST" => Some(HttpMethod::Post),
                    "PUT" => Some(HttpMethod::Put),
                    "DELETE" => Some(HttpMethod::Delete),
                    "PATCH" => Some(HttpMethod::Patch),
                    "HEAD" => Some(HttpMethod::Head),
                    "OPTIONS" => Some(HttpMethod::Options),
                    _ => None,
                }),
            path: self.path.clone(),
            headers: self.headers.clone(),
            body: self.body.as_ref().map(|b| b.as_bytes().to_vec()),
        }
    }
}

/// Parameters for aborting a breakpoint
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct BreakpointAbortParams {
    /// Transaction ID to abort
    #[serde(rename = "transactionId")]
    pub transaction_id: String,
    /// Reason for aborting (optional)
    #[serde(default)]
    pub reason: Option<String>,
}

/// Parameters for replaying a request
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct ReplayRequestParams {
    /// Transaction ID to replay
    pub id: String,
    /// Optional: Override the HTTP method
    #[serde(default)]
    pub method: Option<String>,
    /// Optional: Override the request path  
    #[serde(default)]
    pub path: Option<String>,
    /// Optional: Override headers (JSON object)
    #[serde(default)]
    pub headers: Option<std::collections::HashMap<String, String>>,
    /// Optional: Override request body
    #[serde(default)]
    pub body: Option<String>,
    /// Optional: Allow invalid TLS certificates (default: false)
    #[serde(default)]
    pub allow_insecure_tls: bool,
}

/// Parameters for HAR export
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct HarExportParams {
    /// File path to export HAR to
    pub path: String,
    // Filter could be added but requires simple types
}

/// Parameters for HAR import
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct HarImportParams {
    /// File path to import HAR from
    pub path: String,
}

/// Parameters for listing WebSocket connections
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct WebSocketConnectionsParams {
    /// Page number (0-indexed)
    #[serde(default)]
    pub page: Option<u32>,
    /// Number of items per page (max 100)
    #[serde(rename = "pageSize", default)]
    pub page_size: Option<u32>,
}

/// Parameters for querying WebSocket messages
#[derive(Debug, Clone, Deserialize, JsonSchema)]
pub struct WebSocketMessagesParams {
    /// Connection/Transaction ID of the WebSocket connection
    #[serde(rename = "connectionId")]
    pub connection_id: String,
    /// Maximum number of messages to return (default: 100, max: 1000)
    #[serde(default)]
    pub limit: Option<u32>,
    /// Offset for pagination (default: 0)
    #[serde(default)]
    pub offset: Option<u32>,
}

const MAX_WS_MESSAGE_LIMIT: u32 = 1000;

/// Parameters for list_domains tool
#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
pub struct ListDomainsParams {
    /// Maximum number of domains to return (default: 100, max: 500)
    #[serde(default)]
    pub limit: Option<u32>,
}

// ============================================================================
// Response Types (for outputSchema support)
// ============================================================================

use serde::Serialize;

/// Response from proxy_status tool
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProxyStatusResponse {
    /// Whether the proxy server is currently running
    pub is_running: bool,
    /// Port number the proxy is listening on
    pub port: u16,
    /// Bind address (e.g., "127.0.0.1")
    pub bind_address: String,
    /// Number of currently active connections
    pub active_connections: u32,
    /// Total number of requests processed
    pub total_requests: u64,
}

/// Response from system_status tool
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SystemStatusResponse {
    /// Certificate information
    pub certificate: CertificateInfo,
    /// Path where proxy data is stored
    pub storage_path: String,
}

/// Certificate information
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CertificateInfo {
    /// Common name of the root CA
    pub common_name: String,
    /// File path to the certificate
    pub path: String,
    /// Whether the certificate file exists
    pub installed: bool,
    /// Trust status: "trusted", "not_trusted", or "unknown"
    pub trust_status: String,
}

/// Response from server_stats tool
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatsResponse {
    /// Total number of captured transactions
    pub transactions: u64,
    /// Server version string
    pub version: String,
    /// Operating system
    pub os: String,
    /// CPU architecture
    pub arch: String,
}

/// Response from list_domains tool
#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct ListDomainsResponse {
    /// List of domains with request counts
    pub domains: Vec<DomainInfo>,
    /// Total number of unique domains
    pub total: usize,
}

/// Domain information
#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DomainInfo {
    /// Host/domain name
    pub host: String,
    /// Number of requests to this domain
    pub request_count: u64,
}

// ============================================================================
// Cheddar Proxy MCP Server Handler

/// Cheddar Proxy MCP Server - exposes proxy control and traffic inspection tools.
#[derive(Clone)]
pub struct CheddarProxyServer {
    config: Arc<McpServerConfig>,
    initialized: Arc<Mutex<bool>>,
    tool_router: ToolRouter<Self>,
}

impl CheddarProxyServer {
    pub fn new(config: McpServerConfig) -> Self {
        Self {
            config: Arc::new(config),
            initialized: Arc::new(Mutex::new(false)),
            tool_router: Self::tool_router(),
        }
    }

    /// Initialize the core subsystems.
    pub async fn bootstrap(&self) -> anyhow::Result<()> {
        self.config.ensure_storage_dir()?;
        proxy_api::init_core(Some(self.config.storage_path_as_string()))
            .map_err(|e| anyhow::anyhow!(e))?;

        // Always initialize the transaction store so queries work even without proxy running
        crate::storage::init_transaction_store(&self.config.storage_path_as_string())
            .map_err(|e| anyhow::anyhow!("Failed to initialize transaction store: {}", e))?;

        if self.config.auto_start_proxy {
            let mut proxy_config = proxy_api::create_default_config();
            proxy_config.storage_path = self.config.storage_path_as_string();
            proxy_api::start_proxy(proxy_config)
                .await
                .map_err(|e| anyhow::anyhow!(e))?;
        }

        *self.initialized.lock().await = true;
        tracing::info!(
            "Cheddar Proxy MCP server ready (storage: {})",
            self.config.storage_path.display()
        );
        Ok(())
    }

    fn ensure_write_allowed(&self, action: &str) -> Result<(), McpError> {
        if !self.config.allow_writes {
            return Err(McpError::invalid_request(
                "MCP server is in read-only mode. Enable writes to perform this action.",
                None,
            ));
        }
        if self.config.require_approval {
            let msg = format!(
                "Action '{}' requires approval. Disable 'Require approval for writes' or approve via UI.",
                action
            );
            return Err(McpError::invalid_request(msg, None));
        }
        Ok(())
    }
}

fn cert_status_to_str(status: CertTrustStatus) -> &'static str {
    match status {
        CertTrustStatus::Trusted => "trusted",
        CertTrustStatus::NotTrusted => "not_trusted",
        CertTrustStatus::Unknown => "unknown",
    }
}

// ============================================================================
// Tool Implementations
// ============================================================================

#[tool_router]
impl CheddarProxyServer {
    // ========================================================================
    // Proxy Control (Phase 1)
    // ========================================================================

    #[tool(
        description = "Get the current proxy server status including port, bind address, active connections, and total requests",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn proxy_status(&self) -> Result<Json<ProxyStatusResponse>, McpError> {
        let status = proxy_api::get_proxy_status();
        Ok(Json(ProxyStatusResponse {
            is_running: status.is_running,
            port: status.port,
            bind_address: status.bind_address,
            active_connections: status.active_connections,
            total_requests: status.total_requests,
        }))
    }

    #[tool(
        description = "Start the proxy server. Optionally enable system-wide proxy routing with enableSystemProxy parameter.",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn proxy_start(
        &self,
        params: Parameters<ProxyStartParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("proxy_start")?;
        let status = proxy_api::get_proxy_status();
        if status.is_running {
            let msg = format!(
                "Proxy already running on {}:{}",
                status.bind_address, status.port
            );
            return Ok(CallToolResult::success(vec![Content::text(msg)]));
        }

        let p = params.0;
        let mut config: ProxyConfig = proxy_api::create_default_config();
        config.port = p.port.unwrap_or(config.port);
        config.bind_address = p.bind_address.unwrap_or(config.bind_address);
        config.enable_https = p.enable_https.unwrap_or(config.enable_https);
        config.storage_path = self.config.storage_path_as_string();

        let port = config.port;
        let addr = config.bind_address.clone();
        let enable_system_proxy = p.enable_system_proxy.unwrap_or(false);

        proxy_api::start_proxy(config)
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to start proxy: {e}"), None))?;

        // Optionally configure system proxy
        let mut msg = format!("Proxy started on {}:{}", addr, port);
        if enable_system_proxy {
            if let Err(e) = proxy_api::enable_system_proxy(addr.clone(), port).await {
                msg.push_str(&format!(". Warning: Failed to enable system proxy: {}", e));
            } else {
                msg.push_str(". System proxy enabled.");
            }
        }

        Ok(CallToolResult::success(vec![Content::text(msg)]))
    }

    #[tool(
        description = "Stop the proxy server and disable system proxy settings",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn proxy_stop(&self) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("proxy_stop")?;
        let status = proxy_api::get_proxy_status();
        if !status.is_running {
            return Ok(CallToolResult::success(vec![Content::text(
                "Proxy already stopped".to_string(),
            )]));
        }
        // First disable system proxy to restore normal network routing
        let mut warnings = Vec::new();
        if let Err(e) = proxy_api::disable_system_proxy().await {
            warnings.push(format!("Warning: Failed to disable system proxy: {}", e));
        }

        // Then stop the proxy server
        proxy_api::stop_proxy()
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to stop proxy: {e}"), None))?;

        let mut msg = "Proxy stopped. System proxy disabled.".to_string();
        for w in warnings {
            msg.push_str(&format!(" {}", w));
        }
        Ok(CallToolResult::success(vec![Content::text(msg)]))
    }

    // ========================================================================
    // System Integration (Phase 1)
    // ========================================================================

    #[tool(
        description = "Get system proxy and certificate trust status",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn system_status(&self) -> Result<Json<SystemStatusResponse>, McpError> {
        let ca_path = self.config.storage_path.join("cheddar_proxy_ca.pem");
        let trust_status = platform::detect_certificate_trust(ROOT_CA_COMMON_NAME)
            .unwrap_or(CertTrustStatus::Unknown);

        Ok(Json(SystemStatusResponse {
            certificate: CertificateInfo {
                common_name: ROOT_CA_COMMON_NAME.to_string(),
                path: ca_path.to_string_lossy().to_string(),
                installed: ca_path.exists(),
                trust_status: cert_status_to_str(trust_status).to_string(),
            },
            storage_path: self.config.storage_path_as_string(),
        }))
    }

    #[tool(
        description = "Generate or retrieve the root CA certificate (PEM format) for HTTPS interception",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn install_certificate(&self) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("install_certificate")?;
        let storage_path = self.config.storage_path_as_string();

        proxy_api::ensure_root_ca(storage_path.clone()).map_err(|e| {
            McpError::internal_error(format!("Failed to ensure root CA: {e}"), None)
        })?;

        let pem = proxy_api::get_root_ca_pem(storage_path)
            .map_err(|e| McpError::internal_error(format!("Failed to read root CA: {e}"), None))?;

        Ok(CallToolResult::success(vec![Content::text(pem)]))
    }
    // ========================================================================
    // System & Stats
    // ========================================================================

    #[tool(
        description = "Get current server statistics including total transaction count, version, and uptime",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn server_stats(&self) -> Result<Json<ServerStatsResponse>, McpError> {
        let count = proxy_api::get_transaction_count()
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to get count: {e}"), None))?;

        Ok(Json(ServerStatsResponse {
            transactions: count,
            version: crate::VERSION.to_string(),
            os: std::env::consts::OS.to_string(),
            arch: std::env::consts::ARCH.to_string(),
        }))
    }

    // ========================================================================
    // Transaction Inspection (Phase 1)
    // ========================================================================

    #[tool(
        description = "Query captured HTTP transactions with time-bounded filtering. REQUIRES startTime parameter (ISO 8601 format or 'today'). Supports filtering by method, host, path, status codes, with pagination (max 100 per page).",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn transactions_list(
        &self,
        params: Parameters<TransactionsQueryParams>,
    ) -> Result<CallToolResult, McpError> {
        let p = params.0;

        // Validate required start_time
        let start_ms = p
            .parse_start_time()
            .map_err(|e| McpError::invalid_params(e, None))?;
        let end_ms = p
            .parse_end_time()
            .map_err(|e| McpError::invalid_params(e, None))?;

        let page = p.page.unwrap_or(0);
        let page_size = p.page_size.unwrap_or(50).min(MAX_PAGE_SIZE);
        let filter = p.to_filter();

        // Query with time bounds
        let result = proxy_api::query_transactions_with_time_range(
            filter, start_ms, end_ms, page, page_size,
        )
        .await
        .map_err(|e| {
            McpError::internal_error(format!("Failed to query transactions: {e}"), None)
        })?;

        let json = serde_json::to_string_pretty(&result).unwrap_or_default();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    #[tool(
        description = "Fetch a single transaction by ID including headers, bodies, and timing metadata.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn transaction_detail(
        &self,
        params: Parameters<TransactionDetailParams>,
    ) -> Result<CallToolResult, McpError> {
        let tx = proxy_api::get_transaction_detail(&params.0.id)
            .await
            .map_err(|e| {
                McpError::internal_error(format!("Failed to fetch transaction: {e}"), None)
            })?;

        let tx = tx.ok_or_else(|| McpError::invalid_params("Transaction not found", None))?;
        let json = serde_json::to_string_pretty(&tx).unwrap_or_default();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    #[tool(
        description = "Find the slowest requests (by total duration, descending). Supports optional thresholdMs, limit (max 500), and basic filters.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn performance_slow_requests(
        &self,
        params: Parameters<SlowRequestsParams>,
    ) -> Result<CallToolResult, McpError> {
        let p = params.0;
        let slow = proxy_api::get_slow_transactions(p.to_filter(), p.threshold_ms, p.limit)
            .await
            .map_err(|e| {
                McpError::internal_error(format!("Failed to query slow requests: {e}"), None)
            })?;

        let json = serde_json::to_string_pretty(&slow).unwrap_or_default();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    #[tool(
        description = "List unique domains/hosts contacted with request counts. Useful for privacy auditing to see what servers an app communicates with.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn list_domains(
        &self,
        params: Parameters<ListDomainsParams>,
    ) -> Result<Json<ListDomainsResponse>, McpError> {
        let capped_limit = params.0.limit.unwrap_or(100).clamp(1, 500);
        let hosts = crate::storage::list_unique_hosts(capped_limit)
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to list domains: {e}"), None))?;

        let domains: Vec<DomainInfo> = hosts
            .into_iter()
            .map(|(host, request_count)| DomainInfo {
                host,
                request_count,
            })
            .collect();
        let total = domains.len();

        Ok(Json(ListDomainsResponse { domains, total }))
    }

    // ========================================================================
    // Breakpoints (Phase 2)
    // ========================================================================

    #[tool(
        description = "List all active breakpoint rules that intercept matching requests",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn breakpoint_rules_list(&self) -> Result<CallToolResult, McpError> {
        let rules = breakpoints::list_breakpoint_rules();
        let json = serde_json::to_string_pretty(&rules).unwrap_or_default();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    #[tool(
        description = "Add a new breakpoint rule to intercept matching HTTP requests. Specify url_pattern, methods, and phase (request/response/both).",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn add_breakpoint_rule(
        &self,
        params: Parameters<BreakpointAddParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("add_breakpoint_rule")?;
        let input = params.0.to_input();
        let created = breakpoints::add_breakpoint_rule(input);
        let json = serde_json::to_string_pretty(&created).unwrap_or_default();
        Ok(CallToolResult::success(vec![Content::text(json)]))
    }

    #[tool(
        description = "Remove a breakpoint rule by its ID",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn remove_breakpoint_rule(
        &self,
        params: Parameters<BreakpointRemoveParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("remove_breakpoint_rule")?;
        let removed = breakpoints::remove_breakpoint_rule(&params.0.id);
        Ok(CallToolResult::success(vec![Content::text(format!(
            "Rule {} removed: {}",
            params.0.id, removed
        ))]))
    }

    #[tool(
        description = "Resume a request paused at a breakpoint. Optionally modify method, path, headers, or body.",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn resume_breakpoint(
        &self,
        params: Parameters<BreakpointResumeParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("resume_breakpoint")?;
        let p = params.0;
        let edit = p.to_edit();
        let has_edits = !edit.is_empty();

        breakpoints::resume_breakpoint(&p.transaction_id, edit).map_err(|e| {
            McpError::internal_error(format!("Failed to resume breakpoint: {e}"), None)
        })?;

        let msg = if has_edits {
            format!(
                "Breakpoint resumed with modifications for transaction {}",
                p.transaction_id
            )
        } else {
            format!("Breakpoint resumed for transaction {}", p.transaction_id)
        };
        Ok(CallToolResult::success(vec![Content::text(msg)]))
    }

    #[tool(
        description = "Abort a request paused at a breakpoint, preventing it from being sent",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn abort_breakpoint(
        &self,
        params: Parameters<BreakpointAbortParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("abort_breakpoint")?;
        let p = params.0;
        let reason = p.reason.unwrap_or_else(|| "Aborted via MCP".to_string());

        breakpoints::abort_breakpoint(&p.transaction_id, reason).map_err(|e| {
            McpError::internal_error(format!("Failed to abort breakpoint: {e}"), None)
        })?;

        Ok(CallToolResult::success(vec![Content::text(format!(
            "Breakpoint aborted for transaction {}",
            p.transaction_id
        ))]))
    }

    // ========================================================================
    // Request Replay
    // ========================================================================

    #[tool(
        description = "Replay a previously captured HTTP request. Returns the new transaction ID and response status.",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn replay_request(
        &self,
        params: Parameters<ReplayRequestParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("replay_request")?;
        use crate::models::HttpMethod;
        use crate::replay::{replay_request, ReplayParams};

        let p = params.0;

        // Convert method string to enum if provided
        let method = p
            .method
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

        let replay_params = ReplayParams {
            method,
            path: p.path,
            headers: p.headers,
            body: p.body.map(|s| s.into_bytes()),
            accept_invalid_certs: p.allow_insecure_tls,
        };

        let result = replay_request(&p.id, replay_params)
            .await
            .map_err(|e| McpError::internal_error(format!("Replay failed: {e}"), None))?;

        if result.success {
            Ok(CallToolResult::success(vec![Content::text(format!(
                "Request replayed successfully. New transaction ID: {}, Status: {}",
                result.transaction_id,
                result
                    .status_code
                    .map_or("pending".to_string(), |c| c.to_string())
            ))]))
        } else {
            Ok(CallToolResult::success(vec![Content::text(format!(
                "Request replay failed. Transaction ID: {}, Error: {}",
                result.transaction_id,
                result.error.unwrap_or_else(|| "Unknown error".to_string())
            ))]))
        }
    }

    // ========================================================================
    // HAR Export/Import (Phase 2)
    // ========================================================================

    #[tool(
        description = "Export captured transactions to a HAR (HTTP Archive) file at the specified path",
        annotations(read_only_hint = false, destructive_hint = false)
    )]
    async fn export_har(
        &self,
        params: Parameters<HarExportParams>,
    ) -> Result<CallToolResult, McpError> {
        let p = params.0;
        let count = proxy_api::export_har_file(p.path.clone(), None)
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to export HAR: {e}"), None))?;

        Ok(CallToolResult::success(vec![Content::text(format!(
            "Exported {} transactions to {}",
            count, p.path
        ))]))
    }

    #[tool(
        description = "Import transactions from a HAR (HTTP Archive) file at the specified path",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn import_har(
        &self,
        params: Parameters<HarImportParams>,
    ) -> Result<CallToolResult, McpError> {
        self.ensure_write_allowed("import_har")?;
        let p = params.0;
        let count = proxy_api::import_har_file(p.path.clone())
            .await
            .map_err(|e| McpError::internal_error(format!("Failed to import HAR: {e}"), None))?;

        Ok(CallToolResult::success(vec![Content::text(format!(
            "Imported {} transactions from {}",
            count, p.path
        ))]))
    }

    // ========================================================================
    // WebSocket Inspection
    // ========================================================================

    #[tool(
        description = "List all WebSocket connections. Returns transactions where is_websocket=true with connection metadata.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn websocket_connections_list(
        &self,
        params: Parameters<WebSocketConnectionsParams>,
    ) -> Result<CallToolResult, McpError> {
        let p = params.0;
        let page = p.page.unwrap_or(0);
        let page_size = p.page_size.unwrap_or(50).min(MAX_PAGE_SIZE);

        // Query WebSocket transactions from storage
        let connections = crate::storage::get_websocket_connections(page, page_size);

        let result = serde_json::json!({
            "connections": connections.iter().map(|tx| {
                serde_json::json!({
                    "id": tx.id,
                    "host": tx.host,
                    "path": tx.path,
                    "timestamp": tx.timestamp_ms,
                    "messageCount": crate::storage::get_websocket_message_count(&tx.id),
                })
            }).collect::<Vec<_>>(),
            "page": page,
            "pageSize": page_size,
            "total": connections.len(),
        });

        Ok(CallToolResult::success(vec![Content::text(
            serde_json::to_string_pretty(&result).unwrap_or_default(),
        )]))
    }

    #[tool(
        description = "Get WebSocket messages for a specific connection. Returns message direction, opcode, payload (text or base64 for binary), and timestamp.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn websocket_messages_list(
        &self,
        params: Parameters<WebSocketMessagesParams>,
    ) -> Result<CallToolResult, McpError> {
        let p = params.0;
        let limit = p.limit.unwrap_or(100).min(MAX_WS_MESSAGE_LIMIT);
        let offset = p.offset.unwrap_or(0);

        // Get all messages and apply pagination
        let all_messages = crate::storage::get_websocket_messages(&p.connection_id);
        let total = all_messages.len();
        let messages: Vec<_> = all_messages
            .into_iter()
            .skip(offset as usize)
            .take(limit as usize)
            .collect();

        use base64::Engine;
        let result = serde_json::json!({
            "connectionId": p.connection_id,
            "messages": messages.iter().map(|msg| {
                let payload_str = match msg.opcode {
                    crate::models::WebSocketOpcode::Text => {
                        String::from_utf8(msg.payload.clone()).unwrap_or_else(|_| {
                            base64::engine::general_purpose::STANDARD.encode(&msg.payload)
                        })
                    }
                    crate::models::WebSocketOpcode::Binary => {
                        format!("[binary:{}]", base64::engine::general_purpose::STANDARD.encode(&msg.payload))
                    }
                    _ => format!("[{}]", msg.opcode.to_string()),
                };
                serde_json::json!({
                    "direction": msg.direction.to_string(),
                    "opcode": msg.opcode.to_string(),
                    "payload": payload_str,
                    "payloadLength": msg.payload_length,
                    "timestamp": msg.timestamp,
                })
            }).collect::<Vec<_>>(),
            "offset": offset,
            "limit": limit,
            "total": total,
            "hasMore": (offset as usize + messages.len()) < total,
        });

        Ok(CallToolResult::success(vec![Content::text(
            serde_json::to_string_pretty(&result).unwrap_or_default(),
        )]))
    }

    #[tool(
        description = "Get the count of WebSocket messages for a specific connection.",
        annotations(read_only_hint = true, destructive_hint = false)
    )]
    async fn websocket_message_count(
        &self,
        params: Parameters<WebSocketMessagesParams>,
    ) -> Result<CallToolResult, McpError> {
        let count = crate::storage::get_websocket_message_count(&params.0.connection_id);

        let result = serde_json::json!({
            "connectionId": params.0.connection_id,
            "count": count,
        });

        Ok(CallToolResult::success(vec![Content::text(
            serde_json::to_string_pretty(&result).unwrap_or_default(),
        )]))
    }
}

// ============================================================================
// ServerHandler Implementation
// ============================================================================

impl ServerHandler for CheddarProxyServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            server_info: Implementation {
                name: "cheddarproxy".into(),
                version: crate::VERSION.into(),
                title: Some("Cheddar Proxy MCP Server".into()),
                icons: None,
                website_url: Some("https://github.com/aman-shahid/cheddarproxy".into()),
            },
            capabilities: ServerCapabilities::builder()
                .enable_tools()
                .enable_resources()
                .build(),
            instructions: Some(
                "Cheddar Proxy is a network traffic inspection tool. \
                 Use tools to query captured HTTP transactions, manage breakpoints, \
                 and control the proxy server. Resources provide read-only access \
                 to proxy status and transaction details."
                    .into(),
            ),
            ..Default::default()
        }
    }

    fn list_tools(
        &self,
        _request: Option<PaginatedRequestParam>,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ListToolsResult, McpError>> + Send + '_ {
        let tools = self.tool_router.list_all();
        std::future::ready(Ok(ListToolsResult {
            tools,
            ..Default::default()
        }))
    }

    #[allow(clippy::manual_async_fn)]
    fn call_tool(
        &self,
        request: CallToolRequestParam,
        context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<CallToolResult, McpError>> + Send + '_ {
        async move {
            let tool_context = ToolCallContext::new(self, request, context);
            self.tool_router.call(tool_context).await
        }
    }

    fn list_resources(
        &self,
        _request: Option<PaginatedRequestParam>,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ListResourcesResult, McpError>> + Send + '_ {
        use rmcp::model::{Annotated, RawResource};

        std::future::ready(Ok(ListResourcesResult {
            resources: vec![
                Annotated {
                    raw: RawResource {
                        uri: "proxy://status".into(),
                        name: "Proxy Status".into(),
                        title: None,
                        description: Some("Current proxy server status including port, connections, and request count".into()),
                        mime_type: Some("application/json".into()),
                        size: None,
                        icons: None,
                        meta: None,
                    },
                    annotations: None,
                },
                Annotated {
                    raw: RawResource {
                        uri: "proxy://certificate".into(),
                        name: "Certificate Status".into(),
                        title: None,
                        description: Some("Root CA certificate status and trust information".into()),
                        mime_type: Some("application/json".into()),
                        size: None,
                        icons: None,
                        meta: None,
                    },
                    annotations: None,
                },
            ],
            ..Default::default()
        }))
    }

    fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParam>,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ListResourceTemplatesResult, McpError>> + Send + '_
    {
        use rmcp::model::{Annotated, RawResourceTemplate};

        std::future::ready(Ok(ListResourceTemplatesResult {
            resource_templates: vec![Annotated {
                raw: RawResourceTemplate {
                    uri_template: "proxy://transaction/{id}".into(),
                    name: "Transaction Detail".into(),
                    title: None,
                    description: Some("Full details of a captured HTTP transaction by ID".into()),
                    mime_type: Some("application/json".into()),
                },
                annotations: None,
            }],
            ..Default::default()
        }))
    }

    fn read_resource(
        &self,
        request: ReadResourceRequestParam,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ReadResourceResult, McpError>> + Send + '_ {
        let config = self.config.clone();
        async move {
            let uri = request.uri.as_str();

            if uri == "proxy://status" {
                let status = proxy_api::get_proxy_status();
                let json = serde_json::json!({
                    "isRunning": status.is_running,
                    "port": status.port,
                    "bindAddress": status.bind_address,
                    "activeConnections": status.active_connections,
                    "totalRequests": status.total_requests,
                });
                return Ok(ReadResourceResult {
                    contents: vec![ResourceContents::text(
                        serde_json::to_string_pretty(&json).unwrap_or_default(),
                        uri,
                    )],
                });
            }

            if uri == "proxy://certificate" {
                let ca_path = config.storage_path.join("cheddar_proxy_ca.pem");
                let trust_status = platform::detect_certificate_trust(ROOT_CA_COMMON_NAME)
                    .unwrap_or(CertTrustStatus::Unknown);
                let json = serde_json::json!({
                    "commonName": ROOT_CA_COMMON_NAME,
                    "path": ca_path.to_string_lossy(),
                    "installed": ca_path.exists(),
                    "trustStatus": cert_status_to_str(trust_status),
                });
                return Ok(ReadResourceResult {
                    contents: vec![ResourceContents::text(
                        serde_json::to_string_pretty(&json).unwrap_or_default(),
                        uri,
                    )],
                });
            }

            // Handle transaction/{id} pattern
            if let Some(id) = uri.strip_prefix("proxy://transaction/") {
                let tx = proxy_api::get_transaction_detail(id).await.map_err(|e| {
                    McpError::internal_error(format!("Failed to fetch transaction: {e}"), None)
                })?;

                let tx =
                    tx.ok_or_else(|| McpError::invalid_params("Transaction not found", None))?;
                let json = serde_json::to_string_pretty(&tx).unwrap_or_default();
                return Ok(ReadResourceResult {
                    contents: vec![ResourceContents::text(json, uri)],
                });
            }

            Err(McpError::invalid_params(
                format!("Unknown resource URI: {}", uri),
                None,
            ))
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_default() {
        let config = McpServerConfig::default();
        assert_eq!(config.storage_path, PathBuf::from("./cheddarproxy_data"));
        assert!(!config.auto_start_proxy);
    }

    #[test]
    fn test_transactions_query_params_to_filter() {
        use crate::models::HttpMethod;

        let params = TransactionsQueryParams {
            method: Some("GET".into()),
            host_contains: Some("example.com".into()),
            ..Default::default()
        };
        let filter = params.to_filter().unwrap();
        assert_eq!(filter.method, Some(HttpMethod::Get));
        assert_eq!(filter.host_contains, Some("example.com".into()));
    }
}
