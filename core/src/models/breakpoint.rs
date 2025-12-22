//! Models related to breakpoints and request editing.

use crate::models::HttpMethod;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Input payload for creating or updating breakpoint rules.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct BreakpointRuleInput {
    pub enabled: bool,
    pub method: Option<HttpMethod>,
    pub host_contains: Option<String>,
    pub path_contains: Option<String>,
}

impl Default for BreakpointRuleInput {
    fn default() -> Self {
        Self {
            enabled: true,
            method: None,
            host_contains: None,
            path_contains: None,
        }
    }
}

/// Breakpoint rule stored on the backend.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct BreakpointRule {
    pub id: String,
    pub enabled: bool,
    pub method: Option<HttpMethod>,
    pub host_contains: Option<String>,
    pub path_contains: Option<String>,
}

/// Request edits applied when resuming a breakpoint.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[frb]
pub struct RequestEdit {
    pub method: Option<HttpMethod>,
    pub path: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub body: Option<Vec<u8>>,
}

impl RequestEdit {
    pub fn is_empty(&self) -> bool {
        self.method.is_none()
            && self.path.is_none()
            && self.headers.is_none()
            && self.body.is_none()
    }
}
