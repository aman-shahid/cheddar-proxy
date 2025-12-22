//! MCP (Model Context Protocol) adapter scaffolding.
//!
//! This module provides an MCP server implementation using the official rmcp SDK.
//! The server exposes tools and resources for controlling the proxy and inspecting traffic.

pub mod auth;
pub mod manager;
pub mod sdk_server;

// Re-export SDK server types for convenience
pub use sdk_server::{CheddarProxyServer, McpServerConfig};
