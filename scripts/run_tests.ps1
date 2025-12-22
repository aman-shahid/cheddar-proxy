# Run all tests (unit + integration) for Cheddar Proxy
# Usage: .\scripts\run_tests.ps1

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location "$RepoRoot\ui"

try {
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Running Unit Tests" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    flutter test
    if ($LASTEXITCODE -ne 0) { throw "Unit tests failed" }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Running E2E Integration Tests (Windows)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
    flutter test integration_test/e2e_test.dart -d windows --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "Integration tests failed" }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  ✅ All tests passed!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
}
finally {
    Pop-Location
}
