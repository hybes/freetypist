#!/bin/bash
# May also be run on the signing Mac after transferring an unsigned review bundle.
set -euo pipefail
app="${1:?Usage: sign_app.sh /path/to/FreeTypist.app}"
identity="${SIGNING_IDENTITY:--}"
flags=(--force --sign "$identity")
if [ "$identity" != "-" ]; then flags+=(--options runtime --timestamp); fi

sign() {
    if codesign -d "$1" >/dev/null 2>&1; then
        codesign "${flags[@]}" --preserve-metadata=identifier,entitlements "$1"
    else
        codesign "${flags[@]}" "$1"
    fi
}

# Sign from the inside out. Do not use --deep to sign: it skips Contents/lib
# and can discard the Sparkle helpers' existing sandbox entitlements.
for library in "$app"/Contents/lib/*.dylib; do
    [ -f "$library" ] && sign "$library"
done
framework="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$framework" ]; then
    sign "$framework/Versions/B/Autoupdate"
    sign "$framework/Versions/B/Updater.app"
    sign "$framework/Versions/B/XPCServices/Downloader.xpc"
    sign "$framework/Versions/B/XPCServices/Installer.xpc"
    sign "$framework"
fi
[ ! -f "$app/Contents/MacOS/llama-server" ] || sign "$app/Contents/MacOS/llama-server"
sign "$app"
codesign --verify --deep --strict "$app"
for library in "$app"/Contents/lib/*.dylib; do
    [ ! -f "$library" ] || codesign --verify --strict "$library"
done
