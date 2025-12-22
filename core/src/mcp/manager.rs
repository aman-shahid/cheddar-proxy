//! MCP Runtime Manager
//!
//! Manages the lifecycle of the MCP server (start, stop, status).
//! Uses the rmcp SDK for MCP protocol implementation.

use std::path::{Path, PathBuf};

use anyhow::Result;
use once_cell::sync::Lazy;
use tokio::sync::broadcast;
use tokio::sync::Mutex;

use crate::mcp::auth::McpAuthTokenManager;
use crate::mcp::{CheddarProxyServer, McpServerConfig};

#[derive(Debug, Clone)]
pub struct McpRuntimeConfig {
    pub storage_path: PathBuf,
    pub auto_start_proxy: bool,
    pub socket_path: Option<PathBuf>,
    pub allow_writes: bool,
    pub require_approval: bool,
}

impl McpRuntimeConfig {
    pub fn socket_path(&self) -> PathBuf {
        self.socket_path
            .clone()
            .unwrap_or_else(|| self.storage_path.join("cheddarproxy_mcp.sock"))
    }
}

#[derive(Debug, Clone)]
pub struct McpRuntimeStatus {
    pub is_running: bool,
    pub socket_path: Option<String>,
    pub last_error: Option<String>,
    pub allow_writes: bool,
    pub require_approval: bool,
}

impl Default for McpRuntimeStatus {
    fn default() -> Self {
        Self {
            is_running: false,
            socket_path: None,
            last_error: None,
            allow_writes: false,
            require_approval: true,
        }
    }
}

#[cfg(unix)]
mod platform_runtime {
    use super::*;
    use anyhow::anyhow;
    use rmcp::ServiceExt;
    use std::fs;
    use tokio::net::UnixListener;
    use tokio::sync::oneshot;
    use tokio::task::JoinHandle;

    struct RuntimeHandle {
        task: JoinHandle<()>,
        shutdown: Option<oneshot::Sender<()>>,
        socket_path: PathBuf,
        config: McpRuntimeConfig,
    }

    static RUNTIME: Lazy<Mutex<Option<RuntimeHandle>>> = Lazy::new(|| Mutex::new(None));
    static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
    static TOKEN_ROTATION_TX: Lazy<broadcast::Sender<()>> = Lazy::new(|| broadcast::channel(8).0);

    pub(super) fn subscribe_token_rotated() -> broadcast::Receiver<()> {
        TOKEN_ROTATION_TX.subscribe()
    }

    pub(super) fn notify_token_rotated() {
        let _ = TOKEN_ROTATION_TX.send(());
    }

    pub(super) async fn start_runtime(config: McpRuntimeConfig) -> Result<McpRuntimeStatus> {
        let mut guard = RUNTIME.lock().await;
        if guard.is_some() {
            tracing::info!("MCP runtime already running; returning current status");
            return Ok(current_status_locked().await);
        }

        config.storage_path.as_path().ensure_dir()?;
        McpAuthTokenManager::new(config.storage_path.clone())
            .ensure_token()
            .map_err(|e| anyhow!("Failed to initialize MCP token: {e}"))?;
        let socket_path = config.socket_path();
        if socket_path.exists() {
            let _ = fs::remove_file(&socket_path);
        }

        tracing::info!(
            "Binding MCP Unix socket at {} (auto_start_proxy={})",
            socket_path.display(),
            config.auto_start_proxy
        );

        let listener = UnixListener::bind(&socket_path)?;

        let server_config = McpServerConfig {
            storage_path: config.storage_path.clone(),
            auto_start_proxy: config.auto_start_proxy,
            allow_writes: config.allow_writes,
            require_approval: config.require_approval,
        };
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let socket_path_for_task = socket_path.clone();

        let task = tokio::spawn(async move {
            if let Err(err) =
                run_socket_listener(listener, server_config, shutdown_rx, socket_path_for_task)
                    .await
            {
                tracing::error!("MCP socket server error: {err}");
                let mut last_error = LAST_ERROR.lock().await;
                *last_error = Some(err.to_string());
            }
        });

        *guard = Some(RuntimeHandle {
            task,
            shutdown: Some(shutdown_tx),
            socket_path: socket_path.clone(),
            config: config.clone(),
        });

        // Register with local MCP discovery
        if let Err(e) = register_discovery_manifest(&socket_path) {
            tracing::warn!("Failed to write MCP discovery manifest: {}", e);
        } else {
            tracing::info!("Registered MCP server in discovery directory");
        }

        drop(guard);
        Ok(current_status_locked().await)
    }

