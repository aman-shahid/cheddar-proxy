# build_release.ps1 - Windows Release Build Script for CheddarProxy
# Usage: .\scripts\build_release.ps1 [-Version "1.0.0"] [-BuildNumber 1]

param(
    [string]$Version = $env:VERSION,
    [int]$BuildNumber = $env:BUILD_NUMBER
)

# Default values if not provided
if (-not $Version) { $Version = "1.0.0" }
if (-not $BuildNumber) { $BuildNumber = 1 }
$BuildDir = $env:FLUTTER_BUILD_DIR
if (-not $BuildDir) { $BuildDir = "build" }

# Normalize version (strip leading 'v' if present)
if ($Version.StartsWith("v")) {
    $Version = $Version.Substring(1)
}

$ErrorActionPreference = "Stop"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  CheddarProxy Windows Release Builder" -ForegroundColor Cyan
Write-Host "  Version: $Version (Build $BuildNumber)" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

# Ensure we're in the project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
Set-Location $RepoRoot

# Step 1: Generate Flutter-Rust bindings
Write-Host "`n[1/4] Generating Rust bindings..." -ForegroundColor Yellow
Push-Location ui
try {
    flutter_rust_bridge_codegen generate
    if ($LASTEXITCODE -ne 0) { throw "Binding generation failed" }
} finally {
    Pop-Location
}

# Step 2: Build Rust core
Write-Host "`n[2/4] Building Rust core..." -ForegroundColor Yellow
Push-Location core
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
} finally {
    Pop-Location
}

# Step 3: Copy Rust DLL to Flutter assets
Write-Host "`n[3/4] Copying Rust library..." -ForegroundColor Yellow
$RustDll = "core\target\release\rust_lib_cheddarproxy.dll"
$FlutterLibDir = "ui\windows\libs"

if (-not (Test-Path $FlutterLibDir)) {
    New-Item -ItemType Directory -Path $FlutterLibDir -Force | Out-Null
}

if (Test-Path $RustDll) {
    Copy-Item $RustDll -Destination $FlutterLibDir -Force
    Write-Host "  Copied rust_lib_CheddarProxy.dll" -ForegroundColor Green
} else {
    Write-Host "  Warning: DLL not found at $RustDll" -ForegroundColor Red
}

# Step 4: Build Flutter Windows
Write-Host "`n[4/4] Building Flutter Windows app..." -ForegroundColor Yellow
Push-Location ui
try {
    $env:FLUTTER_BUILD_DIR = $BuildDir
    flutter build windows --release --build-name="$Version" --build-number=$BuildNumber
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed" }
} finally {
    Pop-Location
}

# Output location
$OutputDir = "ui\$BuildDir\windows\x64\runner\Release"
Write-Host "`n======================================" -ForegroundColor Green
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "  Output: $OutputDir" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green

# Stage MCP bridge binary alongside the app for stdio-based clients.
$BridgeExe = "core\target\release\cheddarproxy_mcp_bridge.exe"
if (Test-Path $BridgeExe) {
    Copy-Item $BridgeExe -Destination "$OutputDir\cheddarproxy_mcp_bridge.exe" -Force
    Write-Host "  Staged MCP bridge -> $OutputDir\cheddarproxy_mcp_bridge.exe" -ForegroundColor Green
} else {
    Write-Host "  Warning: MCP bridge not found at $BridgeExe" -ForegroundColor Yellow
}

# Optional: Create ZIP archive (standardized name)
$ZipName = "CheddarProxy-$Version-windows.zip"
$ReleasesDir = "$BuildDir\releases"

if (-not (Test-Path $ReleasesDir)) {
    New-Item -ItemType Directory -Path $ReleasesDir -Force | Out-Null
}

Write-Host "`nCreating ZIP archive..." -ForegroundColor Yellow
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$ReleasesDir\$ZipName" -Force
Write-Host "  Created: $ReleasesDir\$ZipName" -ForegroundColor Green
