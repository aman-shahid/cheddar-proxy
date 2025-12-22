#!/bin/bash
# Build script for Cheddar Proxy
# This script builds the Rust library and creates a macOS framework

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$ROOT_DIR/core"
FLUTTER_DIR="$ROOT_DIR/ui"
FRB_CONFIG="$FLUTTER_DIR/flutter_rust_bridge.yaml"

FRB_CODEGEN="${FRB_CODEGEN:-1}"
if [ "$FRB_CODEGEN" != "0" ]; then
    echo "🔗 Regenerating Flutter/Rust bindings..."
    if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
        echo "❌ flutter_rust_bridge_codegen not found. Install with: cargo install flutter_rust_bridge_codegen@^2.0.0"
        exit 1
    fi
    pushd "$FLUTTER_DIR" >/dev/null
    flutter_rust_bridge_codegen generate --config-file "$FRB_CONFIG"
    popd >/dev/null
else
    echo "🔗 Skipping Flutter/Rust bindings regeneration (FRB_CODEGEN=0)."
fi

echo "🦀 Building Rust library..."
cd "$RUST_DIR"

# Always clean so we don't accidentally reuse stale binaries
echo "🧼 Cleaning previous Rust artifacts..."
cargo clean

# Ensure we have the right targets installed
rustup target add aarch64-apple-darwin x86_64-apple-darwin 2>/dev/null || true

# Build for both architectures (library + binaries)
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

echo "📦 Creating universal library..."

# Create output directories
FRAMEWORK_DIR="$FLUTTER_DIR/macos/Frameworks/core.framework"
OUTPUT_DIR="$FRAMEWORK_DIR/Versions/A"
mkdir -p "$OUTPUT_DIR"

# Create universal dylib (crate name: rust_lib_cheddarproxy)
LIPO_INPUT_A="$RUST_DIR/target/aarch64-apple-darwin/release/deps/librust_lib_cheddarproxy.dylib"
LIPO_INPUT_X="$RUST_DIR/target/x86_64-apple-darwin/release/deps/librust_lib_cheddarproxy.dylib"
if [ ! -f "$LIPO_INPUT_A" ] || [ ! -f "$LIPO_INPUT_X" ]; then
    echo "❌ Expected dylib not found. Did cargo build succeed?"
    exit 1
fi
UNIVERSAL_DYLIB="$OUTPUT_DIR/core"
lipo -create \
    "$LIPO_INPUT_A" \
    "$LIPO_INPUT_X" \
    -output "$UNIVERSAL_DYLIB"

# Keep a copy accessible as librust_lib_cheddarproxy.dylib for @rpath consumers
RPATH_DIR="$FLUTTER_DIR/macos/Frameworks"
mkdir -p "$RPATH_DIR"
RPATH_DYLIB="$RPATH_DIR/librust_lib_cheddarproxy.dylib"
cp "$UNIVERSAL_DYLIB" "$RPATH_DYLIB"
install_name_tool -id @rpath/librust_lib_cheddarproxy.dylib "$RPATH_DYLIB"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
    echo "🔏 Code signing core framework (identity: $SIGN_IDENTITY)..."
    codesign --force --timestamp=none --options=runtime --sign "$SIGN_IDENTITY" "$UNIVERSAL_DYLIB" || true
    codesign --force --timestamp=none --options=runtime --sign "$SIGN_IDENTITY" "$RPATH_DYLIB" || true
fi

# Use VERSION env var or default to 1.0.0
VERSION="${VERSION:-1.0.0}"

# Ensure Info.plist exists for codesigning
INFO_PLIST="$OUTPUT_DIR/Resources/Info.plist"
mkdir -p "$(dirname "$INFO_PLIST")"
cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>core</string>
    <key>CFBundleIdentifier</key>
    <string>com.cheddarproxy.core</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
</dict>
</plist>
EOF

# Create framework symlinks
cd "$FRAMEWORK_DIR"
ln -sfh A Versions/Current 2>/dev/null || true
ln -sf Versions/A/core core 2>/dev/null || true
ln -sf Versions/Current/Resources Resources 2>/dev/null || true
rm -f Info.plist
ln -s Versions/Current/Resources/Info.plist Info.plist

echo "✅ Build complete!"
echo "   Framework at: $FLUTTER_DIR/macos/Frameworks/core.framework"

echo "🧰 Building MCP bridge (universal)..."
BRIDGE_ARM="$RUST_DIR/target/aarch64-apple-darwin/release/cheddarproxy_mcp_bridge"
BRIDGE_X64="$RUST_DIR/target/x86_64-apple-darwin/release/cheddarproxy_mcp_bridge"
BRIDGE_UNIVERSAL="$FLUTTER_DIR/macos/cheddarproxy_mcp_bridge"
if [ ! -f "$BRIDGE_ARM" ] || [ ! -f "$BRIDGE_X64" ]; then
    echo "❌ Expected MCP bridge binaries not found. Did cargo build succeed?"
    exit 1
fi
lipo -create "$BRIDGE_ARM" "$BRIDGE_X64" -output "$BRIDGE_UNIVERSAL"
chmod +x "$BRIDGE_UNIVERSAL"
if command -v codesign >/dev/null 2>&1; then
    echo "🔏 Code signing MCP bridge (identity: $SIGN_IDENTITY)..."
    codesign --force --timestamp=none --options=runtime --sign "$SIGN_IDENTITY" "$BRIDGE_UNIVERSAL" || true
fi
echo "   MCP bridge staged at: $BRIDGE_UNIVERSAL"

# Also copy to build products for development
if [ -d "$FLUTTER_DIR/build/macos/Build/Products/Debug/Cheddar Proxy.app" ]; then
    echo "📋 Copying to Debug app bundle..."
    DEST="$FLUTTER_DIR/build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/core.framework"
    mkdir -p "$DEST"
    rsync -a "$FRAMEWORK_DIR/" "$DEST/"
    cp "$RPATH_DYLIB" "$FLUTTER_DIR/build/macos/Build/Products/Debug/Cheddar Proxy.app/Contents/Frameworks/librust_lib_cheddarproxy.dylib"
    cd "$DEST"
    ln -sfh A Versions/Current 2>/dev/null || true
    ln -sf Versions/A/core core 2>/dev/null || true
    ln -sf Versions/Current/Resources Resources 2>/dev/null || true
    rm -f Info.plist
    ln -s Versions/Current/Resources/Info.plist Info.plist
fi

echo "🚀 Ready to run: cd ui && flutter run -d macos"
