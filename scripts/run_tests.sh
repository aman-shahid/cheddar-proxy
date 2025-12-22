#!/bin/bash
# Run all tests (unit + integration) for Cheddar Proxy
# Usage: ./scripts/run_tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR/ui"

echo "═══════════════════════════════════════════════════"
echo "  Running Unit Tests"
echo "═══════════════════════════════════════════════════"
flutter test

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Running E2E Integration Tests (macOS)"
echo "═══════════════════════════════════════════════════"
flutter test integration_test/e2e_test.dart -d macos --timeout 5m

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ All tests passed!"
echo "═══════════════════════════════════════════════════"
