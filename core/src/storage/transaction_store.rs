use crate::models::{HttpTransaction, PaginatedTransactions, TransactionFilter};
use anyhow::Context;
use rusqlite::types::Value;
use rusqlite::{params, Connection};
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::RwLock;

pub trait TransactionFilterExt {
    fn matches(&self, tx: &HttpTransaction) -> bool;
}

impl TransactionFilterExt for TransactionFilter {
    fn matches(&self, tx: &HttpTransaction) -> bool {
        if let Some(method) = self.method {
            if tx.method != method {
                return false;
            }
        }
        if let Some(host) = &self.host_contains {
            if !tx
                .host
                .to_ascii_lowercase()
                .contains(&host.to_ascii_lowercase())
            {
                return false;
            }
        }
        if let Some(path) = &self.path_contains {
            if !tx
                .path
                .to_ascii_lowercase()
                .contains(&path.to_ascii_lowercase())
            {
                return false;
            }
        }
        if let Some(min) = self.status_min {
            if tx.status_code.unwrap_or(0) < min {
                return false;
            }
        }
        if let Some(max) = self.status_max {
            if tx.status_code.unwrap_or(0) > max {
                return false;
            }
        }
        true
    }
}

pub struct TransactionStore {
    ring: RwLock<VecDeque<HttpTransaction>>,
    max_len: usize,
    db: Arc<Mutex<Connection>>,
    db_path: PathBuf,
}

