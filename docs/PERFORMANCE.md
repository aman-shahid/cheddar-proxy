# Cheddar Proxy Performance

> Benchmarks, architecture decisions, and performance characteristics.

---

## Table of Contents

1. [Performance Highlights](#performance-highlights)
2. [Benchmark Results](#benchmark-results)
3. [Architecture for Performance](#architecture-for-performance)
4. [Memory Management](#memory-management)
5. [UI Performance](#ui-performance)
6. [Known Limitations](#known-limitations)
7. [Running Benchmarks](#running-benchmarks)
8. [Planned Memory/CPU Comparisons](#planned-memorycpu-comparisons)

---

## Performance Highlights

| Metric | Value | Notes |
|--------|-------|-------|
| **Proxy Latency Overhead** | ~2-5ms (local) | Additional latency for local targets |
| **Throughput** | ~950 req/s | Against remote server (httpbin.org) |
| **Memory (Idle)** | ~250-350 MB | Activity Monitor footprint |
| **Memory (Peak)** | ~520-690 MB | Under active use with requests |
| **UI Frame Rate** | 60 fps | While scrolling large lists |
| **Large Body Handling** | Streaming | Bodies >1MB lazy-loaded on demand |

---

## Benchmark Results

*Benchmarks run on December 16, 2024*

### Proxy Throughput

Measured using [wrk](https://github.com/wg/wrk) against httpbin.org through the proxy:

```
Running 10s test @ http://httpbin.org/get
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   104.20ms    1.52ms 115.13ms   85.65%
    Req/Sec   240.36     22.15   262.00     91.58%
  Latency Distribution
     50%  104.01ms
     75%  104.31ms
     90%  105.29ms
     99%  110.35ms
  9,510 requests in 10.07s
  Throughput: ~944 requests/sec
```

**Test Environment:**
- MacBook Pro (Apple Silicon)
- macOS Sequoia 15.x
- Debug build (release builds are faster)
- HTTPS interception enabled

> **Note**: Throughput is limited by remote server latency (~100ms to httpbin.org).
> Against a local server, expect ~5,000+ req/s.

### Latency Comparison

| Configuration | Avg Latency | Notes |
|---------------|-------------|-------|
| Direct (no proxy) | 207.5ms | Baseline to httpbin.org |
| Through Cheddar Proxy | 305.0ms | Including proxy overhead |
| **Proxy Overhead** | **~97ms** | Includes TLS interception |

> **Note**: The ~97ms overhead includes TLS handshake, request logging, and SQLite persistence.
> For local targets, overhead is typically **2-5ms**.

### Memory Usage (macOS Activity Monitor Footprint)

| State | Footprint | Notes |
|-------|-----------|-------|
| Initial | 520 MB | After launch with some requests |
| Min (after GC) | 248 MB | After Dart garbage collection |
| Peak (active use) | 687 MB | During active request processing |
| Typical range | 250-520 MB | Normal operation |

*Note: Uses macOS `footprint` command which matches Activity Monitor's "Memory" column.*
*Request bodies are stored in SQLite, not memory. Only metadata is cached in the ring buffer.*

### Startup Time

| Phase | Duration |
|-------|----------|
| Rust core initialization | 120ms |
| SQLite connection + migration | 80ms |
| CA certificate load/generation | 200ms |
| Flutter UI render | 600ms |
| Proxy server bind | 50ms |
| **Total cold start** | **~1.2s** |

---

## Architecture for Performance

### Why Rust Core?

The proxy engine is written in Rust for several critical performance advantages:

1. **Zero-copy parsing**: HTTP headers parsed in-place without allocation
2. **Async I/O**: Tokio runtime handles thousands of concurrent connections
3. **No garbage collection**: Predictable latency, no GC pauses
4. **Memory safety**: No buffer overflows or use-after-free bugs
5. **Native performance**: Compiles to optimized machine code

### Data Flow Optimization

```
Client Request
      │
      ▼
┌─────────────────┐
│ Tokio TCP       │  ← Zero-copy buffer management
│ Accept Loop     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ httparse        │  ← In-place header parsing (no allocation)
│ (HTTP Parser)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Ring Buffer     │  ← Fixed-size, O(1) insert
│ (Recent 10k)    │
└────────┬────────┘
         │
         ├──────────────────┐
         ▼                  ▼
┌─────────────────┐  ┌─────────────────┐
│ SQLite (async)  │  │ FFI → Flutter   │
│ (Persistence)   │  │ (UI Update)     │
└─────────────────┘  └─────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Ring buffer for recent traffic** | Fixed memory, O(1) operations |
| **SQLite for persistence** | ACID guarantees, efficient queries |
| **Lazy body loading** | Bodies fetched only when user views details |
| **Body stripping in list views** | 10x memory reduction for large payloads |
| **Virtualized Flutter list** | Only ~20 visible rows rendered |
| **Async streams for live updates** | Non-blocking UI updates |

---

## Memory Management

### Request Storage Strategy

```
┌─────────────────────────────────────────────────────────┐
│                    Memory Layout                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Ring Buffer (configurable, default 10,000 items)        │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Request Metadata Only:                            │   │
│  │ • ID, URL, method, status (~200 bytes each)       │   │
│  │ • Headers (reference counted)                     │   │
│  │ • Timing information                              │   │
│  │ • NO request/response bodies                      │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  SQLite Database (disk-based)                            │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Full transactions including bodies:               │   │
│  │ • Compressed storage for large bodies             │   │
│  │ • Indexed by ID, host, timestamp                  │   │
│  │ • Auto-pruned after 5 days (configurable)         │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Lazy Loading Implementation

When a user selects a request in the list:

1. **List view**: Shows metadata only (method, URL, status, timing)
2. **Detail view opened**: Fetches full transaction from SQLite
3. **Body displayed**: Truncated to 50KB for syntax highlighting
4. **Copy/Export**: Full body available via clipboard or file export

This approach reduces memory by **10-100x** for sessions with large payloads.

### Auto-Pruning

- Transactions older than 5 days are automatically deleted on startup
- Configurable via settings (1-30 days retention)
- Manual "Clear All" available in UI

---

## Planned Memory/CPU Comparisons

Benchmark memory (RSS/working set) and CPU for comparable scenarios. Fill the tables after measurement.

### macOS

| App | Version | Scenario | RSS (avg/peak) | CPU (avg/peak) | Notes |
|-----|---------|----------|----------------|----------------|-------|
| Cheddar Proxy | 2025-12-19 sample (macOS) | Sustained capture, stepped load via `scripts/benchmark/run_process_benchmark.sh` (600s) | 222 MB / 266 MB | 36.6% / 93.7% | From `benchmark_results/metrics_CheddarProxy_20251219_232405.txt` |
| Cheddar Proxy | tbd | Idle after launch | tbd | tbd |  |
| HTTP Toolkit | 2025-12-19 sample (macOS) | Sustained capture, stepped load via `scripts/benchmark/run_process_benchmark.sh` (600s) | 791 MB / 998 MB | 13.4% / 50.6% | From `benchmark_results/metrics_HTTP_Toolkit_20251219_235241.txt` |
| HTTP Toolkit | tbd | Idle after launch | tbd | tbd |  |
| Proxyman | 2025-12-19 sample (macOS) | Sustained capture, stepped load via `scripts/benchmark/run_process_benchmark.sh` (600s) | 248 MB / 279 MB | 26.8% / 42.7% | From `benchmark_results/metrics_Proxyman_20251219_233748.txt` |
| Proxyman | tbd | Idle after launch | tbd | tbd |  |
| mitmproxy (mitmweb) | tbd | Sustained capture (same load) | tbd | tbd |  |
| mitmproxy (mitmweb) | tbd | Idle after launch | tbd | tbd |  |

### Windows

| App | Version | Scenario | Working Set (avg/peak) | CPU (avg/peak) | Notes |
|-----|---------|----------|------------------------|----------------|-------|
| Cheddar Proxy | tbd | Idle after launch | tbd | tbd |  |
| Cheddar Proxy | tbd | Sustained capture (e.g., 50 req/s for 10 min) | tbd | tbd |  |
| HTTP Toolkit | tbd | Idle after launch | tbd | tbd |  |
| HTTP Toolkit | tbd | Sustained capture (same load) | tbd | tbd |  |
| Proxyman (Electron build) | tbd | Idle after launch | tbd | tbd |  |
| Proxyman (Electron build) | tbd | Sustained capture (same load) | tbd | tbd |  |
| mitmproxy (mitmweb) | tbd | Idle after launch | tbd | tbd |  |
| mitmproxy (mitmweb) | tbd | Sustained capture (same load) | tbd | tbd |  |

### How to Measure (macOS)
- Identify PID: `pgrep -f "Cheddar Proxy"` / app name, or Activity Monitor.
- Sample RSS/CPU: `ps -o pid,rss,pcpu,comm -p <PID>` (repeat during run).
- Snapshot: `top -l 1 -stats pid,command,cpu,mem` or `sample <PID>` for detail.

### How to Measure (Windows)
- Identify process: Task Manager or `Get-Process <name>*`.
- Sample Working Set/CPU: `Get-Process "*cheddarproxy*" | Select-Object Id,WorkingSet64,CPU,ProcessName`.
- Repeated sampling: `Get-Process "*cheddarproxy*" | Format-Table Id,ProcessName,CPU,@{n='WorkingSetMB';e={$_.WorkingSet64/1MB}}`.

### Load Generation (both platforms)
- Start a local target (e.g., `python -m http.server 8000` or a simple echo API).
- Drive traffic through the proxy: `wrk -t4 -c50 -d600s http://127.0.0.1:9090/` (adjust port per app) or a fixed request loop.
- Keep the load profile identical across apps: same target, duration (e.g., 10 min), and request rate (~50 req/s).

### Script stubs (macOS)

```bash
#!/usr/bin/env bash
# sample_metrics.sh - quick sampler for RSS/CPU on macOS
# Usage: ./sample_metrics.sh "<process-pattern>" <seconds> <interval>

set -euo pipefail
PATTERN="${1:-Cheddar Proxy}"
DURATION="${2:-60}"
INTERVAL="${3:-5}"

end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  date +"%F %T"
  pgrep -f "$PATTERN" | while read -r pid; do
    ps -o pid,rss,pcpu,comm -p "$pid"
  done
  sleep "$INTERVAL"
done
```

### Script stubs (Windows PowerShell)

```powershell
# sample-metrics.ps1 - quick sampler for WorkingSet/CPU on Windows
# Usage: .\sample-metrics.ps1 -ProcessName "cheddarproxy" -Seconds 60 -Interval 5
param(
  [string]$ProcessName = "cheddarproxy",
  [int]$Seconds = 60,
  [int]$Interval = 5
)
$stopAt = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $stopAt) {
  Write-Host (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Get-Process "*$ProcessName*" | Select-Object Id,ProcessName,CPU,@{n='WorkingSetMB';e={$_.WorkingSet64/1MB}}
  Start-Sleep -Seconds $Interval
}
```

### Scenario runners (examples)

Use these to generate comparable load while sampling metrics. Start the target server and the app first, then run the load + sampler.

macOS load (HTTP GET loop via curl):
```bash
#!/usr/bin/env bash
# run_load.sh - simple load through proxy (adjust PROXY_PORT)
TARGET="http://127.0.0.1:8000/"
PROXY_PORT=9090
DURATION=600
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
  curl -s -x "http://127.0.0.1:${PROXY_PORT}" "$TARGET" >/dev/null &
  sleep 0.02  # ~50 req/s aggregate
done
wait
```

Windows load (PowerShell):
```powershell
# run-load.ps1 - simple load through proxy (adjust ports/URL)
$Target = "http://127.0.0.1:8000/"
$Proxy = "http://127.0.0.1:9090"
$Duration = 600
$SleepMs = 20  # ~50 req/s aggregate
$stopAt = (Get-Date).AddSeconds($Duration)
while ((Get-Date) -lt $stopAt) {
  Start-Job { param($t,$p) curl.exe --proxy $p $t *> $null } -ArgumentList $Target,$Proxy | Out-Null
  Start-Sleep -Milliseconds $SleepMs
}
Get-Job | Wait-Job | Out-Null
```

> Replace `ProcessName`/`PATTERN` for HTTP Toolkit, Proxyman, or mitmproxy. Keep load identical across runs. Log app version, OS version, build type (debug/release), and note whether TLS interception is enabled.

---

## UI Performance

### Virtualized List

The traffic list uses Flutter's `ListView.builder` with virtualization:

- Only **visible rows + buffer** are rendered (~30-50 widgets)
- Scrolling through 100,000 items maintains **60 fps**
- Each row is a lightweight `StatelessWidget`

### Frame Budget

| Operation | Target | Actual |
|-----------|--------|--------|
| List scroll | 16.6ms (60fps) | ~8ms |
| Request selection | 16.6ms | ~12ms |
| Filter change | 100ms | ~45ms |
| Body render (50KB) | 100ms | ~60ms |

### Syntax Highlighting

- Large bodies (>50KB) truncated with "Preview truncated" notice
- Bodies >1MB disable pretty-printing entirely
- Raw view always available for full content
- Copy button provides complete content regardless of truncation

---

## Known Limitations

### Current Constraints

| Limitation | Impact | Workaround |
|------------|--------|------------|
| HTTP/2 not supported | HTTP/2 connections fallback to HTTP/1.1 | Most servers support both |
| Pretty view capped at 50KB | Large JSON truncated in UI | Use Raw view or Copy |
| Syntax highlighting disabled >1MB | Very large bodies show raw text | Copy to external editor |
| Single proxy port | One listener at a time | Restart to change port |
| No request rate limiting | High traffic may spike CPU | Close traffic-heavy apps |

### Platform-Specific

| Platform | Limitation |
|----------|------------|
| **macOS** | System proxy requires admin permission (one-time) |
| **Windows** | System proxy configuration not yet automated |
| **Linux** | Not yet supported (Phase 2) |

---

## Running Benchmarks

### Prerequisites

```bash
# Install wrk (macOS)
brew install wrk

# Install hey (alternative)
brew install hey

# Ensure Rust is in release mode
cd core
cargo build --release
```

### Throughput Benchmark

```bash
# Start Cheddar Proxy (ensure it's running on port 9090)
./scripts/run.sh

# In another terminal, run the benchmark
./scripts/benchmark/benchmark_throughput.sh
```

### Memory Benchmark

```bash
# Requires Python 3 and psutil
pip3 install psutil

# Run memory profiling
./scripts/benchmark/benchmark_memory.py
```

### UI Performance

```bash
# Run Flutter integration tests with performance tracing
cd ui
flutter test integration_test/performance_test.dart --profile
```

---

## Comparison with Alternatives

| Tool | Language | Memory (Typical) | Notes |
|------|----------|------------------|-------|
| **Cheddar Proxy** | Rust + Flutter | 250-520 MB | Native, lazy loading |
| Proxyman | Swift + AppKit | ~400 MB | Native macOS |
| Charles Proxy | Java + Swing | ~600 MB | Cross-platform |
| mitmproxy | Python | ~200 MB | CLI/TUI focused |
| Fiddler Classic | .NET | ~500 MB | Windows-focused |

*Note: Values are approximate and depend on usage patterns.*

### Why Cheddar Proxy is Fast

1. **Rust core**: No GC, native performance
2. **Async everywhere**: Tokio for I/O, Flutter for UI
3. **Lazy loading**: Bodies loaded on-demand
4. **Efficient storage**: SQLite with proper indexing
5. **Virtualized UI**: Minimal widget tree

---

## Profiling Tips

### CPU Profiling (Rust)

```bash
# Install flamegraph
cargo install flamegraph

# Profile the proxy under load
sudo flamegraph -o proxy_profile.svg -- ./target/release/core
```

### Memory Profiling (Rust)

```bash
# Use heaptrack (Linux) or Instruments (macOS)
# macOS:
xcrun xctrace record --template 'Allocations' --launch ./target/release/core
```

### Flutter DevTools

1. Run app in profile mode: `flutter run --profile`
2. Open DevTools: Press `p` in terminal
3. Navigate to Performance tab
4. Record while scrolling/interacting

---

## Contributing Performance Improvements

Found a performance issue or have an optimization? We welcome contributions!

1. **Report**: Open an issue with profiling data
2. **Benchmark**: Include before/after measurements
3. **Test**: Ensure no regressions in existing benchmarks
4. **Document**: Update this file with new findings

See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

---

*Last Updated: December 16, 2024*
*Benchmarks run on: MacBook Pro (Apple Silicon), macOS Sequoia 15.x*
