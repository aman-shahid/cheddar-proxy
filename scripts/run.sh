#!/bin/bash
# Convenience script to build Rust core, codesign frameworks, and run Flutter UI
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$ROOT_DIR/core"
FLUTTER_DIR="$ROOT_DIR/ui"
FRAMEWORK_PATH="$FLUTTER_DIR/macos/Frameworks/core.framework/Versions/A/core"
APP_FRAMEWORK_PATH="$FLUTTER_DIR/build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/core.framework/Versions/A/core"
RPATH_DYLIB_PATH="$FLUTTER_DIR/macos/Frameworks/librust_lib_cheddarproxy.dylib"
APP_RPATH_DYLIB_PATH="$FLUTTER_DIR/build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/librust_lib_cheddarproxy.dylib"

# Default: skip codegen for faster dev loops; set FRB_CODEGEN=1 to regenerate bindings.
: "${FRB_CODEGEN:=0}"

# Ensure Flutter artifacts are clean before rebuilding
echo "🧹 Cleaning Flutter build artifacts..."
pushd "$FLUTTER_DIR" >/dev/null
rm -rf macos/Frameworks/core.framework
rm -rf macos/Frameworks/librust_lib_cheddarproxy.dylib
rm -rf "build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/core.framework"
rm -rf "build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/librust_lib_cheddarproxy.dylib"
popd >/dev/null

pushd "$ROOT_DIR" >/dev/null
./scripts/build_rust.sh
popd >/dev/null

pushd "$FLUTTER_DIR" >/dev/null
if [ -f "$FRAMEWORK_PATH" ]; then
  codesign --force --sign - "$FRAMEWORK_PATH"
fi
if [ -f "$APP_FRAMEWORK_PATH" ]; then
  codesign --force --sign - "$APP_FRAMEWORK_PATH"
fi
if [ -f "$RPATH_DYLIB_PATH" ]; then
  codesign --force --sign - "$RPATH_DYLIB_PATH"
fi
if [ -f "$APP_RPATH_DYLIB_PATH" ]; then
  codesign --force --sign - "$APP_RPATH_DYLIB_PATH"
fi
echo "✅ Rust build complete. Starting Flutter app..."
flutter run -d macos
popd >/dev/null