impl TransactionStore {
    pub fn new(base_path: &str, max_len: usize) -> anyhow::Result<Self> {
        let dir = Path::new(base_path);
        if !dir.exists() {
            fs::create_dir_all(dir)
                .with_context(|| format!("creating storage directory {:?}", dir))?;
        }
        let db_path = dir.join("cheddarproxy_traffic.sqlite");
        let conn = Connection::open(&db_path)
            .with_context(|| format!("opening database at {:?}", db_path))?;
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS transactions (
                id TEXT PRIMARY KEY,
                started_at INTEGER,
                method TEXT,
                host TEXT,
                path TEXT,
                status INTEGER,
                data TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_transactions_started_at
                ON transactions(started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_transactions_host
                ON transactions(host);
            CREATE INDEX IF NOT EXISTS idx_transactions_status
                ON transactions(status);
            ",
        )?;

        Ok(Self {
            ring: RwLock::new(VecDeque::with_capacity(max_len)),
            max_len,
            db: Arc::new(Mutex::new(conn)),
            db_path,
        })
    }

    pub async fn add_transaction(&self, tx: HttpTransaction) -> anyhow::Result<()> {
        {
            let mut ring = self.ring.write().await;
            ring.push_back(tx.clone());
            while ring.len() > self.max_len {
                ring.pop_front();
            }
        }

        let db = Arc::clone(&self.db);
        let payload = serde_json::to_string(&tx)?;
        tokio::task::spawn_blocking(move || {
            let started_at = tx.timing.start_time;
            let method = tx.method.to_string();
            let host = tx.host.clone();
            let path = tx.path.clone();
            let status = tx.status_code.map(|s| s as i64);

            let conn = db.lock().expect("db mutex poisoned");
            conn.execute(
                "INSERT OR REPLACE INTO transactions
                   (id, started_at, method, host, path, status, data)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![tx.id, started_at, method, host, path, status, payload],
            )
            .context("inserting transaction")
        })
        .await??;

        Ok(())
    }

    pub async fn query(
        &self,
        filter: &TransactionFilter,
        page: u32,
        page_size: u32,
    ) -> anyhow::Result<PaginatedTransactions> {
        let offset = page as i64 * page_size as i64;
        let (clause, params) = self.build_where_clause(filter);
        let db = Arc::clone(&self.db);

        let (items, total) = tokio::task::spawn_blocking(move || {
            let conn = db.lock().expect("db mutex poisoned");

            let count_sql = format!("SELECT COUNT(*) FROM transactions {}", clause);
            let mut count_stmt = conn.prepare(&count_sql)?;
            let count_params = params.clone();
            let total: u64 = count_stmt
                .query_row(rusqlite::params_from_iter(count_params.iter()), |row| {
                    row.get::<_, i64>(0)
                })?
                .max(0) as u64;

            let mut query_params = params;
            let limit_val = page_size as i64;
            query_params.push(Value::from(limit_val));
            query_params.push(Value::from(offset));

            let sql = format!(
                "SELECT data FROM transactions {} ORDER BY started_at DESC LIMIT ? OFFSET ?",
                clause
            );
            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query(rusqlite::params_from_iter(query_params.iter()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok::<_, anyhow::Error>((out, total))
        })
        .await??;

        Ok(PaginatedTransactions {
            total,
            page,
            page_size,
            items,
        })
    }

    /// Query transactions with time range bounds
    pub async fn query_with_time_range(
        &self,
        filter: &TransactionFilter,
        start_time_ms: i64,
        end_time_ms: i64,
        page: u32,
        page_size: u32,
    ) -> anyhow::Result<PaginatedTransactions> {
        let offset = page as i64 * page_size as i64;
        let (base_clause, mut params) = self.build_where_clause(filter);

        // Add time bounds
        let time_conditions = if base_clause.is_empty() {
            "WHERE started_at >= ? AND started_at <= ?".to_string()
        } else {
            format!("{} AND started_at >= ? AND started_at <= ?", base_clause)
        };
        params.push(Value::from(start_time_ms));
        params.push(Value::from(end_time_ms));

        let db = Arc::clone(&self.db);
        let clause = time_conditions;

        let (items, total) = tokio::task::spawn_blocking(move || {
            let conn = db.lock().expect("db mutex poisoned");

            let count_sql = format!("SELECT COUNT(*) FROM transactions {}", clause);
            let mut count_stmt = conn.prepare(&count_sql)?;
            let count_params = params.clone();
            let total: u64 = count_stmt
                .query_row(rusqlite::params_from_iter(count_params.iter()), |row| {
                    row.get::<_, i64>(0)
                })?
                .max(0) as u64;

            let mut query_params = params;
            let limit_val = page_size as i64;
            query_params.push(Value::from(limit_val));
            query_params.push(Value::from(offset));

            let sql = format!(
                "SELECT data FROM transactions {} ORDER BY started_at DESC LIMIT ? OFFSET ?",
                clause
            );
            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query(rusqlite::params_from_iter(query_params.iter()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok::<_, anyhow::Error>((out, total))
        })
        .await??;

        Ok(PaginatedTransactions {
            total,
            page,
            page_size,
            items,
        })
    }

    pub async fn list(&self, filter: &TransactionFilter) -> anyhow::Result<Vec<HttpTransaction>> {
        let (clause, params) = self.build_where_clause(filter);
        let db = Arc::clone(&self.db);
        let rows = tokio::task::spawn_blocking(move || {
            let conn = db.lock().expect("db mutex poisoned");
            let sql = format!(
                "SELECT data FROM transactions {} ORDER BY started_at DESC",
                clause
            );
            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query(rusqlite::params_from_iter(params.iter()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok::<_, anyhow::Error>(out)
        })
        .await??;

        Ok(rows)
    }

    /// List recent transactions up to a limit (ordered by started_at DESC)
    pub async fn list_recent(&self, limit: u32) -> anyhow::Result<Vec<HttpTransaction>> {
        let db = Arc::clone(&self.db);
        let capped_limit = limit.clamp(1, 10_000) as i64;
        let rows = tokio::task::spawn_blocking(move || {
            let conn = db.lock().expect("db mutex poisoned");
            let sql = "SELECT data FROM transactions ORDER BY started_at DESC LIMIT ?";
            let mut stmt = conn.prepare(sql)?;
            let mut rows = stmt.query(rusqlite::params![capped_limit])?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok::<_, anyhow::Error>(out)
        })
        .await??;

        Ok(rows)
    }

    /// List transactions older than the given timestamp (ms) up to a limit.
    pub async fn list_page(
        &self,
        before_started_at_ms: Option<i64>,
        limit: u32,
    ) -> anyhow::Result<Vec<HttpTransaction>> {
        let db = Arc::clone(&self.db);
        let capped_limit = limit.clamp(1, 10_000) as i64;
        let rows = tokio::task::spawn_blocking(move || {
            let conn = db.lock().expect("db mutex poisoned");
            let mut params: Vec<rusqlite::types::Value> = Vec::new();
            let where_clause = if let Some(before) = before_started_at_ms {
                params.push(rusqlite::types::Value::from(before));
                "WHERE started_at < ?".to_string()
            } else {
                String::new()
            };
            params.push(rusqlite::types::Value::from(capped_limit));
            let sql = format!(
                "SELECT data FROM transactions {} ORDER BY started_at DESC LIMIT ?",
                where_clause
            );
            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query(rusqlite::params_from_iter(params.iter()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok::<_, anyhow::Error>(out)
        })
        .await??;

        Ok(rows)
    }

    /// Fetch the slowest transactions by total duration (descending).
    /// Optional threshold_ms filters out fast transactions; limit caps the result size.
    pub async fn slowest_by_duration(
        &self,
        filter: &TransactionFilter,
        threshold_ms: Option<u64>,
        limit: u32,
    ) -> anyhow::Result<Vec<HttpTransaction>> {
        let (base_clause, mut params) = self.build_where_clause(filter);

        let duration_condition =
            "json_extract(data, '$.timing.total_ms') IS NOT NULL AND json_extract(data, '$.timing.total_ms') > 0";
        let where_clause = if base_clause.is_empty() {
            format!("WHERE {}", duration_condition)
        } else {
            format!("{} AND {}", base_clause, duration_condition)
        };

        if let Some(threshold) = threshold_ms {
            params.push(Value::from(threshold as i64));
        }

        let mut query_params = params.clone();
        let mut clause_with_threshold = where_clause.clone();
        if threshold_ms.is_some() {
            clause_with_threshold.push_str(" AND json_extract(data, '$.timing.total_ms') >= ?");
        }

        let db = Arc::clone(&self.db);
        let capped_limit = limit.clamp(1, 500) as i64;

        let results = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<HttpTransaction>> {
            let conn = db.lock().expect("db mutex poisoned");

            query_params.push(Value::from(capped_limit));

            let sql = format!(
                "SELECT data FROM transactions {} ORDER BY json_extract(data, '$.timing.total_ms') DESC LIMIT ?",
                clause_with_threshold
            );

            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query(rusqlite::params_from_iter(query_params.iter()))?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let data: String = row.get(0)?;
                let tx: HttpTransaction = serde_json::from_str(&data)?;
                out.push(tx);
            }
            Ok(out)
        })
        .await??;

        Ok(results)
    }

    /// Get a transaction by ID, first checking ring buffer then database
    pub async fn get_by_id(&self, id: &str) -> anyhow::Result<Option<HttpTransaction>> {
        // First check the ring buffer for faster access
        {
            let ring = self.ring.read().await;
            if let Some(tx) = ring.iter().find(|tx| tx.id == id) {
                return Ok(Some(tx.clone()));
            }
        }

        // Fall back to database
        let db = Arc::clone(&self.db);
        let id_owned = id.to_string();
        let result =
            tokio::task::spawn_blocking(move || -> anyhow::Result<Option<HttpTransaction>> {
                let conn = db.lock().expect("db mutex poisoned");
                let mut stmt = conn.prepare("SELECT data FROM transactions WHERE id = ?")?;
                let mut rows = stmt.query(params![id_owned])?;
                if let Some(row) = rows.next()? {
                    let data: String = row.get(0)?;
                    let tx: HttpTransaction = serde_json::from_str(&data)?;
                    Ok(Some(tx))
                } else {
                    Ok(None)
                }
            })
            .await??;

        Ok(result)
    }

    fn build_where_clause(&self, filter: &TransactionFilter) -> (String, Vec<Value>) {
        let mut clauses = Vec::new();
        let mut params = Vec::new();

        if let Some(method) = filter.method {
            clauses.push("method = ?".to_string());
            params.push(Value::from(method.to_string()));
        }
        if let Some(host) = &filter.host_contains {
            clauses.push("LOWER(host) LIKE ?".to_string());
            params.push(Value::from(format!("%{}%", host.to_ascii_lowercase())));
        }
        if let Some(path) = &filter.path_contains {
            clauses.push("LOWER(path) LIKE ?".to_string());
            params.push(Value::from(format!("%{}%", path.to_ascii_lowercase())));
        }
        if let Some(min) = filter.status_min {
            clauses.push("status >= ?".to_string());
            params.push(Value::from(min as i64));
        }
        if let Some(max) = filter.status_max {
            clauses.push("status <= ?".to_string());
            params.push(Value::from(max as i64));
        }

        let clause = if clauses.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", clauses.join(" AND "))
        };
        (clause, params)
    }

    /// Delete transactions older than the specified number of days and reclaim space
    pub async fn prune_older_than(&self, days: u32) -> anyhow::Result<u64> {
        let db = Arc::clone(&self.db);
        let cutoff_ms = {
            use std::time::{SystemTime, UNIX_EPOCH};
            let now_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_millis() as i64;
            now_ms - (days as i64 * 24 * 60 * 60 * 1000)
        };

        let deleted = tokio::task::spawn_blocking(move || -> anyhow::Result<u64> {
            let conn = db.lock().expect("db mutex poisoned");
            let count = conn.execute(
                "DELETE FROM transactions WHERE started_at < ?1",
                params![cutoff_ms],
            )?;
            if count > 0 {
                // Reclaim disk space after deleting rows
                conn.execute_batch("VACUUM")?;
            }
            Ok(count as u64)
        })
        .await??;

        if deleted > 0 {
            tracing::info!("Pruned {} transactions older than {} days", deleted, days);
        }

        Ok(deleted)
    }

    /// Delete all transactions and reclaim space
    pub async fn clear_all(&self) -> anyhow::Result<u64> {
        // Clear the in-memory ring buffer
        {
            let mut ring = self.ring.write().await;
            ring.clear();
        }

        // Clear the database
        let db = Arc::clone(&self.db);
        let deleted = tokio::task::spawn_blocking(move || -> anyhow::Result<u64> {
            let conn = db.lock().expect("db mutex poisoned");
            let count = conn.execute("DELETE FROM transactions", [])?;
            conn.execute_batch("VACUUM")?;
            Ok(count as u64)
        })
        .await??;

        tracing::info!("Cleared {} transactions from database", deleted);
        Ok(deleted)
    }

    /// Get the count of transactions in the database
    pub async fn count(&self) -> anyhow::Result<u64> {
        let db = Arc::clone(&self.db);
        let count = tokio::task::spawn_blocking(move || -> anyhow::Result<u64> {
            let conn = db.lock().expect("db mutex poisoned");
            let count: i64 =
                conn.query_row("SELECT COUNT(*) FROM transactions", [], |row| row.get(0))?;
            Ok(count.max(0) as u64)
        })
        .await??;
        Ok(count)
    }

    /// Get unique hosts with request counts, sorted by count descending
    pub async fn list_unique_hosts(&self, limit: u32) -> anyhow::Result<Vec<(String, u64)>> {
        let db = Arc::clone(&self.db);
        let capped_limit = limit.clamp(1, 500) as i64;

        let results = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<(String, u64)>> {
            let conn = db.lock().expect("db mutex poisoned");
            let mut stmt = conn.prepare(
                "SELECT host, COUNT(*) as cnt FROM transactions 
                 GROUP BY host 
                 ORDER BY cnt DESC 
                 LIMIT ?",
            )?;
            let mut rows = stmt.query(params![capped_limit])?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let host: String = row.get(0)?;
                let count: i64 = row.get(1)?;
                out.push((host, count as u64));
            }
            Ok(out)
        })
        .await??;

        Ok(results)
    }

    #[allow(dead_code)]
    pub fn db_path(&self) -> &Path {
        &self.db_path
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{HttpMethod, TransactionFilter, TransactionTiming};
    use std::collections::HashMap;
    use tempfile::tempdir;

    fn make_tx(id: &str, started_at: i64) -> HttpTransaction {
        let mut tx = HttpTransaction::new(
            HttpMethod::Get,
            "https",
            "example.com",
            443,
            "/",
            HashMap::new(),
        );
        tx.id = id.to_string();
        tx.timing.start_time = started_at;
        tx
    }

    fn sample_transaction(
        host: &str,
        status: u16,
        start_time: i64,
        method: HttpMethod,
    ) -> HttpTransaction {
        let mut tx = HttpTransaction::new(method, "https", host, 443, "/api", HashMap::new());
        tx.status_code = Some(status);
        tx.timing = TransactionTiming {
            start_time,
            ..TransactionTiming::default()
        };
        tx
    }

    #[tokio::test]
    async fn add_transaction_persists_and_queries() {
        let dir = tempdir().expect("temp dir");
        let store =
            TransactionStore::new(dir.path().to_str().unwrap(), 10).expect("store initializes");

        let base_time = 1_700_000_000_000i64;
        for i in 0..3 {
            let tx = sample_transaction(
                &format!("api{i}.example.com"),
                200 + i as u16,
                base_time + i as i64,
                HttpMethod::Get,
            );
            store.add_transaction(tx).await.expect("add ok");
        }

        let result = store
            .query(&TransactionFilter::default(), 0, 50)
            .await
            .expect("query ok");

        assert_eq!(result.total, 3);
        assert_eq!(result.items.len(), 3);
        assert!(result.items[0].timing.start_time >= result.items[1].timing.start_time);
    }

    #[tokio::test]
    async fn query_respects_filters() {
        let dir = tempdir().expect("temp dir");
        let store =
            TransactionStore::new(dir.path().to_str().unwrap(), 10).expect("store initializes");

        let tx_match = sample_transaction(
            "match.example.com",
            502,
            1_700_000_000_100,
            HttpMethod::Post,
        );
        let tx_other =
            sample_transaction("other.example.com", 200, 1_700_000_000_200, HttpMethod::Get);

        store.add_transaction(tx_match).await.expect("add match");
        store.add_transaction(tx_other).await.expect("add other");

        let filter = TransactionFilter {
            host_contains: Some("match".into()),
            status_min: Some(400),
            ..Default::default()
        };

        let result = store.query(&filter, 0, 10).await.expect("query ok");
        assert_eq!(result.total, 1);
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].host, "match.example.com");
        assert_eq!(result.items[0].status_code, Some(502));
    }

    #[tokio::test]
    async fn ring_buffer_enforces_max_length() {
        let dir = tempdir().expect("temp dir");
        let max_len = 3;
        let store = TransactionStore::new(dir.path().to_str().unwrap(), max_len)
            .expect("store initializes");

        let base = 1_700_000_000_000i64;
        for i in 0..5 {
            let tx = sample_transaction(
                &format!("ring{i}.example.com"),
                200,
                base + i as i64,
                HttpMethod::Get,
            );
            store.add_transaction(tx).await.expect("add ok");
        }

        {
            let ring = store.ring.read().await;
            assert_eq!(ring.len(), max_len);
            let start_times: Vec<_> = ring.iter().map(|tx| tx.timing.start_time).collect();
            assert_eq!(
                start_times,
                vec![base + 2, base + 3, base + 4],
                "ring buffer keeps newest entries"
            );
        }

        let result = store
            .query(&TransactionFilter::default(), 0, 10)
            .await
            .expect("query ok");
        assert_eq!(result.total, 5, "database retains all entries");
        assert_eq!(
            result.items.first().unwrap().host,
            "ring4.example.com",
            "most recent entry returned first"
        );
    }

    #[tokio::test]
    async fn list_page_orders_and_limits() {
        let dir = tempdir().expect("temp dir");
        let store =
            TransactionStore::new(dir.path().to_str().unwrap(), 100).expect("store initializes");

        let tx1 = make_tx("a", 1_000);
        let tx2 = make_tx("b", 2_000);
        let tx3 = make_tx("c", 3_000);
        store.add_transaction(tx1).await.expect("add tx1");
        store.add_transaction(tx2).await.expect("add tx2");
        store.add_transaction(tx3).await.expect("add tx3");

        // Page 1: newest first, limit 2
        let page1 = store.list_page(None, 2).await.expect("page1 ok");
        assert_eq!(page1.len(), 2);
        assert_eq!(page1[0].id, "c");
        assert_eq!(page1[1].id, "b");

        // Page 2: before timestamp of last item from page1 -> should fetch older
        let before = page1.last().unwrap().timing.start_time;
        let page2 = store.list_page(Some(before), 2).await.expect("page2 ok");
        assert_eq!(page2.len(), 1);
        assert_eq!(page2[0].id, "a");
    }
}
