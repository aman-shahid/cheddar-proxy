//! HTTP Transaction model
//!
//! Represents a single HTTP request/response pair captured by the proxy.

use chrono::Utc;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// HTTP methods
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[frb]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Patch,
    Delete,
    Head,
    Options,
    Connect,
    Trace,
}

impl HttpMethod {
    /// Convert from string (lossy, defaults to GET)
    pub fn from_str_lossy(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "GET" => HttpMethod::Get,
            "POST" => HttpMethod::Post,
            "PUT" => HttpMethod::Put,
            "PATCH" => HttpMethod::Patch,
            "DELETE" => HttpMethod::Delete,
            "HEAD" => HttpMethod::Head,
            "OPTIONS" => HttpMethod::Options,
            "CONNECT" => HttpMethod::Connect,
            "TRACE" => HttpMethod::Trace,
            _ => HttpMethod::Get,
        }
    }

    /// Convert to string
    #[frb(sync)]
    pub fn to_string(&self) -> String {
        match self {
            HttpMethod::Get => "GET".to_string(),
            HttpMethod::Post => "POST".to_string(),
            HttpMethod::Put => "PUT".to_string(),
            HttpMethod::Patch => "PATCH".to_string(),
            HttpMethod::Delete => "DELETE".to_string(),
            HttpMethod::Head => "HEAD".to_string(),
            HttpMethod::Options => "OPTIONS".to_string(),
            HttpMethod::Connect => "CONNECT".to_string(),
            HttpMethod::Trace => "TRACE".to_string(),
        }
    }
}

impl std::str::FromStr for HttpMethod {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(HttpMethod::from_str_lossy(s))
    }
}

/// State of an HTTP transaction
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[frb]
pub enum TransactionState {
    /// Request is being sent
    Pending,
    /// Request completed successfully
    Completed,
    /// Request failed with an error
    Failed,
    /// Request is paused at a breakpoint
    Breakpointed,
}

/// Timing information for an HTTP transaction
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct TransactionTiming {
    /// When the request started
    pub start_time: i64, // milliseconds since epoch
    /// DNS lookup duration in ms
    pub dns_lookup_ms: Option<u32>,
    /// TCP connection duration in ms
    pub tcp_connect_ms: Option<u32>,
    /// TLS handshake duration in ms
    pub tls_handshake_ms: Option<u32>,
    /// Request send duration in ms
    pub request_send_ms: Option<u32>,
    /// Time to first byte (waiting) in ms
    pub waiting_ms: Option<u32>,
    /// Content download duration in ms
    pub content_download_ms: Option<u32>,
    /// Total duration in ms
    pub total_ms: Option<u32>,
}

impl Default for TransactionTiming {
    fn default() -> Self {
        Self {
            start_time: Utc::now().timestamp_millis(),
            dns_lookup_ms: None,
            tcp_connect_ms: None,
            tls_handshake_ms: None,
            request_send_ms: None,
            waiting_ms: None,
            content_download_ms: None,
            total_ms: None,
        }
    }
}

