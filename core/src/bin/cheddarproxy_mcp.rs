//! Standalone MCP server binary for Cheddar Proxy.
//!
//! This binary runs the MCP server over stdio, suitable for integration with
//! Claude Desktop, Cursor, and other MCP-compatible clients.
//!
//! Usage:
//! ```
//! cargo run -p rust_lib_cheddarproxy --bin cheddarproxy_mcp -- --storage-path ./cheddarproxy_data
//! ```

use std::path::PathBuf;

use rmcp::ServiceExt;
use rust_lib_cheddarproxy::mcp::{CheddarProxyServer, McpServerConfig};
use tokio::io::{stdin, stdout};
use tracing::level_filters::LevelFilter;
use tracing_subscriber::FmtSubscriber;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let config = parse_args();

    tracing::info!("Starting Cheddar Proxy MCP server (rmcp SDK)");

    // Create and bootstrap the server
    let server = CheddarProxyServer::new(config);
    server.bootstrap().await?;

    // Create stdio transport (stdin, stdout) and serve
    let transport = (stdin(), stdout());
    let service = server.serve(transport).await?;

    // Wait for the service to complete
    service.waiting().await?;

    Ok(())
}

fn init_tracing() {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(LevelFilter::INFO)
        .with_writer(std::io::stderr) // Write logs to stderr, not stdout (stdout is for MCP)
        .finish();
    let _ = tracing::subscriber::set_global_default(subscriber);
}

fn parse_args() -> McpServerConfig {
    let mut args = std::env::args().skip(1);
    let mut storage_path = PathBuf::from("./cheddarproxy_data");
    let mut auto_start_proxy = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--storage-path" => {
                if let Some(path) = args.next() {
                    storage_path = PathBuf::from(path);
                }
            }
            "--auto-start-proxy" => {
                auto_start_proxy = true;
            }
            "--help" | "-h" => {
                eprintln!("Cheddar Proxy MCP Server");
                eprintln!();
                eprintln!("Usage: cheddarproxy_mcp [OPTIONS]");
                eprintln!();
                eprintln!("Options:");
                eprintln!("  --storage-path <PATH>   Storage path for data/certs (default: ./cheddarproxy_data)");
                eprintln!("  --auto-start-proxy      Auto-start proxy on server init");
                eprintln!("  --help, -h              Show this help");
                eprintln!();
                eprintln!("Implementation: rmcp SDK (MCP spec 2025-11-25)");
                std::process::exit(0);
            }
            _ => {
                eprintln!("Unknown argument: {arg}");
            }
        }
    }

    McpServerConfig {
        storage_path,
        auto_start_proxy,
        allow_writes: false,
        require_approval: true,
    }
}