    pub(super) async fn stop_runtime() -> Result<McpRuntimeStatus> {
        let mut guard = RUNTIME.lock().await;
        if let Some(handle) = guard.take() {
            tracing::info!(
                "Stopping MCP runtime (socket={})",
                handle.socket_path.display()
            );

            // Unregister from discovery
            unregister_discovery_manifest();

            if let Some(tx) = handle.shutdown {
                let _ = tx.send(());
            }
            if let Err(err) = handle.task.await {
                tracing::warn!("Failed to await MCP runtime task: {err}");
            }
            if handle.socket_path.exists() {
                let _ = std::fs::remove_file(&handle.socket_path);
            }
        }
        drop(guard);
        Ok(current_status_locked().await)
    }

    // --- Discovery Helpers ---

    fn get_discovery_dir() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("mcp").join("servers"))
    }

    fn register_discovery_manifest(socket_path: &Path) -> Result<()> {
        let dir = get_discovery_dir().ok_or_else(|| anyhow!("Could not determine config dir"))?;
        std::fs::create_dir_all(&dir)?;

        let manifest = serde_json::json!({
            "name": "cheddarproxy",
            "version": crate::VERSION,
            "protocolVersion": "2025-11-25",
            "description": "Network traffic inspection proxy",
            "transport": "unix",
            "socket": socket_path.to_string_lossy(),
            "pid": std::process::id(),
            "started_at": chrono::Utc::now().to_rfc3339(),
            "capabilities": {
                "tools": { "listChanged": true },
                "resources": { "subscribe": false, "listChanged": false },
                "prompts": {}
            },
            "instructions": "Cheddar Proxy is a network traffic inspection tool. Use tools to query captured HTTP transactions, manage breakpoints, and control the proxy server. Resources provide read-only access to proxy status and transaction details.",
            "auth": {
                "type": "bearer",
                "required": true
            }
        });

        let path = dir.join("cheddarproxy.json");
        let f = std::fs::File::create(path)?;
        serde_json::to_writer_pretty(f, &manifest)?;
        Ok(())
    }

    fn unregister_discovery_manifest() {
        if let Some(dir) = get_discovery_dir() {
            let path = dir.join("cheddarproxy.json");
            if path.exists() {
                if let Err(e) = std::fs::remove_file(&path) {
                    tracing::warn!("Failed to remove MCP manifest: {}", e);
                }
            }
        }
    }

    pub(super) async fn current_status() -> McpRuntimeStatus {
        current_status_locked().await
    }

    async fn current_status_locked() -> McpRuntimeStatus {
        let runtime = RUNTIME.lock().await;
        let last_error = LAST_ERROR.lock().await;
        McpRuntimeStatus {
            is_running: runtime.is_some(),
            socket_path: runtime
                .as_ref()
                .map(|handle| handle.socket_path.to_string_lossy().to_string()),
            last_error: last_error.clone(),
            allow_writes: runtime
                .as_ref()
                .map(|handle| handle.config.allow_writes)
                .unwrap_or(false),
            require_approval: runtime
                .as_ref()
                .map(|handle| handle.config.require_approval)
                .unwrap_or(true),
        }
    }

    async fn run_socket_listener(
        listener: UnixListener,
        config: McpServerConfig,
        mut shutdown: oneshot::Receiver<()>,
        socket_path: PathBuf,
    ) -> Result<()> {
        tracing::info!(
            "MCP socket listener running (socket={}, auto_start_proxy={})",
            socket_path.display(),
            config.auto_start_proxy
        );

        // Create and bootstrap the server once
        let server = CheddarProxyServer::new(config);
        server.bootstrap().await?;

        loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => {
                    tracing::info!("MCP socket runtime shutting down");
                    break;
                }
                accept_result = listener.accept() => {
                    match accept_result {
                        Ok((stream, _addr)) => {
                            // Split the stream into read/write halves for rmcp
                            let (reader, writer) = tokio::io::split(stream);
                            let transport = (reader, writer);

                            // Clone server for this connection
                            let session_server = server.clone();

                            tokio::spawn(async move {
                                match session_server.serve(transport).await {
                                    Ok(service) => {
                                        if let Err(err) = service.waiting().await {
                                            tracing::warn!("MCP SDK session ended with error: {err}");
                                        }
                                    }
                                    Err(err) => {
                                        tracing::warn!("Failed to start MCP SDK session: {err}");
                                    }
                                }
                            });
                        }
                        Err(err) => {
                            tracing::error!("MCP listener error: {err}");
                            break;
                        }
                    }
                }
            }
        }

        if socket_path.exists() {
            let _ = std::fs::remove_file(&socket_path);
        }
        Ok(())
    }

    trait EnsureDir {
        fn ensure_dir(&self) -> Result<()>;
    }

    impl EnsureDir for Path {
        fn ensure_dir(&self) -> Result<()> {
            if !self.exists() {
                std::fs::create_dir_all(self)?;
            }
            Ok(())
        }
    }
}

