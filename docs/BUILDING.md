# Building Cheddar Proxy

This document covers building the Rust core and Flutter desktop app from source on macOS and Windows. Use the quick starts if you already have the toolchains; otherwise follow the platform setup notes.

## Prerequisites (Common)

- Flutter 3.19+ with desktop targets enabled.
- Rust 1.75+ with `cargo` in PATH.
- Dart/Flutter dependencies: run `flutter pub get` from `ui/`.

## macOS Quick Start

```bash
# From repo root
cd core
cargo build --release
cd ..
./scripts/build_rust.sh          # regenerates FRB bindings + builds universal dylib
cd ui
flutter run -d macos
```

Requirements: Xcode, CocoaPods, and Flutter desktop enabled (`flutter config --enable-macos-desktop`).

## Windows Quick Start

```powershell
# 1) Ensure PATH has Flutter, Cargo, NASM, LLVM/Clang, CMake
$env:PATH = @(
  "C:\src\flutter\bin",
  "$env:USERPROFILE\.cargo\bin",
  "C:\Program Files\NASM",
  "C:\Program Files\LLVM\bin",
  "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin",
  $env:PATH
) -join ";"

# 2) Build and run
cd core
cargo build --release
cd ..\ui
flutter run -d windows
```

Requirements:
- Windows 10/11 64-bit with Developer Mode enabled (for Flutter symlinks)
- Visual Studio 2022 with **Desktop development with C++** workload
- NASM
- LLVM/Clang (for `libclang.dll` used by ffigen)
- Flutter desktop enabled (`flutter config --enable-windows-desktop`)
- Cargo tools: `flutter_rust_bridge_codegen` (install via `cargo install flutter_rust_bridge_codegen@^2.0.0`)

If `ffigen` complains about `libclang.dll`, ensure `C:\Program Files\LLVM\bin` is on PATH or set `LIBCLANG_PATH` to that DLL.

## Full Build Steps (either platform)

From the repo root:

```bash
# Build the Rust core (shared library for Flutter)
cd core
cargo build --release

# Generate Rust <-> Flutter bindings and platform artifacts (uses flutter_rust_bridge_codegen)
cd ..
./scripts/build_rust.sh

# Build/run the Flutter desktop app
cd ui
flutter run -d macos     # or -d windows
```

## Tests

```bash
# Core tests
cd core
cargo test

# Flutter tests
cd ../ui
flutter test
```

## Release builds

- macOS: run `./scripts/build_release.sh` (produces a DMG under `build/releases/`).
- Windows: run `./scripts/build_release.ps1 -Version <semver> -BuildNumber <build>` (produces a ZIP under `build/releases/`).

## Certificates and system proxy

Cheddar Proxy generates certificates locally; none are committed to the repository. The app will regenerate certificates as needed—just follow platform prompts to trust the generated root certificate and set the system proxy when running the app.

### Windows system proxy note

The app includes a PowerShell-based system proxy helper; it still needs validation across Windows SKUs. If proxy auto-config fails, set the system proxy manually to `127.0.0.1:<port>` while the app is running.
