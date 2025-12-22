# Cheddar Proxy MCP Adapter Specification

## 1. Background & Motivation

Cheddar Proxy today exposes its capabilities through two surfaces:

- The Flutter desktop UI.
- A Flutter Rust Bridge (FRB) API that powers the UI and scripting hooks.

There is no structured way for IDEs, agents, or automation pipelines to control the proxy without going through the UI. With the rise of MCP (Model Context Protocol) clients (Cursor, VS Code extensions, automated agents), we want to expose Cheddar Proxy as an MCP server so tooling can:

- Start/stop the proxy and monitor health.
- Enable/disable system proxy settings and certificate trust.
- Subscribe to captured traffic streams and query historical transactions.
- Manage breakpoints/request edits programmatically.
- Export/import sessions (HAR/archive) without UI interaction.

## 2. Goals & Non-Goals

### Goals
1. Provide a self-contained MCP server binary (or mode) that runs alongside the existing Rust core.
2. Map the current FRB APIs to MCP resources/actions:
   - Proxy lifecycle.
   - Transaction streaming/query.
   - System proxy & certificate management.
   - Breakpoints.
3. Document protocol schemas so IDE/agent authors can integrate without reverse-engineering.
4. Ensure the MCP server obeys the same persistence/storage semantics as the UI (shared SQLite + ring buffer).

### Non-Goals (for initial version)
1. Remote or multi-user access (assume local loopback/IPC).
2. ~~New proxy core features (e.g., WebSocket capture) beyond what already exists.~~ **[DONE: WebSocket capture implemented Dec 2024]**
3. UI integration beyond exposing notifications/status (that can come later).

## 3. Architecture Overview

```
┌────────────────────────────┐
│ MCP Client (IDE/Agent)     │
│  ├─ Requests (JSON-RPC)    │
│  └─ Subscriptions          │
└────────────┬───────────────┘
             │ MCP (stdio / socket)
┌────────────▼───────────────┐
│ Cheddar Proxy MCP Server    │
│  ├─ MCP Router             │
│  ├─ FRB Bridge (existing)  │
│  └─ Tok io runtime         │
└────────────┬───────────────┘
             │ FRB async API
┌────────────▼───────────────┐
│ Rust Core (proxy/storage)  │
│  ├─ Proxy server           │
│  ├─ System proxy helpers   │
│  ├─ Breakpoints            │
│  └─ Transaction store      │
└────────────────────────────┘
```

## 3.1 Feature Parity: MCP ↔ UI

All capabilities exposed via MCP **must also be available in the Flutter UI**. The Rust core is the single source of truth; both MCP and UI are "consumers" of the same API.

```
┌────────────────┐     ┌────────────────┐
│ Flutter UI     │     │ MCP Client     │
│ (Desktop App)  │     │ (IDE/Agent)    │
└───────┬────────┘     └───────┬────────┘
        │ FRB (async)          │ JSON-RPC
        └──────────┬───────────┘
                   ▼
        ┌──────────────────────┐
        │ core (Rust)          │
        │ • proxy_api.rs       │
        │ • storage/           │
        │ • breakpoints/       │
        └──────────────────────┘
```

## 3.2 Safety & Bounded Autonomy

Exposing network traffic control to AI agents is powerful but inherently risky. An autonomous agent with unchecked write access could cause infinite loops (replaying its own requests), trigger destructive actions, or overwhelm servers.

Cheddar adopts a **Bounded Autonomy** approach: Agents get full observability but constrained actuation.

### Permission Tiers

| Tier | Capabilities | Risk Level | Default |
| :--- | :--- | :--- | :--- |
| **Read-Only** | Stream transactions, query history, export HAR | Low | ✅ Yes |
| **Replay** | Re-send captured requests (optionally modified) | Medium | Requires explicit enable |
| **Breakpoints** | Pause live traffic, inspect/edit before forwarding | High | Requires explicit enable |
| **Proxy Control** | Start/stop proxy, modify system settings | Critical | UI-only (not exposed via MCP) |

### Guardrails (Current & Planned)

1. **Authentication Required:** MCP clients must present a valid Bearer token. Tokens are scoped per-session and can be rotated from the UI.
2. **Rate Limiting (Planned):** Hard limits on replay frequency to prevent runaway loops.
3. **Human-in-the-Loop (Planned):** High-risk actions (e.g., bulk replay, breakpoint edits) will prompt for user confirmation in the UI before executing.
4. **Audit Log (Planned):** All MCP actions are logged with timestamps and client identifiers.

