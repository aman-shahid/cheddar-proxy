#!/bin/bash
# Cheddar Proxy Latency Benchmark
# Compares latency with and without proxy

set -e

# Get script directory and create results folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results"
mkdir -p "$RESULTS_DIR"

# Generate timestamped output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${RESULTS_DIR}/latency_${TIMESTAMP}.txt"

# Run main script, capturing output to both console and file
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo "Results will be saved to: $OUTPUT_FILE"
echo ""

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9090}"
TARGET_URL="${TARGET_URL:-http://httpbin.org/get}"
REQUESTS="${REQUESTS:-100}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Cheddar Proxy Latency Benchmark                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Proxy:    $PROXY_HOST:$PROXY_PORT"
echo "  Target:   $TARGET_URL"
echo "  Requests: $REQUESTS"
echo ""

# Check for curl
if ! command -v curl &> /dev/null; then
    echo "❌ Error: curl not found"
    exit 1
fi

# Function to measure latency
measure_latency() {
    local use_proxy=$1
    local total=0
    local count=0
    local min=999999
    local max=0
    
    for i in $(seq 1 $REQUESTS); do
        if [ "$use_proxy" = "true" ]; then
            time_ms=$(curl -s -o /dev/null -w "%{time_total}" \
                -x "http://$PROXY_HOST:$PROXY_PORT" \
                "$TARGET_URL" 2>/dev/null)
        else
            time_ms=$(curl -s -o /dev/null -w "%{time_total}" \
                "$TARGET_URL" 2>/dev/null)
        fi
        
        # Convert to milliseconds (curl returns seconds)
        time_ms=$(echo "$time_ms * 1000" | bc)
        time_int=${time_ms%.*}
        
        total=$(echo "$total + $time_ms" | bc)
        count=$((count + 1))
        
        if (( $(echo "$time_ms < $min" | bc -l) )); then
            min=$time_ms
        fi
        if (( $(echo "$time_ms > $max" | bc -l) )); then
            max=$time_ms
        fi
        
        # Progress
        if [ $((i % 10)) -eq 0 ]; then
            echo -ne "\r  Progress: $i/$REQUESTS"
        fi
    done
    
    echo -ne "\r                        \r"
    
    avg=$(echo "scale=2; $total / $count" | bc)
    echo "  Requests: $count"
    echo "  Avg:      ${avg}ms"
    echo "  Min:      ${min}ms"
    echo "  Max:      ${max}ms"
    
    # Return average for comparison
    echo "$avg" > /tmp/latency_result
}

# Test 1: Direct connection (no proxy)
echo "═══════════════════════════════════════════════════════════════"
echo "Test 1: Direct Connection (baseline)"
echo "═══════════════════════════════════════════════════════════════"
measure_latency "false"
DIRECT_AVG=$(cat /tmp/latency_result)

# Check if proxy is running
if ! nc -z "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null; then
    echo ""
    echo "⚠️  Proxy is not running on $PROXY_HOST:$PROXY_PORT"
    echo "   Skipping proxy benchmark. Start Cheddar Proxy to compare."
    exit 0
fi

echo ""

# Test 2: Through proxy
echo "═══════════════════════════════════════════════════════════════"
echo "Test 2: Through Cheddar Proxy"
echo "═══════════════════════════════════════════════════════════════"
measure_latency "true"
PROXY_AVG=$(cat /tmp/latency_result)

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Summary"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Direct Connection:  ${DIRECT_AVG}ms (average)"
echo "  Through Proxy:      ${PROXY_AVG}ms (average)"

OVERHEAD=$(echo "scale=2; $PROXY_AVG - $DIRECT_AVG" | bc)
echo ""
echo "  ➜ Proxy Overhead:   ${OVERHEAD}ms"
echo ""

# Cleanup
rm -f /tmp/latency_result
