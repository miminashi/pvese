#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

PHASES="iso-download preseed-generate iso-remaster bmc-mount-boot install-monitor post-install-config pve-install cleanup"
DEFAULT_STATE_DIR="${PROJECT_DIR}/state/os-setup"

usage() {
    echo "Usage: os-setup-phase.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init   [--state-dir DIR]              Initialize phase tracking"
    echo "  check  <phase> [--state-dir DIR]      Check if phase is completed (exit 0=done, 1=not)"
    echo "  mark   <phase> [--state-dir DIR]      Mark phase as completed"
    echo "  fail   <phase> [--state-dir DIR]      Mark phase as failed"
    echo "  reset  <phase> [--state-dir DIR]      Reset phase to pending"
    echo "  status [--state-dir DIR]              Show current phase status"
    echo "  next   [--state-dir DIR]              Print next pending phase (exit 1 if all done)"
    echo ""
    echo "Phases: ${PHASES}"
    exit 1
}

parse_state_dir() {
    state_dir="${DEFAULT_STATE_DIR}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --state-dir) state_dir="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    echo "$state_dir"
}

cmd_init() {
    state_dir=$(parse_state_dir "$@")
    mkdir -p "$state_dir"
    for phase in $PHASES; do
        if [ ! -f "$state_dir/$phase" ]; then
            echo "pending" > "$state_dir/$phase"
        fi
    done
    echo "Initialized: $state_dir"
}

cmd_check() {
    phase="$1"; shift
    state_dir=$(parse_state_dir "$@")
    if [ ! -f "$state_dir/$phase" ]; then
        echo "Phase not found: $phase" >&2
        exit 2
    fi
    status=$(cat "$state_dir/$phase")
    if [ "$status" = "done" ]; then
        exit 0
    else
        exit 1
    fi
}

cmd_mark() {
    phase="$1"; shift
    state_dir=$(parse_state_dir "$@")
    if [ ! -f "$state_dir/$phase" ]; then
        echo "Phase not found: $phase" >&2
        exit 2
    fi
    echo "done" > "$state_dir/$phase"
    echo "Marked done: $phase"
}

cmd_fail() {
    phase="$1"; shift
    state_dir=$(parse_state_dir "$@")
    if [ ! -f "$state_dir/$phase" ]; then
        echo "Phase not found: $phase" >&2
        exit 2
    fi
    echo "failed" > "$state_dir/$phase"
    echo "Marked failed: $phase"
}

cmd_reset() {
    phase="$1"; shift
    state_dir=$(parse_state_dir "$@")
    if [ ! -f "$state_dir/$phase" ]; then
        echo "Phase not found: $phase" >&2
        exit 2
    fi
    echo "pending" > "$state_dir/$phase"
    echo "Reset: $phase"
}

cmd_status() {
    state_dir=$(parse_state_dir "$@")
    if [ ! -d "$state_dir" ]; then
        echo "Not initialized. Run: os-setup-phase.sh init"
        exit 1
    fi
    for phase in $PHASES; do
        if [ -f "$state_dir/$phase" ]; then
            status=$(cat "$state_dir/$phase")
        else
            status="unknown"
        fi
        printf "%-25s %s\n" "$phase" "$status"
    done
}

cmd_next() {
    state_dir=$(parse_state_dir "$@")
    if [ ! -d "$state_dir" ]; then
        echo "Not initialized. Run: os-setup-phase.sh init"
        exit 1
    fi
    for phase in $PHASES; do
        if [ -f "$state_dir/$phase" ]; then
            status=$(cat "$state_dir/$phase")
        else
            status="pending"
        fi
        if [ "$status" != "done" ]; then
            echo "$phase"
            exit 0
        fi
    done
    echo "All phases completed"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    init)   cmd_init "$@" ;;
    check)
        if [ $# -lt 1 ]; then usage; fi
        cmd_check "$@"
        ;;
    mark)
        if [ $# -lt 1 ]; then usage; fi
        cmd_mark "$@"
        ;;
    fail)
        if [ $# -lt 1 ]; then usage; fi
        cmd_fail "$@"
        ;;
    reset)
        if [ $# -lt 1 ]; then usage; fi
        cmd_reset "$@"
        ;;
    status) cmd_status "$@" ;;
    next)   cmd_next "$@" ;;
    *)      usage ;;
esac
