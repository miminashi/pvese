#!/bin/sh
echo "pvese: raid10-setup line1 reached" > /dev/kmsg 2>/dev/null || true
set -u
echo "pvese: raid10-setup after set -u" > /dev/kmsg 2>/dev/null || true

# Phase 14 (2026-05-22 linear-mountain): the orchestrate `build` Phase 2.5
# now pre-extracts storcli64 with dpkg-deb on the host and bundles the bare
# binary into the ISO as /storcli64.bin. d-i busybox initramfs has no dpkg,
# so the previous .deb-based install path exited with rc=127 (command not
# found) inside partman/early_command. This script now just chmod+exec the
# bundled binary — no package tooling required at install time.
BIN=${1:-/cdrom/storcli64.bin}
LOG=${RAID10_LOG:-/var/log/raid10-setup.log}
echo "pvese: raid10-setup BIN=$BIN LOG=$LOG" > /dev/kmsg 2>/dev/null || true

# Ensure log dir exists (missing in d-i busybox initramfs)
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() {
    printf '%s [raid10-setup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" 2>/dev/null | tee -a "$LOG" >&2 2>/dev/null || true
    echo "pvese: raid10-setup $*" > /dev/kmsg 2>/dev/null || true
}

log "start: bin=$BIN log=$LOG"

if [ ! -f "$BIN" ]; then
    log "FATAL: storcli64 binary not found at $BIN"
    exit 4
fi

# Place a stable copy under /usr/local/bin so subsequent stages (including
# in-target invocations from late_command) can locate it on PATH.
mkdir -p /usr/local/bin 2>/dev/null || true
cp "$BIN" /usr/local/bin/storcli64
chmod +x /usr/local/bin/storcli64
log "installed binary -> /usr/local/bin/storcli64"

SCLI="/usr/local/bin/storcli64"
log "storcli64 path: $SCLI"

log "controller info:"
"$SCLI" /c0 show >> "$LOG" 2>&1 || {
    log "FATAL: /c0 show failed (controller not recognized)"
    exit 5
}

log "current VDs:"
"$SCLI" /c0/vall show >> "$LOG" 2>&1 || true

log "deleting existing VDs (best effort)"
"$SCLI" /c0/vall delete force >> "$LOG" 2>&1 || true

log "enumerating physical drives:"
"$SCLI" /c0/eall/sall show >> "$LOG" 2>&1

EID_SLOTS=$("$SCLI" /c0/eall/sall show | awk '/HDD|SSD/ {print $1}' | head -4)
COUNT=$(echo "$EID_SLOTS" | grep -c ':')
log "found drives: $COUNT"
echo "$EID_SLOTS" | tee -a "$LOG" >&2

if [ "$COUNT" -lt 4 ]; then
    log "FATAL: need 4 drives for RAID10, got $COUNT"
    exit 6
fi

DRIVES=$(echo "$EID_SLOTS" | tr '\n' ',' | sed 's/,$//')
log "creating RAID10 with drives=$DRIVES pdperarray=2"
"$SCLI" /c0 add vd type=raid10 size=all drives="$DRIVES" pdperarray=2 wb ra direct strip=256 >> "$LOG" 2>&1 || {
    log "FATAL: add vd type=raid10 failed"
    exit 7
}

log "post-create VD list:"
"$SCLI" /c0/vall show all | tee -a "$LOG" >&2

if ! "$SCLI" /c0/vall show | grep -E 'RAID-?10'; then
    log "FATAL: RAID10 not found in VD list"
    exit 7
fi

log "OK: RAID10 created"
exit 0
