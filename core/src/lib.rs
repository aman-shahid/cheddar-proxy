//! # Cheddar Proxy Core
#![allow(unexpected_cfgs)]

//! High-performance network traffic inspection engine for the Cheddar Proxy application.
//! Built with Rust for speed and reliability.
//!
//! ## Features
//!
//! - HTTP/HTTPS proxy with traffic interception
//! - TLS decryption via dynamic CA certificates
//! - Traffic storage and querying
//! - Request/response breakpoints
//! - Export to HAR, cURL, etc.
//!
//! ## Architecture
//!
//! ```text
//! ┌─────────────────────────────────────────────────────────┐
//! │                    Flutter UI (Dart)                     │
//! ├─────────────────────────────────────────────────────────┤
//! │               flutter_rust_bridge (FFI)                  │
//! ├─────────────────────────────────────────────────────────┤
//! │                 Cheddar Proxy Core (Rust)                 │
//! │  ┌─────────┐  ┌──────────┐  ┌────────┐  ┌───────────┐   │
//! │  │  Proxy  │  │   TLS    │  │ Parser │  │  Storage  │   │
//! │  │ Server  │──│ Handler  │──│        │──│ (SQLite)  │   │
//! │  └─────────┘  └──────────┘  └────────┘  └───────────┘   │
//! └─────────────────────────────────────────────────────────┘
//! ```

mod frb_generated;

// Public modules
pub mod api;
pub mod mcp;
pub mod models;
pub mod platform;
pub mod proxy;
pub mod replay;
pub mod storage;

/// Library version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