#[cfg(windows)]
mod platform_runtime {
    use super::*;
    use anyhow::anyhow;
    use rmcp::ServiceExt;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;
    use tokio::task::JoinHandle;

    struct RuntimeHandle {
        task: JoinHandle<()>,
        shutdown: Option<oneshot::Sender<()>>,
        addr: SocketAddr,
        config: McpRuntimeConfig,
    }

    static RUNTIME: Lazy<Mutex<Option<RuntimeHandle>>> = Lazy::new(|| Mutex::new(None));
    static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
    static TOKEN_ROTATION_TX: Lazy<broadcast::Sender<()>> = Lazy::new(|| broadcast::channel(8).0);

    pub(super) fn subscribe_token_rotated() -> broadcast::Receiver<()> {
        TOKEN_ROTATION_TX.subscribe()
    }

    pub(super) fn notify_token_rotated() {
        let _ = TOKEN_ROTATION_TX.send(());
    }

    pub(super) async fn start_runtime(config: McpRuntimeConfig) -> Result<McpRuntimeStatus> {
        let mut guard = RUNTIME.lock().await;
        if guard.is_some() {
            tracing::info!("MCP runtime already running; returning current status");
            return Ok(current_status_locked().await);
        }

        config.storage_path.as_path().ensure_dir()?;
        McpAuthTokenManager::new(config.storage_path.clone())
            .ensure_token()
            .map_err(|e| anyhow!("Failed to initialize MCP token: {e}"))?;

        let listener = TcpListener::bind((IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).await?;
        let addr = listener.local_addr()?;

        tracing::info!(
            "Binding MCP TCP listener at {} (auto_start_proxy={})",
            addr,
            config.auto_start_proxy
        );

        let server_config = McpServerConfig {
            storage_path: config.storage_path.clone(),
            auto_start_proxy: config.auto_start_proxy,
            allow_writes: config.allow_writes,
            require_approval: config.require_approval,
        };
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let addr_for_task = addr;

        let task = tokio::spawn(async move {
            if let Err(err) =
                run_socket_listener(listener, server_config, shutdown_rx, addr_for_task).await
            {
                tracing::error!("MCP TCP server error: {err}");
                let mut last_error = LAST_ERROR.lock().await;
                *last_error = Some(err.to_string());
            }
        });

        *guard = Some(RuntimeHandle {
            task,
            shutdown: Some(shutdown_tx),
            addr,
            config: config.clone(),
        });

        drop(guard);
        Ok(current_status_locked().await)
    }

    pub(super) async fn stop_runtime() -> Result<McpRuntimeStatus> {
        let mut guard = RUNTIME.lock().await;
        if let Some(handle) = guard.take() {
            tracing::info!("Stopping MCP runtime (addr={})", handle.addr);

            if let Some(tx) = handle.shutdown {
                let _ = tx.send(());
            }
            if let Err(err) = handle.task.await {
                tracing::warn!("Failed to await MCP runtime task: {err}");
            }
        }
        drop(guard);
        Ok(current_status_locked().await)
    }

    pub(super) async fn current_status() -> McpRuntimeStatus {
        current_status_locked().await
    }

    async fn current_status_locked() -> McpRuntimeStatus {
        let runtime = RUNTIME.lock().await;
        let last_error = LAST_ERROR.lock().await;
        McpRuntimeStatus {
            is_running: runtime.is_some(),
            socket_path: runtime
                .as_ref()
                .map(|handle| format!("tcp://{}", handle.addr)),
            last_error: last_error.clone(),
            allow_writes: runtime
                .as_ref()
                .map(|handle| handle.config.allow_writes)
                .unwrap_or(false),
            require_approval: runtime
                .as_ref()
                .map(|handle| handle.config.require_approval)
                .unwrap_or(true),
        }
    }

    async fn run_socket_listener(
        listener: TcpListener,
        config: McpServerConfig,
        mut shutdown: oneshot::Receiver<()>,
        addr: SocketAddr,
    ) -> Result<()> {
        tracing::info!(
            "MCP TCP listener running (addr={}, auto_start_proxy={})",
            addr,
            config.auto_start_proxy
        );

        let server = CheddarProxyServer::new(config);
        server.bootstrap().await?;

        loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => {
                    tracing::info!("MCP TCP runtime shutting down");
                    break;
                }
                accept_result = listener.accept() => {
                    match accept_result {
                        Ok((stream, peer)) => {
                            tracing::debug!("Accepted MCP TCP connection from {}", peer);
                            let (reader, writer) = tokio::io::split(stream);
                            let transport = (reader, writer);
                            let session_server = server.clone();

                            tokio::spawn(async move {
                                match session_server.serve(transport).await {
                                    Ok(service) => {
                                        if let Err(err) = service.waiting().await {
                                            tracing::warn!("MCP SDK session ended with error: {err}");
                                        }
                                    }
                                    Err(err) => {
                                        tracing::warn!("Failed to start MCP SDK session: {err}");
                                    }
                                }
                            });
                        }
                        Err(err) => {
                            tracing::error!("MCP listener error: {err}");
                            break;
                        }
                    }
                }
            }
        }

