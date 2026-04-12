#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
OPTIMIZE_MODE="ReleaseFast"
LINUX_BIN="${DIST_DIR}/linux/bin/agent-zig"
MACOS_BIN="${DIST_DIR}/macos/bin/agent-zig"

build_target() {
    local target="$1"
    local output_dir="$2"

    printf 'Building %s -> %s\n' "$target" "$output_dir"
    zig build \
        -Dtarget="$target" \
        -Doptimize="$OPTIMIZE_MODE" \
        --prefix "$output_dir"
}

mkdir -p "$DIST_DIR"

build_target "x86_64-linux-musl" "$DIST_DIR/linux"
build_target "aarch64-macos" "$DIST_DIR/macos"

printf 'Installing %s -> /usr/local/bin/agent-zig\n' "$LINUX_BIN"
sudo cp "$LINUX_BIN" /usr/local/bin/agent-zig
