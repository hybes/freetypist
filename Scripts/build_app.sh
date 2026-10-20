#!/bin/bash
set -e

# Finder/iCloud adds resource forks in Documents; codesign rejects those.
export COPYFILE_DISABLE=1
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/freetypist-build}"

BUILD_CONFIG="${BUILD_CONFIG:-release}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [ "$1" = "--debug" ]; then
    BUILD_CONFIG="debug"
fi

strip_disallowed_xattrs() {
    local root="$1"
    # Only the bundle root. Walking files here lets File Provider restore FinderInfo
    # before codesign, which is what fails in ~/Documents.
    xattr -d com.apple.FinderInfo "$root" 2>/dev/null || true
    xattr -d com.apple.ResourceFork "$root" 2>/dev/null || true
    xattr -d com.apple.fileprovider.fpfs#P "$root" 2>/dev/null || true
}

echo "🔨 Building FreeTypist ($BUILD_CONFIG incremental build, low-CPU mode)..."
swift build -c "$BUILD_CONFIG" -j 4 \
    --scratch-path "$SCRATCH_PATH" \
    --disable-sandbox \
    --cache-path /tmp/swiftpm-cache \
    --config-path /tmp/swiftpm-config \
    --security-path /tmp/swiftpm-security \
    -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

APP_NAME="FreeTypist"
BUILD_DIR="$SCRATCH_PATH/$BUILD_CONFIG"
OUTPUT_DIR="dist"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

echo "📦 Packaging $APP_NAME.app incrementally..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# -X skips Finder/SIP xattrs (com.apple.provenance) that codesign rejects
cp -X "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -X "Scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Use a pinned portable engine; local Homebrew builds may require the build Mac's OS.
LLAMA_BIN="${LLAMA_SERVER_PATH:-$(bash Scripts/fetch_engine.sh)}"
rm -rf "$APP_BUNDLE/Contents/lib" "$APP_BUNDLE/Contents/Frameworks"
python3 Scripts/bundle_llama.py "$LLAMA_BIN" "$APP_BUNDLE"

# SwiftPM links binary frameworks but our manual .app packager must embed them.
SPARKLE_ROOT="$SCRATCH_PATH/artifacts/sparkle/Sparkle"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP_BUNDLE/Contents/Resources/Licenses"
rm -f "$APP_BUNDLE/Contents/Resources/Licenses/Sparkle.txt" "$APP_BUNDLE/Contents/Resources/Licenses/llama.cpp.txt"
cp -X "$SCRATCH_PATH/checkouts/Sparkle/LICENSE" "$APP_BUNDLE/Contents/Resources/Licenses/Sparkle.txt"
if [ -f "$(dirname "$LLAMA_BIN")/LICENSE" ]; then
    cp -X "$(dirname "$LLAMA_BIN")/LICENSE" "$APP_BUNDLE/Contents/Resources/Licenses/llama.cpp.txt"
else
    cp -X Resources/Licenses/llama.cpp.txt "$APP_BUNDLE/Contents/Resources/Licenses/llama.cpp.txt"
fi

# Generate App Icon if present
if [ -f "Resources/AppIcon.icns" ]; then
    if [ ! -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ] || [ "Resources/AppIcon.icns" -nt "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
        cp -X "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    fi
fi

echo "🔐 Codesigning application bundle..."
strip_disallowed_xattrs "$APP_BUNDLE"
SIGNING_IDENTITY="$SIGNING_IDENTITY" bash Scripts/sign_app.sh "$APP_BUNDLE"
if [ -f "$APP_BUNDLE/Contents/MacOS/llama-server" ]; then
    "$APP_BUNDLE/Contents/MacOS/llama-server" --version
fi
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Accessibility: this build is ad-hoc signed. Re-add this app in System Settings after rebuilding if permission stops working."
    echo "Set SIGNING_IDENTITY to your Apple Development or Developer ID certificate to keep a stable signing identity."
fi

echo "✅ Successfully built $APP_BUNDLE"
echo "You can now run: open $APP_BUNDLE"