        Ok(())
    }

    trait EnsureDir {
        fn ensure_dir(&self) -> Result<()>;
    }

    impl EnsureDir for Path {
        fn ensure_dir(&self) -> Result<()> {
            if !self.exists() {
                std::fs::create_dir_all(self)?;
            }
            Ok(())
        }
    }
}

#[cfg(all(not(unix), not(windows)))]
mod platform_runtime {
    use super::*;

    pub(super) async fn start_runtime(_config: McpRuntimeConfig) -> Result<McpRuntimeStatus> {
        Err(anyhow::anyhow!(
            "MCP server toggle is currently supported only on Unix/Windows platforms"
        ))
    }

    pub(super) async fn stop_runtime() -> Result<McpRuntimeStatus> {
        Ok(McpRuntimeStatus::default())
    }

    pub(super) async fn current_status() -> McpRuntimeStatus {
        McpRuntimeStatus::default()
    }

    pub(super) fn subscribe_token_rotated() -> tokio::sync::broadcast::Receiver<()> {
        let (tx, rx) = tokio::sync::broadcast::channel(1);
        let _ = tx; // unused
        rx
    }

    pub(super) fn notify_token_rotated() {
        // no-op on non-unix
    }
}

pub async fn start_runtime(config: McpRuntimeConfig) -> Result<McpRuntimeStatus> {
    platform_runtime::start_runtime(config).await
}

pub async fn stop_runtime() -> Result<McpRuntimeStatus> {
    platform_runtime::stop_runtime().await
}

pub async fn current_status() -> McpRuntimeStatus {
    platform_runtime::current_status().await
}

pub fn subscribe_token_rotated() -> tokio::sync::broadcast::Receiver<()> {
    platform_runtime::subscribe_token_rotated()
}

pub fn notify_token_rotated() {
    platform_runtime::notify_token_rotated();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn windows_runtime_reports_tcp_endpoint() {
        let storage = tempfile::tempdir().unwrap();
        let config = McpRuntimeConfig {
            storage_path: storage.path().to_path_buf(),
            auto_start_proxy: false,
            socket_path: None,
            allow_writes: false,
            require_approval: true,
        };

        let status = start_runtime(config).await.expect("start runtime");
        assert!(status.is_running);
        let path = status.socket_path.expect("tcp endpoint present");
        assert!(path.starts_with("tcp://127.0.0.1:"));

        let stopped = stop_runtime().await.expect("stop runtime");
        assert!(!stopped.is_running);
    }
}
