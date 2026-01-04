use crate::api::proxy_api::send_transaction_to_sink;
use crate::models::breakpoint::{BreakpointRule, BreakpointRuleInput, RequestEdit};
use crate::models::{HttpMethod, HttpTransaction, TransactionState};
use anyhow::{anyhow, Context};
use once_cell::sync::{Lazy, OnceCell};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Mutex, RwLock};
use tokio::sync::broadcast;
use tokio::sync::oneshot;
use uuid::Uuid;

static MANAGER: OnceCell<BreakpointManager> = OnceCell::new();
static BREAKPOINT_EVENTS: Lazy<broadcast::Sender<BreakpointEvent>> = Lazy::new(|| {
    let (tx, _rx) = broadcast::channel(128);
    tx
});

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BreakpointContext {
    pub method: HttpMethod,
    pub host: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum BreakpointEventKind {
    Hit,
    Resumed { edited: bool },
    Aborted { reason: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BreakpointEvent {
    pub transaction_id: String,
    pub kind: BreakpointEventKind,
    pub context: Option<BreakpointContext>,
}

impl BreakpointEvent {
    fn hit(transaction_id: String, ctx: BreakpointContext) -> Self {
        Self {
            transaction_id,
            kind: BreakpointEventKind::Hit,
            context: Some(ctx),
        }
    }

    fn resumed(transaction_id: String, edited: bool) -> Self {
        Self {
            transaction_id,
            kind: BreakpointEventKind::Resumed { edited },
            context: None,
        }
    }

    fn aborted(transaction_id: String, reason: String) -> Self {
        Self {
            transaction_id,
            kind: BreakpointEventKind::Aborted { reason },
            context: None,
        }
    }
}

fn emit_event(event: BreakpointEvent) {
    let _ = BREAKPOINT_EVENTS.send(event);
}

pub fn subscribe_breakpoint_events() -> broadcast::Receiver<BreakpointEvent> {
    BREAKPOINT_EVENTS.subscribe()
}

pub enum BreakpointAction {
    Resume(RequestEdit),
    Abort(String),
}

type PendingBreakpoint = oneshot::Sender<BreakpointAction>;

pub struct BreakpointManager {
    rules: RwLock<Vec<BreakpointRule>>,
    pending: Mutex<HashMap<String, PendingBreakpoint>>,
}

impl Default for BreakpointManager {
    fn default() -> Self {
        Self {
            rules: RwLock::new(Vec::new()),
            pending: Mutex::new(HashMap::new()),
        }
    }
}

impl BreakpointManager {
    pub fn instance() -> &'static Self {
        MANAGER.get_or_init(BreakpointManager::default)
    }

    pub fn list_rules(&self) -> Vec<BreakpointRule> {
        self.rules.read().unwrap().clone()
    }

    pub fn add_rule(&self, input: BreakpointRuleInput) -> BreakpointRule {
        let mut rules = self.rules.write().unwrap();
        let rule = BreakpointRule {
            id: Uuid::new_v4().to_string(),
            enabled: input.enabled,
            method: input.method,
            host_contains: input.host_contains,
            path_contains: input.path_contains,
        };
        rules.push(rule.clone());
        rule
    }

    pub fn remove_rule(&self, id: &str) -> bool {
        let mut rules = self.rules.write().unwrap();
        let before = rules.len();
        rules.retain(|rule| rule.id != id);
        before != rules.len()
    }

    fn rule_matches(rule: &BreakpointRule, ctx: &BreakpointContext) -> bool {
        if !rule.enabled {
            return false;
        }
        if let Some(method) = rule.method {
            if method != ctx.method {
                return false;
            }
        }
        if let Some(host) = &rule.host_contains {
            if !ctx
                .host
                .to_ascii_lowercase()
                .contains(&host.to_ascii_lowercase())
            {
                return false;
            }
        }
        if let Some(path) = &rule.path_contains {
            if !ctx
                .path
                .to_ascii_lowercase()
                .contains(&path.to_ascii_lowercase())
            {
                return false;
            }
        }
        true
    }

    pub fn should_break(&self, ctx: &BreakpointContext) -> bool {
        self.rules
            .read()
            .unwrap()
            .iter()
            .any(|rule| Self::rule_matches(rule, ctx))
    }

    pub async fn wait_for_decision(
        &self,
        transaction_id: String,
    ) -> anyhow::Result<BreakpointAction> {
        let (tx, rx) = oneshot::channel();
        {
            let mut guard = self.pending.lock().unwrap();
            guard.insert(transaction_id.clone(), tx);
        }

        let result = rx.await.context("breakpoint cancelled");
        if result.is_err() {
            let mut guard = self.pending.lock().unwrap();
            guard.remove(&transaction_id);
        }
        result
    }

    pub fn resolve(&self, transaction_id: &str, action: BreakpointAction) -> anyhow::Result<()> {
        let mut guard = self.pending.lock().unwrap();
        if let Some(pending) = guard.remove(transaction_id) {
            pending
                .send(action)
                .map_err(|_| anyhow!("Breakpoint consumer dropped"))?;
            Ok(())
        } else {
            Err(anyhow!(
                "No pending breakpoint for transaction {}",
                transaction_id
            ))
        }
    }

    #[cfg(test)]
    fn reset(&self) {
        self.rules.write().unwrap().clear();
        self.pending.lock().unwrap().clear();
    }
}

pub async fn maybe_pause_request(
    tx: &mut HttpTransaction,
    ctx: BreakpointContext,
) -> anyhow::Result<Option<RequestEdit>> {
    let manager = BreakpointManager::instance();
    if !manager.should_break(&ctx) {
        return Ok(None);
    }

    tx.state = TransactionState::Breakpointed;
    tx.has_breakpoint = true;
    let _ = crate::storage::persist_transaction(tx.clone()).await;
    send_transaction_to_sink(tx.clone());
    emit_event(BreakpointEvent::hit(tx.id.clone(), ctx.clone()));

    match manager.wait_for_decision(tx.id.clone()).await? {
        BreakpointAction::Resume(edit) => {
            tx.state = TransactionState::Pending;
            tx.has_breakpoint = false;
            send_transaction_to_sink(tx.clone());
            emit_event(BreakpointEvent::resumed(tx.id.clone(), !edit.is_empty()));
            if edit.is_empty() {
                Ok(None)
            } else {
                Ok(Some(edit))
            }
        }
        BreakpointAction::Abort(reason) => {
            emit_event(BreakpointEvent::aborted(tx.id.clone(), reason.clone()));
            Err(anyhow!(reason))
        }
    }
}

pub fn list_breakpoint_rules() -> Vec<BreakpointRule> {
    BreakpointManager::instance().list_rules()
}

pub fn add_breakpoint_rule(input: BreakpointRuleInput) -> BreakpointRule {
    BreakpointManager::instance().add_rule(input)
}

pub fn remove_breakpoint_rule(id: &str) -> bool {
    BreakpointManager::instance().remove_rule(id)
}

pub fn resume_breakpoint(transaction_id: &str, edit: RequestEdit) -> anyhow::Result<()> {
    BreakpointManager::instance()
        .resolve(transaction_id, BreakpointAction::Resume(edit.clone()))?;
    emit_event(BreakpointEvent::resumed(
        transaction_id.to_string(),
        !edit.is_empty(),
    ));
    Ok(())
}

pub fn abort_breakpoint(transaction_id: &str, reason: String) -> anyhow::Result<()> {
    BreakpointManager::instance()
        .resolve(transaction_id, BreakpointAction::Abort(reason.clone()))?;
    emit_event(BreakpointEvent::aborted(transaction_id.to_string(), reason));
    Ok(())
}

#[cfg(test)]
pub fn reset_for_tests() {
    if let Some(manager) = MANAGER.get() {
        manager.reset();
    }
}