### Design Philosophy

> "With great power comes great responsibility."

Other MCP-over-proxy implementations are read-only by design—safe, but limited. Cheddar's value proposition is giving Agents the ability to *act*, not just *observe*. But we do so with explicit opt-in and visible guardrails.

The goal: **Agents that debug, not Agents that destroy.**

### Parity Matrix

| Capability | MCP Action | UI Implementation | Notes |
| :--- | :--- | :--- | :--- |
| Start/stop proxy | `proxy.start` (with optional `enableSystemProxy`) / `proxy.stop` | ✅ Settings > MCP toggle | ✅ `stop` auto-disables system proxy |
| Enable system proxy | _(Integrated into `proxy.start`)_ | ✅ Settings > MCP toggle | ✅ Pass `enableSystemProxy: true` to start |
| View transactions | `proxy.transactions.get` | ✅ TrafficListView | ✅ Pagination + filters |
| Transaction details | `transaction_detail` | ✅ RequestDetailPanel | ✅ Returns full headers/bodies/timing |
| Add breakpoint | `proxy.addBreakpointRule` | ✅ RequestDetail header (host/method/path rule) | ✅ UI now mirrors MCP schema |
| Resume/abort breakpoint | `proxy.resumeBreakpoint` | ✅ RequestDetail header buttons | ✅ Done |
| Export HAR | `proxy.exportHar` | ✅ File menu (HAR export dialog) | ✅ Done |
| Import HAR | `proxy.importHar` | ✅ File menu (HAR import dialog) | ✅ Done |
| Replay request | `proxy.replayRequest` | ✅ Replay button in detail header | ✅ Done |
| **List WebSocket connections** | `websocket_connections_list` | ✅ Traffic list (WS icon) | ✅ Done |
| **Get WebSocket messages** | `websocket_messages_list` | ✅ WebSocket tab in detail panel | ✅ Done |
| **Get WS message count** | `websocket_message_count` | ✅ Detail panel header | ✅ Done |
| Generate cURL | `proxy.generateCurl` | 🔜 Context menu | Phase 4 |
| Performance timing | _(planned)_ | ✅ Timing tab | ⚠️ MCP action not shipped |
| Find slow requests | `proxy.getSlowRequests` | 🔜 Filter bar | Phase 5 |
| Detect error patterns | `proxy.detectErrorPatterns` | 🔜 Insights panel | Phase 6 |
| Extract API schema | `proxy.extractApiSchema` | 🔜 Export menu | Phase 6 |
| Clear transactions | `proxy.clearTransactions` | ✅ Toolbar button | ✅ Done |

**Rule:** When adding a new MCP action, the corresponding UI affordance MUST be added to the same milestone.

### Transport

- Primary: JSON-RPC over stdio (same process model as most MCP servers).
- Alternative: UNIX domain socket / Windows named pipe for long-lived daemon mode.

### Authentication
- The MCP server requires a Bearer token for access.
- Tokens are generated by the UI and stored in the secure preference store.
- Clients must provide the token in the initialization handshake or via the standard MCP auth header mechanism.
- Config JSON generated by the UI automatically includes the current token.

### Concurrency
- Reuse the existing tokio runtime; MCP handlers are async functions that call FRB APIs.
- Transaction streaming is bridged into MCP by registering as the FRB sink and forwarding events to subscribed MCP clients.

## 4. MCP Resources & Schemas

### Resources (Spec-Compliant)

The MCP server exposes the following **resources** for read-only access to proxy state:

| Resource URI                     | Description                                                   |
|---------------------------------|---------------------------------------------------------------|
| `proxy://status`                | Current proxy server status (port, connections, request count)|
| `proxy://certificate`           | Root CA certificate status and trust information              |
| `proxy://transaction/{id}`      | Full details of a captured HTTP transaction (template)        |

**Capabilities advertised:**
```json
{
  "resources": { "subscribe": false, "listChanged": false }
}
```

### Tools (Legacy Actions)

Tools provide the primary interface for AI agents to interact with the proxy:

