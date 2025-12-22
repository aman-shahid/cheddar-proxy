#!/bin/bash
# Cheddar Proxy Startup Time Benchmark
# Measures time from launch to proxy server ready

set -e

# Get script directory and create results folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../benchmark_results"
mkdir -p "$RESULTS_DIR"

# Generate timestamped output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${RESULTS_DIR}/startup_${TIMESTAMP}.txt"

# Run main script, capturing output to both console and file
exec > >(tee -a "$OUTPUT_FILE") 2>&1

echo "Results will be saved to: $OUTPUT_FILE"
echo ""

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-9090}"
APP_PATH="${APP_PATH:-./ui/build/macos/Build/Products/Release/cheddarproxy.app}"
ITERATIONS="${ITERATIONS:-5}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Cheddar Proxy Startup Time Benchmark                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "⚠️  Release build not found at: $APP_PATH"
    echo "   Building release version..."
    echo ""
    
    cd ui
    flutter build macos --release
    cd ..
    
    # Update path for default location
    APP_PATH="./ui/build/macos/Build/Products/Release/cheddarproxy.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find or build the app"
    exit 1
fi

echo "App path: $APP_PATH"
echo "Iterations: $ITERATIONS"
echo ""

# Function to measure startup time
measure_startup() {
    local iteration=$1
    
    # Kill any existing instance
    pkill -f "cheddarproxy" 2>/dev/null || true
    sleep 1
    
    # Start timer
    local start_time=$(python3 -c "import time; print(time.time())")
    
    # Launch app
    open -a "$APP_PATH" &
    
    # Wait for proxy to be ready
    local max_wait=30
    local waited=0
    while ! nc -z "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null; do
        sleep 0.1
        waited=$(echo "$waited + 0.1" | bc)
        if (( $(echo "$waited > $max_wait" | bc -l) )); then
            echo "  ❌ Timeout waiting for proxy"
            return 1
        fi
    done
    
    # Stop timer
    local end_time=$(python3 -c "import time; print(time.time())")
    
    # Calculate duration
    local duration=$(echo "$end_time - $start_time" | bc)
    
    # Kill the app
    pkill -f "cheddarproxy" 2>/dev/null || true
    sleep 1
    
    echo "  Iteration $iteration: ${duration}s"
    echo "$duration"
}

echo "═══════════════════════════════════════════════════════════════"
echo "Running startup measurements..."
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Collect measurements
times=()
for i in $(seq 1 $ITERATIONS); do
    result=$(measure_startup $i)
    # Get the last line (the time value)
    time_val=$(echo "$result" | tail -1)
    times+=("$time_val")
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Results"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Calculate statistics
total=0
min=999
max=0
for t in "${times[@]}"; do
    total=$(echo "$total + $t" | bc)
    if (( $(echo "$t < $min" | bc -l) )); then
        min=$t
    fi
    if (( $(echo "$t > $max" | bc -l) )); then
        max=$t
    fi
done

avg=$(echo "scale=3; $total / $ITERATIONS" | bc)

echo "  Iterations: $ITERATIONS"
echo "  Average:    ${avg}s"
echo "  Min:        ${min}s"
echo "  Max:        ${max}s"
echo ""

# Cleanup
pkill -f "cheddarproxy" 2>/dev/null || true

echo "Benchmark complete!"
