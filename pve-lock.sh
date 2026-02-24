#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/state"
LOCK_FILE="${STATE_DIR}/.pve-lock"
INFO_FILE="${STATE_DIR}/.pve-lock-info"

usage() {
    cat <<'USAGE'
Usage: pve-lock.sh <command> [options]

Commands:
  status                           Show lock status
  run <cmd...>                     Run command with lock (non-blocking, fail if locked)
  wait [--timeout N] <cmd...>      Run command with lock (blocking, wait for lock)
USAGE
}

cmd_status() {
    mkdir -p "$STATE_DIR"
    if (flock -n 9) 9>"$LOCK_FILE"; then
        echo "unlocked"
    else
        echo "locked"
        if [ -f "$INFO_FILE" ]; then
            cat "$INFO_FILE"
        fi
    fi
}

cmd_run() {
    if [ $# -lt 1 ]; then
        echo "Usage: pve-lock.sh run <cmd...>" >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    (
        flock -n 9 || {
            echo "Error: Lock is held by another process" >&2
            if [ -f "$INFO_FILE" ]; then
                cat "$INFO_FILE" >&2
            fi
            exit 1
        }
        printf "pid=%s cmd=%s time=%s\n" "$$" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INFO_FILE"
        "$@" 9>&-
        rc=$?
        rm -f "$INFO_FILE"
        exit "$rc"
    ) 9>"$LOCK_FILE"
}

cmd_wait() {
    timeout=0
    if [ $# -ge 2 ] && [ "$1" = "--timeout" ]; then
        timeout="$2"
        shift 2
    fi
    if [ $# -lt 1 ]; then
        echo "Usage: pve-lock.sh wait [--timeout N] <cmd...>" >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    (
        if [ "$timeout" -gt 0 ]; then
            flock -w "$timeout" 9 || {
                echo "Error: Timed out waiting for lock (${timeout}s)" >&2
                exit 1
            }
        else
            flock 9
        fi
        printf "pid=%s cmd=%s time=%s\n" "$$" "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INFO_FILE"
        "$@" 9>&-
        rc=$?
        rm -f "$INFO_FILE"
        exit "$rc"
    ) 9>"$LOCK_FILE"
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"; shift
case "$command" in
    status) cmd_status ;;
    run)    cmd_run "$@" ;;
    wait)   cmd_wait "$@" ;;
    help|-h|--help) usage ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        usage
        exit 1
        ;;
esac
