#!/bin/bash
set -e

# Finder/iCloud adds resource forks in Documents; codesign rejects those.
export COPYFILE_DISABLE=1
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/freetypist-build}"

BUILD_CONFIG="${BUILD_CONFIG:-release}"
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

# Bundle llama-server into app bundle only if missing or updated (saves ~30MB copy & codesign CPU)
LLAMA_BIN=""
if [ -f "/opt/homebrew/bin/llama-server" ]; then
    LLAMA_BIN="/opt/homebrew/bin/llama-server"
elif [ -f "/usr/local/bin/llama-server" ]; then
    LLAMA_BIN="/usr/local/bin/llama-server"
fi

NEED_DEEP_SIGN=0
if [ -n "$LLAMA_BIN" ]; then
    BUNDLED_LLAMA="$APP_BUNDLE/Contents/MacOS/llama-server"
    if [ ! -f "$BUNDLED_LLAMA" ] || [ "$LLAMA_BIN" -nt "$BUNDLED_LLAMA" ]; then
        echo "📦 Updating embedded llama-server engine in $APP_NAME.app..."
        rm -f "$BUNDLED_LLAMA"
        cp -X -L "$LLAMA_BIN" "$BUNDLED_LLAMA"
        chmod +x "$BUNDLED_LLAMA"
        NEED_DEEP_SIGN=1
    fi

    # llama-server is a stub that loads @rpath dylibs from ../lib
    LLAMA_LIB=""
    if [ -d "/opt/homebrew/opt/llama.cpp/lib" ]; then
        LLAMA_LIB="/opt/homebrew/opt/llama.cpp/lib"
    else
        RESOLVED_BIN="$(python3 -c "import os; print(os.path.realpath('$LLAMA_BIN'))" 2>/dev/null || true)"
        if [ -n "$RESOLVED_BIN" ]; then
            CANDIDATE="$(dirname "$RESOLVED_BIN")/../lib"
            if [ -d "$CANDIDATE" ]; then
                LLAMA_LIB="$CANDIDATE"
            fi
        fi
    fi

    if [ -n "$LLAMA_LIB" ]; then
        mkdir -p "$APP_BUNDLE/Contents/lib"
        for lib in libllama-server-impl.dylib libllama-common.0.dylib libllama.0.dylib libmtmd.0.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-metal.0.dylib libggml-blas.0.dylib; do
            if [ -f "$LLAMA_LIB/$lib" ]; then
                DEST_LIB="$APP_BUNDLE/Contents/lib/$lib"
                if [ ! -f "$DEST_LIB" ] || [ "$LLAMA_LIB/$lib" -nt "$DEST_LIB" ]; then
                    rm -f "$DEST_LIB"
                    cp -X -L "$LLAMA_LIB/$lib" "$DEST_LIB"
                    chmod u+w "$DEST_LIB" 2>/dev/null || true
                    NEED_DEEP_SIGN=1
                fi
            fi
        done
    fi
fi

# Generate App Icon if present
if [ -f "Resources/AppIcon.icns" ]; then
    if [ ! -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ] || [ "Resources/AppIcon.icns" -nt "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
        cp -X "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    fi
fi

echo "🔐 Codesigning application bundle..."
strip_disallowed_xattrs "$APP_BUNDLE"
if [ "$NEED_DEEP_SIGN" -eq 1 ]; then
    codesign --force --deep --sign - "$APP_BUNDLE"
else
    # Fast incremental sign of just the updated main executable + bundle wrapper
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "✅ Successfully built $APP_BUNDLE"
echo "You can now run: open $APP_BUNDLE"
