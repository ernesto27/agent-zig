#!/usr/bin/env bash
set -euo pipefail

REPO="ernesto27/agent-zig"
BINARY="agent-zig"
INSTALL_DIR="${HOME}/.local/bin"

# --- OS check ---
OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
  echo "error: only Linux is supported at this time (detected: $OS)" >&2
  exit 1
fi

# --- Arch check ---
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ASSET="agent-zig-linux-x86_64.tar.gz" ;;
  *)
    echo "error: unsupported architecture '$ARCH' (only x86_64 is available)" >&2
    exit 1
    ;;
esac

# --- Downloader ---
if command -v curl &>/dev/null; then
  DOWNLOAD="curl -fsSL"
elif command -v wget &>/dev/null; then
  DOWNLOAD="wget -qO-"
else
  echo "error: curl or wget is required" >&2
  exit 1
fi

# --- Resolve latest release asset via GitHub API ---
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
echo "Resolving latest release for ${REPO} ..."
DOWNLOAD_URL="$($DOWNLOAD "$API_URL" \
  | grep -oE "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${ASSET}\"" \
  | head -n1 \
  | sed -E 's/.*"(https:[^"]+)".*/\1/')"

if [ -z "$DOWNLOAD_URL" ]; then
  echo "error: could not find asset '${ASSET}' in latest release of ${REPO}" >&2
  exit 1
fi

# --- Download & extract ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading ${BINARY} from ${DOWNLOAD_URL} ..."
$DOWNLOAD "$DOWNLOAD_URL" | tar -xz -C "$TMP_DIR"

# --- Install ---
mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP_DIR/${BINARY}" "$INSTALL_DIR/${BINARY}"

echo ""
echo "${BINARY} installed to ${INSTALL_DIR}/${BINARY}"

# PATH hint
if ! echo ":${PATH}:" | grep -q ":${INSTALL_DIR}:"; then
  echo ""
  echo "  Add this to your shell profile:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
