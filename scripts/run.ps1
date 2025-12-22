# run.ps1 - Run Cheddar Proxy on Windows
# Usage: .\scripts\run.ps1           (debug mode, default)
#        .\scripts\run.ps1 -Release  (release mode)
#        .\scripts\run.ps1 -Clean    (clean build artifacts first)

param(
    [switch]$Release,
    [switch]$SkipBuild,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# Set up PATH for required tools
$env:PATH = @(
    "C:\src\flutter\bin",
    "$env:USERPROFILE\.cargo\bin",
    "C:\Program Files\NASM",
    "C:\Program Files\LLVM\bin",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
    $env:PATH
) -join ";"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
Set-Location $RepoRoot

# Clean build artifacts if requested
if ($Clean) {
    Write-Host "Cleaning build artifacts..." -ForegroundColor Yellow
    Remove-Item core\target -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item ui\build -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item ui\.dart_tool -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item build -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Clean complete." -ForegroundColor Green
}

if (-not $SkipBuild) {
    Write-Host "Building Rust core..." -ForegroundColor Cyan
    Push-Location core
    if ($Release) {
        cargo build --release
    } else {
        cargo build
    }
    if ($LASTEXITCODE -ne 0) { 
        Pop-Location
        throw "Rust build failed" 
    }
    Pop-Location
}

Write-Host "Launching Cheddar Proxy..." -ForegroundColor Green
Push-Location ui
if ($Release) {
    flutter run -d windows --release
} else {
    flutter run -d windows  # Debug mode with logs
}
Pop-Location
