#!/bin/sh
set -eu

usage() {
    echo "Usage: ssh-wait.sh <host> [--timeout 300] [--interval 10] [--user root]"
    echo ""
    echo "Wait for SSH to become available on a remote host."
    echo ""
    echo "Options:"
    echo "  --timeout N    Max wait time in seconds (default: 300)"
    echo "  --interval N   Retry interval in seconds (default: 10)"
    echo "  --user USER    SSH user (default: root)"
    echo ""
    echo "Exit codes:"
    echo "  0 = SSH connected successfully"
    echo "  1 = Timeout"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

host="$1"
shift

timeout=300
interval=10
user=root

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)  timeout="$2";  shift 2 ;;
        --interval) interval="$2"; shift 2 ;;
        --user)     user="$2";     shift 2 ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

elapsed=0
attempt=0

while [ "$elapsed" -lt "$timeout" ]; do
    attempt=$((attempt + 1))
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "${user}@${host}" true 2>/dev/null; then
        echo "SSH connected to ${user}@${host} (attempt ${attempt}, ${elapsed}s elapsed)"
        exit 0
    fi
    echo "SSH attempt ${attempt} failed (${elapsed}s/${timeout}s), retrying in ${interval}s..."
    sleep "$interval"
    elapsed=$((elapsed + interval))
done

echo "SSH timeout: ${user}@${host} not reachable after ${timeout}s (${attempt} attempts)"
exit 1
