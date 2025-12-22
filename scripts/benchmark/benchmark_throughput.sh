#!/bin/bash
# Cheddar Proxy Throughput Benchmark
# Measures requests/second through the proxy

set -e

# Get script directory and create results folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results"
mkdir -p "$RESULTS_DIR"

# Generate timestamped output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${RESULTS_DIR}/throughput_${TIMESTAMP}.txt"

# Run main script, capturing output to both console and file
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo "Results will be saved to: $OUTPUT_FILE"
echo ""

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9090}"
TARGET_URL="${TARGET_URL:-http://httpbin.org/get}"
DURATION="${DURATION:-120}"
THREADS="${THREADS:-16}"
CONNECTIONS="${CONNECTIONS:-400}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Cheddar Proxy Throughput Benchmark                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Proxy:       $PROXY_HOST:$PROXY_PORT"
echo "  Target:      $TARGET_URL"
echo "  Duration:    ${DURATION}s"
echo "  Threads:     $THREADS"
echo "  Connections: $CONNECTIONS"
echo ""

# Check if proxy is running
if ! nc -z "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null; then
    echo "❌ Error: Proxy is not running on $PROXY_HOST:$PROXY_PORT"
    echo "   Please start Cheddar Proxy first: ./scripts/run.sh"
    exit 1
fi

echo "✓ Proxy is running"
echo ""

# Check for benchmarking tools
# Prefer 'hey' over 'wrk' because hey supports HTTP proxies with -x flag
# wrk does not honor http_proxy environment variables
if command -v hey &> /dev/null; then
    BENCH_TOOL="hey"
elif command -v wrk &> /dev/null; then
    BENCH_TOOL="wrk"
    echo "⚠️  Warning: wrk does not support HTTP proxies."
    echo "   Traffic may not route through the proxy correctly."
    echo "   For accurate proxy benchmarking, install 'hey': brew install hey"
    echo ""
else
    echo "❌ Error: No benchmarking tool found."
    echo "   Please install hey (recommended) or wrk:"
    echo "     brew install hey"
    echo "     # or"
    echo "     brew install wrk"
    exit 1
fi

echo "Using benchmark tool: $BENCH_TOOL"
echo ""

# Run benchmark
echo "═══════════════════════════════════════════════════════════════"
echo "Starting benchmark..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$BENCH_TOOL" = "wrk" ]; then
    # wrk benchmark (requires proxy environment variable or proxychains)
    # For simplicity, we'll use a local echo server
    echo "Running wrk benchmark (${DURATION}s)..."
    echo ""
    
    # If httpbin is used, we go direct through proxy
    http_proxy="http://$PROXY_HOST:$PROXY_PORT" \
    https_proxy="http://$PROXY_HOST:$PROXY_PORT" \
    wrk -t"$THREADS" -c"$CONNECTIONS" -d"${DURATION}s" --latency "$TARGET_URL"
    
elif [ "$BENCH_TOOL" = "hey" ]; then
    echo "Running hey benchmark (${DURATION}s)..."
    echo ""
    
    hey -z "${DURATION}s" \
        -c "$CONNECTIONS" \
        -x "http://$PROXY_HOST:$PROXY_PORT" \
        "$TARGET_URL"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Benchmark complete!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Tips:"
echo "  • Run against a local server for more accurate proxy overhead measurement"
echo "  • Compare with direct connection (no proxy) for baseline"
echo "  • Use 'DURATION=60 ./scripts/benchmark/benchmark_throughput.sh' for longer tests"
