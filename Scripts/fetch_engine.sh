#!/bin/bash
# Official llama.cpp binaries target older macOS releases than local Homebrew builds.
set -euo pipefail
ENGINE_BUILD=b11669
ENGINE_SHA256=dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd
ENGINE_CACHE="${FREETYPIST_ENGINE_CACHE:-/tmp/freetypist-engine}/$ENGINE_BUILD"
if [ "$(uname -m)" != arm64 ]; then
    echo "Set LLAMA_SERVER_PATH to an engine built for this architecture." >&2
    exit 1
fi
mkdir -p "$ENGINE_CACHE"
archive="$ENGINE_CACHE/engine.tar.gz"
if [ ! -f "$archive" ]; then
    curl --fail --location --silent --show-error \
        "https://github.com/ggml-org/llama.cpp/releases/download/$ENGINE_BUILD/llama-$ENGINE_BUILD-bin-macos-arm64.tar.gz" \
        -o "$archive.partial"
    mv "$archive.partial" "$archive"
fi
echo "$ENGINE_SHA256  $archive" | shasum -a 256 --check --status
if [ ! -f "$ENGINE_CACHE/llama-$ENGINE_BUILD/llama-server" ]; then
    tar -xzf "$archive" -C "$ENGINE_CACHE"
fi
echo "$ENGINE_CACHE/llama-$ENGINE_BUILD/llama-server"