| Tool                           | Description                                                   |
|---------------------------------|---------------------------------------------------------------|
| `proxy_status`                  | Get running state, port, bind address, counters               |
| `transactions_list`             | Paginated query with time-bounded filters                     |
| `transaction_detail`            | Fetch single transaction by ID with full headers/body         |
| `breakpoint_rules_list`         | List breakpoint rules                                         |
| `add_breakpoint_rule`           | Add a new breakpoint rule                                     |
| `export_har` / `import_har`     | HAR file operations                                          |

### Structured Output (outputSchema)

Tools that return structured data provide **outputSchema** via the `Json<T>` wrapper:

| Tool | Has outputSchema |
|------|------------------|
| `proxy_status` | ✅ `ProxyStatusResponse` |
| `system_status` | ✅ `SystemStatusResponse` |
| `server_stats` | ✅ `ServerStatsResponse` |
| `list_domains` | ✅ `ListDomainsResponse` |
| `transactions_list` | ❌ (paginated, JSON text) |
| `transaction_detail` | ❌ (complex nested, JSON text) |

The rmcp SDK auto-generates JSON Schema from response types, enabling AI clients to understand response structure.

### Example JSON Schema Snippets

```jsonc
// proxy/status
{
  "isRunning": true,
  "port": 9090,
  "bindAddress": "127.0.0.1",
  "httpsEnabled": true,
  "activeConnections": 4,
  "totalRequests": 213
}

// proxy/transactions GET response
{
  "total": 1250,
  "page": 0,
  "pageSize": 50,
  "items": [
    {
      "id": "txn_123",
      "timestamp": "2024-05-30T12:01:02Z",
      "method": "GET",
      "url": "https://example.com/api",
      "status": 200,
      "durationMs": 123,
      "state": "Completed",
      "hasBreakpoint": false
    }
  ]
}
```

Filtering parameters mirror `TransactionFilter` (method, hostContains, pathContains, statusMin/Max).

```jsonc
// proxy.transactions.subscribe request
{
  "filter": {
    "hostContains": "api.example.com",
    "statusMin": 400
  }
}

// Streaming notification envelope
{
  "jsonrpc": "2.0",
  "method": "proxy.transactions/created",
  "params": {
    "transaction": {
      "...": "Full HttpTransaction payload"
    }
  }
}
```

## 5. MCP Actions

| Action                          | Input                                                | Backend API                     |
|---------------------------------|------------------------------------------------------|---------------------------------|
| `proxy.start` / `proxy.stop`    | `{ port?, bindAddress?, enableHttps? }`              | `start_proxy`, `stop_proxy`     |
| `proxy.enableSystemProxy`       | `{ port }`                                           | `SystemProxyService.enable`     |
| `proxy.disableSystemProxy`      | _none_                                               | `SystemProxyService.disable`    |
| `proxy.installCertificate`      | `{ path? }` (default to storage path)                | `trustAndImportCertificate`     |
| `proxy.resumeBreakpoint`        | `{ transactionId, edit }`                            | `resume_breakpoint`             |
| `proxy.abortBreakpoint`         | `{ transactionId, reason }`                          | `abort_breakpoint`              |
| `proxy.addBreakpointRule`       | `{ enabled, method, hostContains, pathContains }`    | `add_breakpoint_rule`           |
| `proxy.removeBreakpointRule`    | `{ ruleId }`                                         | `remove_breakpoint_rule`        |
| `proxy.clearTransactions`       | _none_                                               | new helper (ring/db purge)      |
| `proxy.exportHar` _(phase 2)_   | `{ path }` or stream                                 | storage export helper           |
| `proxy.importHar` _(phase 2)_   | HAR file path or bytes                               | storage import helper           |
| `proxy.replayRequest`           | `{ id, method?, path?, headers?, body? }`            | `replay::replay_request`        |
| **`websocket_connections_list`** | `{ page?, pageSize? }`                              | `get_websocket_connections`     |
| **`websocket_messages_list`**   | `{ connectionId, limit?, offset? }`                  | `get_websocket_messages`        |
| **`websocket_message_count`**   | `{ connectionId }`                                   | `get_websocket_message_count`   |
| **`list_domains`**              | `{ limit? }`                                         | `list_unique_hosts`             |

Actions return structured success/error objects suitable for MCP clients.  
**Breakpoint defaults:** The Flutter UI now passes the exact HTTP method plus full host and path (including query) when it calls `proxy.addBreakpointRule`, so MCP and UI both treat breakpoints as single-request captures by default.

