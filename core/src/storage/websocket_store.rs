//! WebSocket message storage
//!
//! Simple in-memory ring buffer for WebSocket messages.
//! Messages are stored per-connection and can be queried by connection_id.

use crate::models::WebSocketMessage;
use once_cell::sync::Lazy;
use std::collections::{HashMap, VecDeque};
use std::sync::RwLock;

/// Maximum messages to store per connection
const MAX_MESSAGES_PER_CONNECTION: usize = 1000;

/// Maximum number of connections to track
const MAX_CONNECTIONS: usize = 100;

/// Global WebSocket message store
static WS_STORE: Lazy<RwLock<WebSocketStore>> = Lazy::new(|| RwLock::new(WebSocketStore::new()));

/// In-memory store for WebSocket messages
struct WebSocketStore {
    /// Messages indexed by connection_id
    messages: HashMap<String, VecDeque<WebSocketMessage>>,
    /// Order of connections for LRU eviction
    connection_order: VecDeque<String>,
}

impl WebSocketStore {
    fn new() -> Self {
        Self {
            messages: HashMap::new(),
            connection_order: VecDeque::new(),
        }
    }

    fn add_message(&mut self, msg: WebSocketMessage) {
        let conn_id = msg.connection_id.clone();

        // Get or create the message queue for this connection
        if !self.messages.contains_key(&conn_id) {
            // Evict oldest connection if we're at capacity
            if self.connection_order.len() >= MAX_CONNECTIONS {
                if let Some(old_conn) = self.connection_order.pop_front() {
                    self.messages.remove(&old_conn);
                }
            }
            self.messages.insert(conn_id.clone(), VecDeque::new());
            self.connection_order.push_back(conn_id.clone());
        }

        // Add message to the queue
        if let Some(queue) = self.messages.get_mut(&conn_id) {
            // Evict oldest message if at capacity
            if queue.len() >= MAX_MESSAGES_PER_CONNECTION {
                queue.pop_front();
            }
            queue.push_back(msg);
        }
    }

    fn get_messages(&self, connection_id: &str) -> Vec<WebSocketMessage> {
        self.messages
            .get(connection_id)
            .map(|q| q.iter().cloned().collect())
            .unwrap_or_default()
    }

    fn get_message_count(&self, connection_id: &str) -> usize {
        self.messages
            .get(connection_id)
            .map(|q| q.len())
            .unwrap_or(0)
    }

    fn clear_connection(&mut self, connection_id: &str) {
        self.messages.remove(connection_id);
        self.connection_order.retain(|c| c != connection_id);
    }

    fn clear_all(&mut self) {
        self.messages.clear();
        self.connection_order.clear();
    }
}

/// Add a WebSocket message to the store
pub fn add_websocket_message(msg: WebSocketMessage) {
    if let Ok(mut store) = WS_STORE.write() {
        store.add_message(msg);
    }
}

/// Get all messages for a WebSocket connection
pub fn get_websocket_messages(connection_id: &str) -> Vec<WebSocketMessage> {
    if let Ok(store) = WS_STORE.read() {
        store.get_messages(connection_id)
    } else {
        Vec::new()
    }
}

/// Get the count of messages for a connection
pub fn get_websocket_message_count(connection_id: &str) -> usize {
    if let Ok(store) = WS_STORE.read() {
        store.get_message_count(connection_id)
    } else {
        0
    }
}

/// WebSocket connection summary info
#[derive(Debug, Clone)]
pub struct WebSocketConnectionInfo {
    pub id: String,
    pub host: String,
    pub path: String,
    pub timestamp_ms: i64,
}

/// Get all active WebSocket connection IDs with pagination
pub fn get_websocket_connections(page: u32, page_size: u32) -> Vec<WebSocketConnectionInfo> {
    if let Ok(store) = WS_STORE.read() {
        let connections: Vec<_> = store.connection_order.iter().cloned().collect();
        let start = (page * page_size) as usize;
        connections
            .into_iter()
            .skip(start)
            .take(page_size as usize)
            .map(|id| {
                // Extract host/path from connection_id if formatted as "host:port/path"
                // For now, use the ID itself as both host and path since we don't store metadata
                WebSocketConnectionInfo {
                    id: id.clone(),
                    host: id.split('/').next().unwrap_or(&id).to_string(),
                    path: id.split('/').skip(1).collect::<Vec<_>>().join("/"),
                    timestamp_ms: std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_millis() as i64)
                        .unwrap_or(0),
                }
            })
            .collect()
    } else {
        Vec::new()
    }
}

/// Clear all messages for a connection
pub fn clear_websocket_messages(connection_id: &str) {
    if let Ok(mut store) = WS_STORE.write() {
        store.clear_connection(connection_id);
    }
}

/// Clear all WebSocket messages
pub fn clear_all_websocket_messages() {
    if let Ok(mut store) = WS_STORE.write() {
        store.clear_all();
    }
}