/// Represents a single HTTP request/response transaction
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct HttpTransaction {
    /// Unique identifier for this transaction
    pub id: String,

    /// HTTP method
    pub method: HttpMethod,

    /// Request scheme (http or https)
    pub scheme: String,

    /// Host name
    pub host: String,

    /// Port number
    pub port: u16,

    /// Request path (including query string)
    pub path: String,

    /// HTTP version (e.g., "HTTP/1.1")
    pub http_version: String,

    /// Current state of the transaction
    pub state: TransactionState,

    // Request data
    /// Request headers
    pub request_headers: HashMap<String, String>,
    /// Request body (if any)
    pub request_body: Option<Vec<u8>>,
    /// Request content type
    pub request_content_type: Option<String>,

    // Response data
    /// HTTP status code
    pub status_code: Option<u16>,
    /// HTTP status message
    pub status_message: Option<String>,
    /// Response headers
    pub response_headers: Option<HashMap<String, String>>,
    /// Response body (if any)
    pub response_body: Option<Vec<u8>>,
    /// Response content type
    pub response_content_type: Option<String>,

    // Metadata
    /// Timing information
    pub timing: TransactionTiming,
    /// Response size in bytes
    pub response_size: Option<u64>,
    /// Whether this transaction has a breakpoint
    pub has_breakpoint: bool,
    /// Notes or tags for this transaction
    pub notes: Option<String>,

    // Connection metadata
    /// Server IP address (resolved from DNS)
    pub server_ip: Option<String>,
    /// TLS protocol version (e.g., "TLS 1.3")
    pub tls_version: Option<String>,
    /// TLS cipher suite (e.g., "TLS_AES_256_GCM_SHA384")
    pub tls_cipher: Option<String>,
    /// Whether an existing connection was reused (keep-alive)
    pub connection_reused: bool,
    /// HTTP/2 stream identifier (if applicable)
    pub stream_id: Option<u32>,
    /// Whether this is a WebSocket upgrade connection
    pub is_websocket: bool,
}

/// Filter options for querying or streaming transactions
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[frb]
pub struct TransactionFilter {
    /// Match a specific HTTP method
    pub method: Option<HttpMethod>,
    /// Case-insensitive host substring
    pub host_contains: Option<String>,
    /// Case-insensitive path substring
    pub path_contains: Option<String>,
    /// Minimum HTTP status (inclusive)
    pub status_min: Option<u16>,
    /// Maximum HTTP status (inclusive)
    pub status_max: Option<u16>,
}

/// Paginated response returned to Flutter
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct PaginatedTransactions {
    pub total: u64,
    pub page: u32,
    pub page_size: u32,
    pub items: Vec<HttpTransaction>,
}

impl HttpTransaction {
    /// Create a new transaction for an incoming request
    pub fn new(
        method: HttpMethod,
        scheme: &str,
        host: &str,
        port: u16,
        path: &str,
        headers: HashMap<String, String>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            method,
            scheme: scheme.to_string(),
            host: host.to_string(),
            port,
            path: path.to_string(),
            http_version: "HTTP/1.1".to_string(),
            state: TransactionState::Pending,
            request_headers: headers,
            request_body: None,
            request_content_type: None,
            status_code: None,
            status_message: None,
            response_headers: None,
            response_body: None,
            response_content_type: None,
            timing: TransactionTiming::default(),
            response_size: None,
            has_breakpoint: false,
            notes: None,
            server_ip: None,
            tls_version: None,
            tls_cipher: None,
            connection_reused: false,
            stream_id: None,
            is_websocket: false,
        }
    }

    /// Get the full URL
    #[frb(sync)]
    pub fn full_url(&self) -> String {
        let port_str = if (self.scheme == "https" && self.port == 443)
            || (self.scheme == "http" && self.port == 80)
        {
            String::new()
        } else {
            format!(":{}", self.port)
        };
        format!("{}://{}{}{}", self.scheme, self.host, port_str, self.path)
    }

    /// Get duration as formatted string
    #[frb(sync)]
    pub fn duration_str(&self) -> String {
        match self.timing.total_ms {
            Some(ms) if ms < 1000 => format!("{}ms", ms),
            Some(ms) => format!("{:.1}s", ms as f64 / 1000.0),
            None => "-".to_string(),
        }
    }

    /// Get size as formatted string
    #[frb(sync)]
    pub fn size_str(&self) -> String {
        match self.response_size {
            Some(size) if size < 1024 => format!("{}B", size),
            Some(size) if size < 1024 * 1024 => format!("{:.1}KB", size as f64 / 1024.0),
            Some(size) => format!("{:.1}MB", size as f64 / (1024.0 * 1024.0)),
            None => "-".to_string(),
        }
    }
}