### WebSocket Example Schemas

```jsonc
// websocket_connections_list response
{
  "connections": [
    {
      "id": "wss://example.com/socket",
      "host": "example.com",
      "path": "/socket",
      "timestamp": 1702500000000,
      "messageCount": 42
    }
  ],
  "page": 0,
  "pageSize": 50,
  "total": 1
}

// websocket_messages_list response
{
  "connectionId": "wss://example.com/socket",
  "messages": [
    {
      "direction": "client_to_server",
      "opcode": "text",
      "payload": "{\"type\":\"ping\"}",
      "payloadLength": 15,
      "timestamp": 1702500001234
    },
    {
      "direction": "server_to_client",
      "opcode": "text",
      "payload": "{\"type\":\"pong\"}",
      "payloadLength": 15,
      "timestamp": 1702500001456
    }
  ],
  "offset": 0,
  "limit": 100,
  "total": 42,
  "hasMore": false
}
```

## 6. Developer Workflow

1. **Startup**
   - `cheddarproxy_mcp` binary launches (or `core --mcp` flag).
   - Initializes FRB core (`init_core`, `create_traffic_stream`), then starts MCP loop.
2. **Client Connects**
   - Issues `proxy.status` to check running state.
   - If needed, calls `proxy.start`, `proxy.enableSystemProxy`, `proxy.installCertificate`.
3. **Traffic capture**
   - Subscribe to `proxy/transactions` stream for live updates.
   - Use `proxy/transactions` GET for historical/paginated view.
4. **Breakpoints**
   - Add rules via `proxy.addBreakpointRule`.
   - When a transaction hits a breakpoint, client receives stream update with state = `Breakpointed`, then decides to resume/abort via actions.
5. **Shutdown**
   - `proxy.disableSystemProxy`, `proxy.stop`, disconnect MCP client.

## 7. Tasks & Milestones

### Phase 0 – Prep (done)
- ✅ Ensure storage + proxy integration tests cover breakpoint abort, TLS CONNECT, and ring buffer behaviour (already implemented).

### Phase 1 – MCP Core
1. **Command-line entry point** – ✅ Completed
   - Added standalone `cheddarproxy_mcp` binary with CLI flags.
   - Bootstraps tokio + FRB and sets up stdio MCP transport (JSON-RPC 2.0).
2. **Resource Handlers** – ✅ Completed (Spec-Compliant)
   - Implemented spec-compliant MCP resources with proper URIs:
     - `proxy://status` – Current proxy server status
     - `proxy://certificate` – Root CA certificate information
     - `proxy://transaction/{id}` – Transaction details (resource template)
   - Server advertises `resources` capability in initialization handshake.
   - Server includes `instructions` field per MCP 2025-11-25 spec.
3. **Actions (Tools)** – ✅ Completed
   - 25+ tools implemented including `proxy_start`, `proxy_stop`, `transactions_list`, breakpoint management.
   - Tools use JSON Schema for `inputSchema` via `schemars`.
4. **Streaming** – ✅ Completed
   - MCP server fans out FRB traffic via broadcast channel with filters.
5. **Docs & schema definitions**
   - JSON schema files or TypeScript definitions for each resource/action payload.

### Phase 2 – Breakpoints & HAR
1. ✅ MCP actions for `resumeBreakpoint`, `abortBreakpoint`, and rule add/remove (via `proxy.breakpoint*` calls).
2. ✅ Provide MCP notifications when breakpoints change state.
3. ✅ Wire HAR export/import (storage helpers + MCP actions) so automation can snapshot sessions.
   - Added `storage::har` module (`transactions_to_har`, `har_to_transactions`), FRB wrappers `export_har_file` / `import_har_file`, and MCP actions `proxy.har.export` / `proxy.har.import` that invoke them.

### Phase 3 – UX Enhancements

1. ✅ **UI toggle for MCP server** – Settings dialog now manages the MCP server lifecycle.
   - Shows connection status, socket path, and configuration JSON.
   - Provides "Enable on startup" preference.
2. ✅ **Authentication** – Implemented Bearer Token authentication.
   - Token auto-generated on first run.
   - UI provides "Copy Token" and "Regenerate Token" actions.
   - Configuration JSON includes the `auth` block for immediate client use.
