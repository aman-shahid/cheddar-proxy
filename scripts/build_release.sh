#!/bin/bash
# ==============================================================================
# CheddarProxy Release Build Script
# ==============================================================================
# Usage:
#   ./scripts/build_release.sh              # Uses version from pubspec.yaml
#   ./scripts/build_release.sh 1.2.3        # Override version
#   VERSION=1.2.3 ./scripts/build_release.sh # Via environment variable
#
# Output:
#   build/releases/CheddarProxy-{version}-macos.dmg
# ==============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Navigate to Flutter project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/ui"

cd "$FLUTTER_DIR"

echo -e "${GREEN}📦 Cheddar Proxy Release Builder${NC}"
echo "========================================"

# ==============================================================================
# VERSION HANDLING
# ==============================================================================
# Priority: CLI argument > Environment variable > pubspec.yaml

if [ -n "$1" ]; then
    VERSION="$1"
    echo -e "${YELLOW}Using version from CLI: $VERSION${NC}"
elif [ -n "$VERSION" ]; then
    echo -e "${YELLOW}Using version from environment: $VERSION${NC}"
else
    # Extract version from pubspec.yaml
    VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
    echo -e "Using version from pubspec.yaml: $VERSION"
fi

# Validate version format (semver: x.y.z)
# Strip 'v' prefix if present
if [[ "$VERSION" =~ ^v ]]; then
    VERSION="${VERSION:1}"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}Error: Invalid version format '$VERSION'. Expected: x.y.z (or v.x.y.z)${NC}"
    exit 1
fi

APP_NAME="CheddarProxy"
DMG_NAME="${APP_NAME}-${VERSION}-macos.dmg"
RELEASE_DIR="$PROJECT_ROOT/build/releases"

echo "Version: $VERSION"
echo "Output: $RELEASE_DIR/$DMG_NAME"
echo "========================================"

# ==============================================================================
# CLEAN PREVIOUS BUILD
# ==============================================================================
echo -e "\n${GREEN}🧹 Cleaning previous builds...${NC}"
flutter clean
rm -rf "$PROJECT_ROOT/build/macos"
mkdir -p "$RELEASE_DIR"

# ==============================================================================
# BUILD RUST CORE
# ==============================================================================
echo -e "\n${GREEN}🦀 Building Rust core...${NC}"
export VERSION
FRB_CODEGEN=1 bash "$PROJECT_ROOT/scripts/build_rust.sh"


# ==============================================================================
# BUILD FLUTTER MACOS APP
# ==============================================================================
echo -e "\n${GREEN}🔨 Building Flutter macOS release...${NC}"

# Update pubspec version if different from CLI/env
CURRENT_PUBSPEC_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
if [ "$VERSION" != "$CURRENT_PUBSPEC_VERSION" ]; then
    echo "Updating pubspec.yaml version to $VERSION..."
    sed -i '' "s/^version: .*/version: $VERSION+1/" pubspec.yaml
fi

# Build release
BUILD_ARGS="--release"
if [ -n "$BUILD_NUMBER" ]; then
    echo "Using build number: $BUILD_NUMBER"
    BUILD_ARGS="$BUILD_ARGS --build-number=$BUILD_NUMBER"
fi

flutter build macos $BUILD_ARGS

# Verify build output
# Flutter sometimes emits product names with spaces (from Xcode project).
APP_BUNDLE="$FLUTTER_DIR/build/macos/Build/Products/Release/CheddarProxy.app"
if [ ! -d "$APP_BUNDLE" ]; then
    ALT_APP_BUNDLE="$FLUTTER_DIR/build/macos/Build/Products/Release/Cheddar Proxy.app"
    if [ -d "$ALT_APP_BUNDLE" ]; then
        echo "Renaming '$ALT_APP_BUNDLE' to 'CheddarProxy.app' for consistency..."
        mv "$ALT_APP_BUNDLE" "$FLUTTER_DIR/build/macos/Build/Products/Release/CheddarProxy.app"
        APP_BUNDLE="$FLUTTER_DIR/build/macos/Build/Products/Release/CheddarProxy.app"
    else
        echo -e "${RED}Error: Build failed. App bundle not found at $APP_BUNDLE or $ALT_APP_BUNDLE${NC}"
        exit 1
    fi
fi

# Copy MCP bridge into the app bundle for MCP stdio clients
BRIDGE_SRC="$FLUTTER_DIR/macos/cheddarproxy_mcp_bridge"
BRIDGE_DEST="$APP_BUNDLE/Contents/MacOS/cheddarproxy_mcp_bridge"
if [ -f "$BRIDGE_SRC" ]; then
    echo "🔗 Staging MCP bridge into app bundle..."
    cp "$BRIDGE_SRC" "$BRIDGE_DEST"
    chmod +x "$BRIDGE_DEST"
else
    echo -e "${YELLOW}Warning: MCP bridge not found at $BRIDGE_SRC; stdio MCP clients may not spawn successfully.${NC}"
fi

echo -e "${GREEN}✅ Build successful!${NC}"

# ==============================================================================
# CREATE DMG
# ==============================================================================
echo -e "\n${GREEN}📀 Creating DMG installer...${NC}"

DMG_PATH="$RELEASE_DIR/$DMG_NAME"

# Remove existing DMG if present
rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
DMG_TEMP="$PROJECT_ROOT/build/dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

# Copy app to temp directory
cp -R "$APP_BUNDLE" "$DMG_TEMP/"

# Create symlink to Applications folder
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$DMG_PATH"

# Cleanup temp
rm -rf "$DMG_TEMP"

# ==============================================================================
# SUMMARY
# ==============================================================================
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "========================================"
echo -e "${GREEN}✅ Release build complete!${NC}"
echo "========================================"
echo "Version:  $VERSION"
echo "File:     $DMG_PATH"
echo "Size:     $DMG_SIZE"
echo ""
echo "To test locally:"
echo "  open \"$DMG_PATH\""
echo ""
echo "For GitHub Release, upload: $DMG_NAME"
echo "========================================"
