//! WebSocket message models
//!
//! Represents WebSocket frames captured by the proxy.

use chrono::Utc;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

/// WebSocket frame opcode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[frb]
pub enum WebSocketOpcode {
    /// Continuation frame
    Continuation,
    /// Text frame (UTF-8 encoded)
    Text,
    /// Binary frame
    Binary,
    /// Connection close frame
    Close,
    /// Ping frame
    Ping,
    /// Pong frame
    Pong,
}

impl WebSocketOpcode {
    /// Parse from raw opcode byte
    pub fn from_u8(opcode: u8) -> Option<Self> {
        match opcode & 0x0F {
            0 => Some(WebSocketOpcode::Continuation),
            1 => Some(WebSocketOpcode::Text),
            2 => Some(WebSocketOpcode::Binary),
            8 => Some(WebSocketOpcode::Close),
            9 => Some(WebSocketOpcode::Ping),
            10 => Some(WebSocketOpcode::Pong),
            _ => None,
        }
    }

    /// Convert to string representation
    pub fn as_str(&self) -> &'static str {
        match self {
            WebSocketOpcode::Continuation => "CONTINUATION",
            WebSocketOpcode::Text => "TEXT",
            WebSocketOpcode::Binary => "BINARY",
            WebSocketOpcode::Close => "CLOSE",
            WebSocketOpcode::Ping => "PING",
            WebSocketOpcode::Pong => "PONG",
        }
    }

    #[frb(sync)]
    pub fn to_string(&self) -> String {
        self.as_str().to_string()
    }
}

/// Direction of a WebSocket message
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[frb]
pub enum MessageDirection {
    /// Client to server (request)
    ClientToServer,
    /// Server to client (response)
    ServerToClient,
}

impl MessageDirection {
    pub fn as_str(&self) -> &'static str {
        match self {
            MessageDirection::ClientToServer => "→",
            MessageDirection::ServerToClient => "←",
        }
    }

    #[frb(sync)]
    pub fn to_string(&self) -> String {
        self.as_str().to_string()
    }
}

/// Represents a single WebSocket message/frame
#[derive(Debug, Clone, Serialize, Deserialize)]
#[frb]
pub struct WebSocketMessage {
    /// Unique identifier for this message
    pub id: String,

    /// ID of the parent HTTP transaction (the upgrade request)
    pub connection_id: String,

    /// Direction of the message
    pub direction: MessageDirection,

    /// Frame opcode
    pub opcode: WebSocketOpcode,

    /// Message payload (raw bytes)
    pub payload: Vec<u8>,

    /// Payload length in bytes
    pub payload_length: u64,

    /// Timestamp when the message was captured
    pub timestamp: i64,

    /// Whether this is a fragmented frame
    pub is_fragmented: bool,

    /// Whether this is the final frame in a message
    pub is_final: bool,
}

impl WebSocketMessage {
    /// Create a new WebSocket message
    pub fn new(
        connection_id: String,
        direction: MessageDirection,
        opcode: WebSocketOpcode,
        payload: Vec<u8>,
        is_final: bool,
    ) -> Self {
        let payload_length = payload.len() as u64;
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            connection_id,
            direction,
            opcode,
            payload,
            payload_length,
            timestamp: Utc::now().timestamp_millis(),
            is_fragmented: false,
            is_final,
        }
    }

    /// Get payload as UTF-8 string (for text frames)
    #[frb(sync)]
    pub fn payload_as_string(&self) -> Option<String> {
        if self.opcode == WebSocketOpcode::Text {
            String::from_utf8(self.payload.clone()).ok()
        } else {
            None
        }
    }

    /// Get a preview of the payload (first 100 chars/bytes)
    #[frb(sync)]
    pub fn payload_preview(&self) -> String {
        match self.opcode {
            WebSocketOpcode::Text => {
                if let Ok(text) = String::from_utf8(self.payload.clone()) {
                    if text.len() > 100 {
                        format!("{}...", &text[..100])
                    } else {
                        text
                    }
                } else {
                    format!("[Binary: {} bytes]", self.payload_length)
                }
            }
            WebSocketOpcode::Binary => {
                format!("[Binary: {} bytes]", self.payload_length)
            }
            WebSocketOpcode::Close => {
                if self.payload.len() >= 2 {
                    let code = u16::from_be_bytes([self.payload[0], self.payload[1]]);
                    let reason = if self.payload.len() > 2 {
                        String::from_utf8_lossy(&self.payload[2..]).to_string()
                    } else {
                        String::new()
                    };
                    format!("Close: {} {}", code, reason)
                } else {
                    "Close".to_string()
                }
            }
            WebSocketOpcode::Ping => "Ping".to_string(),
            WebSocketOpcode::Pong => "Pong".to_string(),
            WebSocketOpcode::Continuation => {
                format!("[Continuation: {} bytes]", self.payload_length)
            }
        }
    }

    /// Get payload size as formatted string
    #[frb(sync)]
    pub fn size_str(&self) -> String {
        let size = self.payload_length;
        if size < 1024 {
            format!("{}B", size)
        } else if size < 1024 * 1024 {
            format!("{:.1}KB", size as f64 / 1024.0)
        } else {
            format!("{:.1}MB", size as f64 / (1024.0 * 1024.0))
        }
    }
}