3. Additional metadata (TLS timing, request/response bodies with size limits, WebSocket/GQL once implemented).

### Phase 4 – Replay & Testing

Enable AI agents to re-send captured requests with modifications.

| Action | Input | Description | Status |
| :--- | :--- | :--- | :--- |
| `proxy.replayRequest` | `{ id, method?, path?, headers?, body? }` | Re-send a captured request (optionally modified) | ✅ Done |
| `proxy.replaySequence` | `{ ids[] }` | Replay multiple requests in order | 🔜 Planned |
| `proxy.compareResponses` | `{ id1, id2 }` | Diff two responses (useful after replay) | 🔜 Planned |
| `proxy.generateCurl` | `{ id }` | Export as cURL command | 🔜 Planned |
| `proxy.generateCode` | `{ id, language }` | Export as Python/JS/Go fetch code | 🔜 Planned |

**Use Case:** *"Replay that failed request with the corrected auth header."*

**Implementation Details (replay_request):**
- MCP tool: `replay_request` in `sdk_server.rs`
- Flutter API: `replayRequest()` in `proxy_api.rs`  
- Core module: `src/replay/mod.rs` using `reqwest` HTTP client
- UI: Replay button (🔄) in request detail panel header
- Supports optional overrides for method, path, headers, and body
- New transaction is created and appears in traffic list with note "Replayed from {original_id}"

### Phase 5 – Performance Analysis

Provide actionable performance insights to AI agents.

| Action | Input | Description |
| :--- | :--- | :--- |
| `proxy.getTimingBreakdown` | `{ id }` | DNS, TCP, TLS, TTFB, Download times |
| `proxy.getSlowRequests` | `{ thresholdMs, limit }` | Find requests exceeding latency threshold |
| `proxy.getLargeResponses` | `{ thresholdBytes, limit }` | Find oversized payloads |
| `proxy.analyzeEndpoint` | `{ host, path }` | Aggregate stats for an endpoint (avg latency, error rate) |

**Use Case:** *"Find which API calls are slowing down the page load."*

### Phase 6 – AI Insights (High Value)

Automated pattern detection for intelligent debugging.

| Action | Input | Description |
| :--- | :--- | :--- |
| `proxy.detectErrorPatterns` | `{ limit? }` | Find recurring failures (same endpoint, same error) |
| `proxy.findAuthIssues` | _none_ | Detect 401/403 responses, missing/expired tokens |
| `proxy.findCorsIssues` | _none_ | Detect CORS preflight failures |
| `proxy.findRateLimiting` | _none_ | Detect 429 responses or throttling patterns |
| `proxy.extractApiSchema` | `{ host }` | Infer OpenAPI-like schema from observed traffic |
| `proxy.suggestFixes` | `{ transactionId }` | AI-friendly hints based on error response |

**Use Case:** *"What's wrong with my API integration?"* → Agent calls `detectErrorPatterns()`, sees 5 repeated 401s to `/api/auth`, suggests checking the API key.

### Implementation Priority

| Phase | Effort | AI Value | Status |
| :--- | :--- | :--- | :--- |
| 1. MCP Core | Low | High | ✅ Done |
| 2. Breakpoints & HAR | Medium | High | ✅ Done |
| 3. UX Enhancements | Medium | Medium | 🔜 Planned |
| 4. Replay & Testing | Medium | Very High | 🟡 Partial (replay_request done) |
| 5. Performance Analysis | Low | Medium | 🔜 Planned |
| 6. AI Insights | Medium | Very High | 🔜 Planned (AI?) |

## 8. Open Questions / Future Considerations

- **Multi-client coordination:** do we allow multiple MCP clients simultaneously? If so, need subscription fan-out and consistent state (probably via broadcast channel).
- **Conflict with Flutter UI:** when both UI and MCP try to control system proxy or start the core, we need mutual exclusion / status codes.
- **Long-running session storage:** Should MCP export be incremental (stream) or on-demand file? Might want both.
- **Security posture:** If we later expose the MCP server over TCP for remote automation, we must add TLS + auth.

## 9. Success Metrics

- MCP server can be started, controlled, and queried entirely without the UI.
- IDE extension can display live traffic, set breakpoints, and toggle system proxy via MCP.
- CI script can run `cheddarproxy_mcp`, capture traffic for test suite, export HAR, and shut everything down without manual steps.
