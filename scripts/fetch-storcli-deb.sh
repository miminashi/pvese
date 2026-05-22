#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

STORCLI_URL=${STORCLI_URL:-"https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"}
DEB_OUT=${1:-"/var/samba/public/storcli64.deb"}
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fetch-storcli.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo "[fetch-storcli] URL: $STORCLI_URL"
echo "[fetch-storcli] Output: $DEB_OUT"
echo "[fetch-storcli] Work dir: $WORK_DIR"

cd "$WORK_DIR"
echo "[fetch-storcli] Downloading zip..."
wget -q -O storcli.zip "$STORCLI_URL"
echo "[fetch-storcli] Downloaded: $(stat -c%s storcli.zip) bytes"

echo "[fetch-storcli] Unzipping..."
unzip -q -o storcli.zip

INNER=$(find . -name "Unified_storcli_all_os.zip" | head -1)
if [ -n "$INNER" ]; then
    echo "[fetch-storcli] Unzipping nested: $INNER"
    unzip -q -o "$INNER" -d "$(dirname "$INNER")"
fi

echo "[fetch-storcli] Searching for .deb..."
DEB=$(find . -name "*.deb" -path "*Ubuntu*" | head -1)
if [ -z "$DEB" ]; then
    DEB=$(find . -name "*.deb" -path "*Linux*" | head -1)
fi
if [ -z "$DEB" ]; then
    DEB=$(find . -name "*.deb" | head -1)
fi
if [ -z "$DEB" ]; then
    echo "[fetch-storcli] ERROR: no .deb found in zip" >&2
    find . -name "*.deb" >&2
    find . -type d >&2
    exit 1
fi

echo "[fetch-storcli] Found: $DEB"
cp "$DEB" "$DEB_OUT"
chmod 644 "$DEB_OUT"
echo "[fetch-storcli] Wrote: $DEB_OUT ($(stat -c%s "$DEB_OUT") bytes)"
echo "[fetch-storcli] OK"
