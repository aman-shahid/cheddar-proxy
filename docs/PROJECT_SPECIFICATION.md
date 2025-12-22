# Cheddar Proxy - Open Source Network Traffic Inspector & MCP Bridge

> A free, open-source, cross-platform network traffic inspector with a built-in MCP server for AI/agent workflows.

---

## Table of Contents

1. [Vision & Philosophy](#vision--philosophy)
2. [Target Platforms](#target-platforms)
3. [Core Features](#core-features)
4. [Architecture](#architecture)
5. [Technology Stack](#technology-stack)
6. [User Experience Design](#user-experience-design)
7. [Technical Deep Dive](#technical-deep-dive)

---

## Vision & Philosophy

### The Problem

Existing network inspection tools have significant limitations:

| Tool | Issues |
|------|--------|
| **Fiddler** | Classic is free but Windows-only and largely frozen. Fiddler Everywhere is cross-platform, requires an account, and uses a paid subscription. |
| **Proxyman** | Excellent UX but commercial license; Windows/Linux builds are Electron-based. |
| **Charles Proxy** | Paid license; UI modernized in v5 after years of a dated interface. |
| **HTTP Toolkit** | Requires proxy setup steps; open-core with some features gated behind paid tiers. |
| **mitmproxy** | CLI/TUI centric; mitmweb exists but is browser-based, not a native desktop app. |
| **Browser DevTools** | Browser-only; can’t inspect arbitrary desktop apps or backend services. |

Planned performance comparison (to be filled after measurement):

| App | Stack | Benchmark status |
|-----|-------|------------------|
| Cheddar Proxy | Flutter (desktop) + Rust core | To be measured (idle/load RSS + CPU) |
| HTTP Toolkit | Electron | To be measured (idle/load RSS + CPU) |
| Proxyman (Windows/Linux) | Electron | To be measured (idle/load RSS + CPU) |

### Our Philosophy

**Cheddar Proxy** is built on these core principles:

#### 1. One-Click Setup
> Get started quickly with guided setup for HTTPS inspection.

- HTTP traffic captured immediately on launch
- One-time CA certificate trust for HTTPS decryption (guided flow)
- Sensible defaults that work for 90% of use cases
- Power features planned (see Roadmap)

#### 2. Native Desktop Experience
> It should *feel* like a desktop app, not a website in a box.

- Native-quality UI performance and responsiveness
- Platform-appropriate controls and behaviors
- No web scrollbars, no Electron jank

#### 3. AI-Native Workflows
> Built to plug straight into AI agents and automation.

- Local MCP server for AI agent integration
- Request replay/export hooks designed for scripting
- Fast, full-text search across URL and bodies (request/response) from a single bar
- Breakpoints and request modification for controlled prompts/tests

#### 4. Free and Open Source
> No paywalls. No "upgrade to pro" nags.

- Entire codebase is open and community-driven
- MIT or Apache 2.0 license

---

## Target Platforms

### Phase 1 (MVP)
- **macOS** (Intel + Apple Silicon)
- **Windows** (x64)

### Phase 2
- **Linux** (x64)

---

## Core Features

### MVP Features (Phase 1)

#### Traffic Capture
- [x] HTTP/1.1 interception
- [x] HTTPS decryption (with user-installed CA certificate)
- [x] WebSocket traffic capture
- [x] Automatic system proxy configuration (macOS via `networksetup`)
- [x] Filter by host, path, method, status code

#### Request/Response Inspection
- [x] Request headers, body, timing
- [x] Response headers, body, timing
- [x] Body viewers: JSON, XML, HTML, Images, Raw/Hex
- [x] Syntax highlighting for code bodies
- [x] Search within URL and request/response bodies

#### Developer Productivity
- [x] Copy request as cURL command
- [x] Replay request
- [x] Clear all traffic
- [x] Export/import sessions (HAR format)

#### Breakpoints
- [x] Pause requests matching a rule
- [x] Edit request before forwarding
- [x] Edit response before returning to client
- [x] Conditional breakpoints (by host, path, method)

### Future (Phase 2+)

#### Traffic & Platform
- [ ] HTTP/2 interception
- [ ] Automatic system proxy configuration (Windows)

#### Advanced Protocol Support
- [ ] gRPC inspection and decoding
- [ ] GraphQL query visualization
- [ ] Server-Sent Events (SSE)
- [ ] HTTP/3 (QUIC)

#### Developer Productivity
- [ ] Copy request as code (Python, JavaScript, Go, etc.)

## Architecture

### High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                             Flutter UI Layer                                 │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐   │
│  │ Traffic     │   │ Inspector   │   │ Breakpoint  │   │ Settings        │   │
│  │ List View   │   │ Panel       │   │ Manager     │   │ & Preferences   │   │
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────┤
│                      Flutter <-> Native Bridge                               │
│               (FFI for Rust | Platform Channels for OS APIs)                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                             Core Engine (Rust)                               │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐   │
│  │ Proxy       │   │ TLS         │   │ Protocol    │   │ Storage         │   │
│  │ Server      │   │ Interception│   │ Parsers     │   │ (SQLite)        │   │
│  │ (TCP/HTTP)  │   │ (Cert Gen)  │   │ (HTTP/WS)   │   │                 │   │
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────────┘   │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐   │
│  │ Breakpoint  │   │ Filter      │   │ Export      │   │ MCP Server      │   │
│  │ Engine      │   │ Engine      │   │ (HAR/cURL)  │   │ (AI Integration)│   │
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────────┘   │
├──────────────────────────────────────────────────────────────────────────────┤
│                          Platform Adapters                                   │
│  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐          │
│  │ macOS            │   │ Windows          │   │ Linux            │          │
│  │ • System Proxy   │   │ • System Proxy*  │   │ • System Proxy   │          │
│  │ • Keychain       │   │ • Cert Store     │   │ • Cert trust TBD │          │
│  └──────────────────┘   └──────────────────┘   └──────────────────┘          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
┌────────────┐     ┌─────────────────┐     ┌────────────────┐
│ Client App │────▶│ Cheddar Proxy   │────▶│ Target Server  │
│ (Browser / │◀────│ (localhost:9090)│◀────│ (api.example.  │
│  Desktop)  │     │                 │     │  com)          │
└────────────┘     └────────┬────────┘     └────────────────┘
                            │
                   ┌────────▼────────┐
                   │ Traffic Store   │
                   │ (SQLite + Memory│
                   │  Ring Buffer)   │
                   └────────┬────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
 ┌────────▼────────┐ ┌──────▼──────┐ ┌────────▼────────┐
 │ Flutter UI      │ │ MCP Server  │ │ HAR Export      │
 │ (via FFI)       │ │ (AI Agents) │ │ (File I/O)      │
 └─────────────────┘ └─────────────┘ └─────────────────┘
```

### Component Responsibilities

#### Flutter UI Layer
- Render traffic list with virtualization (for performance with 10k+ requests)
- Request/response detail panels
- Breakpoint management UI
- Settings and preferences
- Platform-specific styling adjustments

#### Native Bridge
- **flutter_rust_bridge** for Rust FFI
- Async streams for real-time traffic updates
- Platform channels for OS-specific APIs (proxy config, cert installation)

#### Rust Core Engine
- **Proxy Server**: Accept connections, forward traffic
- **TLS Interception**: Generate certificates on-the-fly using root CA
- **Protocol Parsers**: Decode HTTP/1.1, WebSocket frames
- **Breakpoint Engine**: Pause request/response flow, allow modification
- **Storage**: SQLite for persistence, memory ring buffer for recent traffic
- **Export**: Generate HAR files, cURL commands
- **MCP Server**: Model Context Protocol server for AI agent integration

#### Platform Adapters
- Configure system proxy settings (macOS: networksetup, Windows: registry/WinHTTP)
- Install/trust CA certificates in system stores
- Handle platform-specific networking quirks

---

## Technology Stack

### Frontend (UI)

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **Framework** | Flutter 3.x | Cross-platform native desktop apps |
| **State Management** | Provider | Simple, effective state management |
| **Syntax Highlighting** | `flutter_highlight` | JSON, XML, HTML body rendering |
| **Typography** | Platform fonts + Google Fonts | Segoe UI (Windows), SF (macOS), Inter (Linux) |
| **macOS Styling** | `macos_ui` | Native macOS look and feel |
| **Windows Styling** | `fluent_ui` | Native Windows 11 look and feel |
| **Window Management** | `window_manager` | Custom window chrome, sizing |
| **FFI Bridge** | `flutter_rust_bridge` | Dart ↔ Rust interop |

### Backend (Core Engine)

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **Language** | Rust | Performance, safety, cross-platform |
| **Async Runtime** | Tokio | Industry standard for async Rust |
| **HTTP Proxy** | `hyper` 1.x + `hyper-util` | Full control over proxy behavior |
| **TLS** | `rustls` + `tokio-rustls` | Pure Rust TLS, no OpenSSL |
| **Certificate Generation** | `rcgen` | Dynamic SSL cert generation |
| **HTTP Parsing** | `httparse` | Fast HTTP/1.1 parsing |
| **WebSocket** | Built-in (upgrade handling) | WebSocket frame capture |
| **Storage** | `rusqlite` (bundled) | Embedded SQLite for persistence |
| **HTTP Client** | `reqwest` | Request replay functionality |
| **Serialization** | `serde` + `serde_json` | JSON/data serialization |
| **MCP Server** | `rmcp` | Built-in MCP server for AI agent integration |

### Platform Integration

| Platform | System Proxy | Certificate Trust |
|----------|--------------|-------------------|
| **macOS** | `networksetup` CLI | Keychain Access helpers (Swift/CLI) |
| **Windows** | PowerShell/registry helper (validation pending) | `certutil` to Windows Root store |

---

## User Experience Design

### Main Window Layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ○ ○  Cheddar Proxy                                        ⏸ 🔍 ⚙️     │
├────────────────────────────────────────────────────────────────────────────┤
│ Filter: [________________________] [Method ▼] [Status ▼] [Host ▼] [Clear] │
├────────────────────────────────────────────────────────────────────────────┤
│                                    │                                       │
│  #   │ Method │ Host        │ Path │ Status │ Time   │                    │
│ ─────┼────────┼─────────────┼──────┼────────┼────────│    Request         │
│  1   │ GET    │ api.example │ /use │  200   │  45ms  │    ─────────       │
│  2   │ POST   │ api.example │ /log │  201   │ 120ms  │    GET /users      │
│  3   │ GET    │ cdn.site    │ /ima │  304   │  12ms  │    Host: api.ex... │
│  4   │ PUT    │ api.example │ /use │  200   │  89ms  │                    │
│  5   │ DELETE │ api.example │ /use │  204   │  34ms  │    Headers (7)     │
│  ●   │ GET    │ api.example │ /ord │  ⏸️   │   -    │    ├─ Accept: ...  │
│      │        │             │      │        │        │    ├─ Auth: Bear.. │
│      │        │             │      │        │        │    └─ Content...   │
│      │        │             │      │        │        │                    │
│      │        │             │      │        │        │    Body (JSON)     │
│      │        │             │      │        │        │    ┌──────────────┐│
│      │        │             │      │        │        │    │{             ││
│      │        │             │      │        │        │    │  "id": 123,  ││
│      │        │             │      │        │        │    │  "name": ... ││
│      │        │             │      │        │        │    │}             ││
│      │        │             │      │        │        │    └──────────────┘│
│                                    │                                       │
│                                    │  [Request] [Response] [Timing]        │
├────────────────────────────────────────────────────────────────────────────┤
│ ● Recording │ 127.0.0.1:9090 │ 247 requests │ CA: Installed ✓             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Key UX Principles

#### 1. Low-Friction Onboarding
- Avoid setup wizards; default to capturing immediately with sensible defaults.
- Minimize blocking prompts; surface trust/proxy steps only when needed.

#### 2. Clarity First
- Request list as the primary plane with clear hierarchy; details in a split panel.
- Color and typography reinforce state (2xx/3xx/4xx/5xx) without visual noise.

#### 3. Platform-Native Feel
- macOS uses `macos_ui`, Windows uses Fluent-styled components via adaptive wrappers.
- Menus, dialogs, scrollbars, and fonts follow the host platform conventions.

#### 4. AI-Native & Searchable
- Single search bar does full-text across method, URL, request body, and response body.
- Hooks (replay/export/MCP) are optimized for automation and agent use.


### Color Scheme

```
Dark (default)
- Background:      #1E1E2E
- Surface:         #2A2A3C (light: #363649) with border #3D3D52
- Text:            primary #F8FAFC, secondary #94A3B8, muted #64748B
- Primary accent:  #FFC107 (amber), light #FFCC80, dark #D97706

Light
- Background:      #F8FAFC
- Surface:         #FFFFFF (light: #F1F5F9) with border #E2E8F0
- Text:            primary #1E293B, secondary #475569, muted #94A3B8

Status
- Success (2xx):   #22C55E
- Redirect (3xx):  #F59E0B
- Client error:    #EF4444
- Server error:    #DC2626
```

---

## Technical Deep Dive

### TLS Interception Flow

```
1. Client connects to proxy (CONNECT api.example.com:443)
2. Proxy acknowledges (200 Connection Established)
3. Client starts TLS handshake with proxy (thinking it's the server)
4. Proxy generates certificate for api.example.com signed by our CA
5. Proxy presents this certificate to client
6. Client accepts (because our CA is trusted)
7. Proxy connects to real api.example.com, does real TLS handshake
8. Traffic flows: Client <--TLS1--> Proxy <--TLS2--> Server
9. Proxy can read/modify plaintext in the middle
```

### Certificate Generation

```rust
// Pseudocode for on-the-fly cert generation
fn generate_cert_for_host(host: &str, ca_cert: &Certificate, ca_key: &PrivateKey) -> Certificate {
    let subject = format!("CN={}", host);
    let san = vec![host]; // Subject Alternative Names

    CertificateBuilder::new()
        .subject(&subject)
        .san(&san)
        .validity(Duration::days(365))
        .sign_with(ca_key, ca_cert)
        .build()
}
```

### Breakpoint Implementation

```
Request arrives at proxy:
  │
  ▼
┌─────────────────────────────┐
│ Check breakpoint rules      │
│ (host, path, method match?) │
└─────────────┬───────────────┘
              │
    ┌─────────┴─────────┐
    │                   │
    ▼                   ▼
[No Match]          [Match]
    │                   │
    ▼                   ▼
Forward to         Pause request
server             Send to UI for editing
                        │
                        ▼
                   User edits (or continues)
                        │
                        ▼
                   Forward modified request
```

### Performance Considerations

| Challenge | Solution |
|-----------|----------|
| 100k+ requests in list | Virtualized list, only render visible rows |
| Large response bodies (MB+) | Stream to disk, lazy load in UI |
| High traffic volume | Ring buffer in memory, archive to SQLite |
| UI responsiveness | Rust handles all I/O, Flutter just renders |
| Memory usage | Configurable limits, auto-prune old traffic |

---

*Last Updated: December 19, 2025*
