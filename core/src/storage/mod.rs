//! Transaction storage and pagination

mod har;
mod transaction_store;
mod websocket_store;

pub use websocket_store::*;

use crate::models::{HttpTransaction, PaginatedTransactions, TransactionFilter};
use once_cell::sync::Lazy;
use std::sync::{Arc, Mutex};
use transaction_store::TransactionStore;

static STORE: Lazy<Mutex<Option<Arc<TransactionStore>>>> = Lazy::new(|| Mutex::new(None));
const DEFAULT_RING_SIZE: usize = 10_000;
const DEFAULT_PRUNE_DAYS: u32 = 5;

/// Initialize the global transaction store if not already present
pub fn init_transaction_store(storage_path: &str) -> anyhow::Result<()> {
    let mut guard = STORE
        .lock()
        .map_err(|e| anyhow::anyhow!("lock poisoned: {}", e))?;
    if guard.is_some() {
        return Ok(());
    }
    let store = Arc::new(TransactionStore::new(storage_path, DEFAULT_RING_SIZE)?);
    *guard = Some(store);
    Ok(())
}

/// Reset the store for testing purposes. This allows tests to re-initialize
/// with a fresh storage path.
#[cfg(test)]
pub fn reset_store_for_tests(storage_path: &str) -> anyhow::Result<()> {
    let mut guard = STORE
        .lock()
        .map_err(|e| anyhow::anyhow!("lock poisoned: {}", e))?;
    // Drop the old store (if any)
    *guard = None;
    // Initialize with the new path
    let store = Arc::new(TransactionStore::new(storage_path, DEFAULT_RING_SIZE)?);
    *guard = Some(store);
    Ok(())
}

/// Initialize the store and run auto-prune (call this on app startup)
pub async fn init_and_prune(storage_path: &str, prune_days: Option<u32>) -> anyhow::Result<u64> {
    init_transaction_store(storage_path)?;
    let days = prune_days.unwrap_or(DEFAULT_PRUNE_DAYS);
    prune_older_than(days).await
}

fn store() -> anyhow::Result<Arc<TransactionStore>> {
    let guard = STORE
        .lock()
        .map_err(|e| anyhow::anyhow!("lock poisoned: {}", e))?;
    guard
        .clone()
        .ok_or_else(|| anyhow::anyhow!("transaction store not initialized"))
}

/// Persist a completed transaction to the ring buffer and SQLite
pub async fn persist_transaction(tx: HttpTransaction) -> anyhow::Result<()> {
    if let Ok(store) = store() {
        store.add_transaction(tx).await
    } else {
        Ok(())
    }
}

/// Query transactions using pagination and optional filters
pub async fn query_transactions(
    filter: &TransactionFilter,
    page: u32,
    page_size: u32,
) -> anyhow::Result<PaginatedTransactions> {
    let store = store()?;
    store.query(filter, page, page_size).await
}

/// Query transactions with time range bounds (start_time_ms and end_time_ms are Unix timestamps in milliseconds)
pub async fn query_transactions_with_time_range(
    filter: &TransactionFilter,
    start_time_ms: i64,
    end_time_ms: i64,
    page: u32,
    page_size: u32,
) -> anyhow::Result<PaginatedTransactions> {
    let store = store()?;
    store
        .query_with_time_range(filter, start_time_ms, end_time_ms, page, page_size)
        .await
}

/// List all transactions that match the filter without pagination (used for exports).
pub async fn list_transactions(filter: &TransactionFilter) -> anyhow::Result<Vec<HttpTransaction>> {
    let store = store()?;
    store.list(filter).await
}

/// List recent transactions up to a limit (ordered by started_at DESC).
pub async fn list_recent_transactions(limit: u32) -> anyhow::Result<Vec<HttpTransaction>> {
    let store = store()?;
    store.list_recent(limit).await
}

/// List a page of transactions older than the given started_at (ms) threshold.
pub async fn list_transactions_page(
    before_started_at_ms: Option<i64>,
    limit: u32,
) -> anyhow::Result<Vec<HttpTransaction>> {
    let store = store()?;
    store.list_page(before_started_at_ms, limit).await
}

/// Get a single transaction by ID
pub async fn get_transaction_by_id(id: &str) -> anyhow::Result<Option<HttpTransaction>> {
    let store = store()?;
    store.get_by_id(id).await
}

/// Delete transactions older than the specified number of days
pub async fn prune_older_than(days: u32) -> anyhow::Result<u64> {
    let store = store()?;
    store.prune_older_than(days).await
}

/// Delete all transactions from both memory and database
pub async fn clear_all_transactions() -> anyhow::Result<u64> {
    let store = store()?;
    store.clear_all().await
}

/// Fetch slowest transactions ordered by total duration (descending).
pub async fn slowest_transactions(
    filter: &TransactionFilter,
    threshold_ms: Option<u64>,
    limit: u32,
) -> anyhow::Result<Vec<HttpTransaction>> {
    let store = store()?;
    store.slowest_by_duration(filter, threshold_ms, limit).await
}

/// Get the total count of transactions in the database
pub async fn get_transaction_count() -> anyhow::Result<u64> {
    let store = store()?;
    store.count().await
}

/// Get unique hosts with request counts, sorted by count descending
pub async fn list_unique_hosts(limit: u32) -> anyhow::Result<Vec<(String, u64)>> {
    let store = store()?;
    store.list_unique_hosts(limit).await
}

pub use har::{export_har_to_path, import_har_from_path, import_har_from_str, transactions_to_har};
pub use transaction_store::TransactionFilterExt;
