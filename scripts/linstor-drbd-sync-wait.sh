#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"
SSH_CONFIG="${SCRIPT_DIR}/../ssh/config"

usage() {
    echo "Usage: linstor-drbd-sync-wait.sh <resource_name> [<config>] [--timeout <seconds>]"
    echo ""
    echo "  Wait for all DRBD replicas of a resource to become UpToDate."
    echo ""
    echo "  <resource_name>  LINSTOR resource name"
    echo "  <config>         Path to linstor.yml (default: config/linstor.yml)"
    echo "  --timeout N      Timeout in seconds (default: 600)"
    echo ""
    echo "  Exit codes:"
    echo "    0  All replicas UpToDate"
    echo "    1  Timeout or error"
    exit 2
}

if [ $# -lt 1 ]; then
    usage
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

RESOURCE="$1"
shift

CONFIG="config/linstor.yml"
TIMEOUT=600
INTERVAL=10

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            if [ $# -lt 2 ]; then
                echo "Error: --timeout requires a value"
                exit 1
            fi
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            if [ -f "$1" ]; then
                CONFIG="$1"
                shift
            else
                echo "Error: unknown argument or file not found: $1"
                exit 1
            fi
            ;;
    esac
done

if [ ! -f "$CONFIG" ]; then
    echo "Error: config file not found: $CONFIG"
    exit 1
fi

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")

run_linstor() {
    ssh -F "$SSH_CONFIG" "root@${CONTROLLER_IP}" "linstor $*"
}

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
    json=$(run_linstor "-m resource list -r $RESOURCE")

    all_uptodate="yes"
    status_line=""
    node_count=0

    nodes=$(echo "$json" | "$YQ" -r ".[0][] | select(.name == \"$RESOURCE\") | .node_name")
    for node in $nodes; do
        disk_state=$(echo "$json" | "$YQ" -r ".[0][] | select(.name == \"$RESOURCE\" and .node_name == \"$node\") | .volumes[0].state.disk_state")
        if [ -z "$status_line" ]; then
            status_line="${node}:${disk_state}"
        else
            status_line="${status_line} ${node}:${disk_state}"
        fi
        node_count=$((node_count + 1))
        if [ "$disk_state" != "UpToDate" ]; then
            all_uptodate="no"
        fi
    done

    if [ "$node_count" -eq 0 ]; then
        echo "Error: resource $RESOURCE not found"
        exit 1
    fi

    echo "[${elapsed}s/${TIMEOUT}s] $status_line"

    if [ "$all_uptodate" = "yes" ]; then
        echo "All $node_count replicas UpToDate."
        exit 0
    fi

    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "Timeout: not all replicas UpToDate after ${TIMEOUT}s"
exit 1
