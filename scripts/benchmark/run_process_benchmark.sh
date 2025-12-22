#!/usr/bin/env bash
# Unified benchmark runner (macOS/Linux)
# - Starts a local target server
# - Drives load through the target proxy
# - Samples process RSS/CPU
# Results go to benchmark_results/metrics_<process>_<timestamp>.txt

set -euo pipefail

PROCESS_NAME="${PROCESS_NAME:-Cheddar Proxy}"
PROCESS_PID="${PROCESS_PID:-}"
PROXY_PORT="${PROXY_PORT:-9090}"
TARGET="${TARGET:-http://127.0.0.1:8001/}"
DURATION="${DURATION:-300}"      # seconds
INTERVAL="${INTERVAL:-5}"        # sampling interval
LOAD_SLEEP_MS="${LOAD_SLEEP_MS:-20}" # default ~50 req/s (used if STEP pattern is disabled)
USE_STEP_PATTERN="${USE_STEP_PATTERN:-1}" # 1 to enable stepped load
# Step pattern: list of "sleep_ms,duration_s" pairs (lower sleep = higher RPS)
# Defaults: 10 rps warmup -> 25 -> 50 -> 100 -> 200 -> cooldown 10
STEP_PATTERN="${STEP_PATTERN:-100,60 40,90 20,90 10,90 5,90 100,60}"
VENV_DIR="${VENV_DIR:-.venv}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$ROOT_DIR/benchmark_results"
mkdir -p "$RESULTS_DIR"
COUNT_FILE="$(mktemp)"

# Ensure Python deps are available (creates/uses .venv locally)
if [ -z "${VIRTUAL_ENV:-}" ]; then
  if [ ! -d "$ROOT_DIR/$VENV_DIR" ]; then
    echo "Creating virtualenv at $ROOT_DIR/$VENV_DIR ..."
    python3 -m venv "$ROOT_DIR/$VENV_DIR"
  fi
  # shellcheck source=/dev/null
  . "$ROOT_DIR/$VENV_DIR/bin/activate"
fi

python3 - <<'PY'
import importlib.util, subprocess, sys
needed = ["psutil", "requests"]
missing = [p for p in needed if importlib.util.find_spec(p) is None]
if missing:
    print(f"Installing missing packages: {', '.join(missing)}")
    subprocess.check_call([sys.executable, "-m", "pip", "install", *missing])
PY

echo "Process:       $PROCESS_NAME"
if [ -n "$PROCESS_PID" ]; then
  echo "Process PID:   $PROCESS_PID"
fi
echo "Proxy port:    $PROXY_PORT"
echo "Target:        $TARGET"
echo "Duration:      $DURATION s"
echo "Sample every:  $INTERVAL s"
echo "Load sleep:    ${LOAD_SLEEP_MS}ms (~50 req/s)"
echo

# Basic proxy reachability check (best effort)
if command -v nc >/dev/null 2>&1; then
  if ! nc -z 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; then
    echo "❌ Proxy not reachable on 127.0.0.1:$PROXY_PORT. Start it or set PROXY_PORT."
    exit 1
  fi
fi

# PID sanity check if provided
if [ -n "$PROCESS_PID" ]; then
  if ! ps -p "$PROCESS_PID" >/dev/null 2>&1; then
    echo "❌ PID $PROCESS_PID not found. Start the process or update PROCESS_PID."
    exit 1
  fi
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  if [[ -n "${LOAD_PID:-}" ]]; then kill "$LOAD_PID" 2>/dev/null || true; fi
  rm -f "$COUNT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# 1) Start local target server
echo "Starting local target server on 127.0.0.1:8001 ..."
pushd "$ROOT_DIR" >/dev/null
python3 -m http.server 8001 >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null
sleep 1

# 2) Start load generator in background
echo "Starting load generator through proxy $PROXY_PORT ..."
LOAD_START_EPOCH=$(date +%s)
(
  count=0
  if [ "$USE_STEP_PATTERN" = "1" ]; then
    for step in $STEP_PATTERN; do
      SLEEP_MS="${step%,*}"
      DURATION_S="${step#*,}"
      echo "  Step: sleep=${SLEEP_MS}ms (~$((1000 / SLEEP_MS)) req/s), duration=${DURATION_S}s"
      end_step=$((SECONDS + DURATION_S))
      while [ $SECONDS -lt $end_step ]; do
        if curl -s -x "http://127.0.0.1:${PROXY_PORT}" "$TARGET" >/dev/null; then
          count=$((count + 1))
        fi
        python3 - <<EOF >/dev/null
import time
time.sleep(${SLEEP_MS}/1000)
EOF
      done
    done
  else
    end=$((SECONDS + DURATION))
    while [ $SECONDS -lt $end ]; do
      if curl -s -x "http://127.0.0.1:${PROXY_PORT}" "$TARGET" >/dev/null; then
        count=$((count + 1))
      fi
      python3 - <<EOF >/dev/null
import time
time.sleep(${LOAD_SLEEP_MS}/1000)
EOF
    done
  fi
  echo "$count" > "$COUNT_FILE"
) &
LOAD_PID=$!

# 3) Sample process metrics
echo "Sampling process metrics..."
if [ -n "$PROCESS_PID" ]; then
  python3 "$SCRIPT_DIR/benchmark_process_metrics.py" \
    --pid "$PROCESS_PID" \
    --duration "$DURATION" \
    --interval "$INTERVAL" \
    --proxy-port "$PROXY_PORT" || true
else
  python3 "$SCRIPT_DIR/benchmark_process_metrics.py" \
    --process-name "$PROCESS_NAME" \
    --duration "$DURATION" \
    --interval "$INTERVAL" \
    --proxy-port "$PROXY_PORT" || true
fi

# Wait for load job to finish and report throughput
if [[ -n "${LOAD_PID:-}" ]]; then
  wait "$LOAD_PID" 2>/dev/null || true
fi
LOAD_END_EPOCH=$(date +%s)
if [ -f "$COUNT_FILE" ]; then
  total_requests=$(cat "$COUNT_FILE")
  elapsed=$((LOAD_END_EPOCH - LOAD_START_EPOCH))
  if [ "$elapsed" -gt 0 ]; then
    rps=$(python3 - <<EOF
total=$total_requests
elapsed=$elapsed
if elapsed == 0:
    print("n/a")
else:
    print(f"{total/elapsed:.2f}")
EOF
)
    summary="Throughput summary: requests=${total_requests}, elapsed=${elapsed}s, avg_rps=${rps}"
    echo "$summary"
    # Append to latest metrics log if present
    latest_metrics=$(ls -t "$RESULTS_DIR"/metrics_*.txt 2>/dev/null | head -1 || true)
    if [ -n "$latest_metrics" ] && [ -f "$latest_metrics" ]; then
      echo "$summary" >> "$latest_metrics"
    fi
  fi
fi

echo "Done. Logs are in $RESULTS_DIR."
