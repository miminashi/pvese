#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/log"
LOG_FILE="${LOG_DIR}/oplog.log"

oplog() {
    mkdir -p "$LOG_DIR"
    local start_time end_time elapsed rc
    start_time=$(date +%s)
    rc=0
    "$@" || rc=$?
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    printf '%s | rc=%d | %ds | %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$rc" "$elapsed" "$*" >>"$LOG_FILE"
    return "$rc"
}

if [ "${0##*/}" = "oplog.sh" ] && [ $# -gt 0 ]; then
    oplog "$@"
fi
