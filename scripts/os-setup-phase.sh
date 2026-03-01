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
    echo "  init   [--config FILE] [--state-dir DIR]   Initialize phase tracking"
    echo "  start  <phase> [--config FILE] [--state-dir DIR]"
    echo "  check  <phase> [--config FILE] [--state-dir DIR]"
    echo "  mark   <phase> [--config FILE] [--state-dir DIR]"
    echo "  fail   <phase> [--config FILE] [--state-dir DIR]"
    echo "  reset  <phase> [--config FILE] [--state-dir DIR]"
    echo "  status [--config FILE] [--state-dir DIR]   Show current phase status"
    echo "  times  [--config FILE] [--state-dir DIR]   Show elapsed time summary"
    echo "  next   [--config FILE] [--state-dir DIR]   Print next pending phase"
    echo ""
    echo "Options:"
    echo "  --config FILE    Server config file (e.g. config/server6.yml)"
    echo "                   Derives state dir: state/os-setup/server6/"
    echo "  --state-dir DIR  Override state directory (takes precedence over --config)"
    echo ""
    echo "If neither --config nor --state-dir is given, uses: state/os-setup/"
    echo ""
    echo "Phases: ${PHASES}"
    exit 1
}

parse_state_dir() {
    state_dir=""
    config_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --state-dir) state_dir="$2"; shift 2 ;;
            --config)
                config_file="$2"
                server_name=$(basename "$config_file" .yml)
                config_dir="${PROJECT_DIR}/state/os-setup/${server_name}"
                shift 2
                ;;
            *) shift ;;
        esac
    done
    if [ -n "$state_dir" ]; then
        echo "$state_dir"
    elif [ -n "$config_dir" ]; then
        echo "$config_dir"
    else
        echo "$DEFAULT_STATE_DIR"
    fi
}

cmd_init() {
    state_dir=$(parse_state_dir "$@")
    mkdir -p "$state_dir"
    for phase in $PHASES; do
        if [ ! -f "$state_dir/$phase" ]; then
            echo "pending" > "$state_dir/$phase"
        fi
        rm -f "$state_dir/$phase.start" "$state_dir/$phase.end"
    done
    echo "Initialized: $state_dir"
}

cmd_start() {
    phase="$1"; shift
    state_dir=$(parse_state_dir "$@")
    if [ ! -f "$state_dir/$phase" ]; then
        echo "Phase not found: $phase" >&2
        exit 2
    fi
    date +%s > "$state_dir/$phase.start"
    echo "Started: $phase"
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
    date +%s > "$state_dir/$phase.end"
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
    rm -f "$state_dir/$phase.start" "$state_dir/$phase.end"
    echo "Reset: $phase"
}

format_duration() {
    elapsed="$1"
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    printf "%dm%02ds" "$minutes" "$seconds"
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
        suffix=""
        if [ "$status" = "done" ] && [ -f "$state_dir/$phase.start" ] && [ -f "$state_dir/$phase.end" ]; then
            ts_start=$(cat "$state_dir/$phase.start")
            ts_end=$(cat "$state_dir/$phase.end")
            elapsed=$((ts_end - ts_start))
            suffix="  ($(format_duration "$elapsed"))"
        elif [ "$status" = "pending" ] && [ -f "$state_dir/$phase.start" ]; then
            status="started"
        fi
        printf "%-25s %s%s\n" "$phase" "$status" "$suffix"
    done
}

cmd_times() {
    state_dir=$(parse_state_dir "$@")
    if [ ! -d "$state_dir" ]; then
        echo "Not initialized. Run: os-setup-phase.sh init"
        exit 1
    fi
    total=0
    has_entry=0
    for phase in $PHASES; do
        if [ -f "$state_dir/$phase.start" ] && [ -f "$state_dir/$phase.end" ]; then
            ts_start=$(cat "$state_dir/$phase.start")
            ts_end=$(cat "$state_dir/$phase.end")
            elapsed=$((ts_end - ts_start))
            total=$((total + elapsed))
            has_entry=1
            printf "%-25s%s\n" "$phase" "$(format_duration "$elapsed")"
        fi
    done
    if [ "$has_entry" = 1 ]; then
        echo "---"
        printf "%-25s%s\n" "total" "$(format_duration "$total")"
    fi
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
    start)
        if [ $# -lt 1 ]; then usage; fi
        cmd_start "$@"
        ;;
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
    times)  cmd_times "$@" ;;
    next)   cmd_next "$@" ;;
    *)      usage ;;
esac
