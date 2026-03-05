#!/bin/sh
set -eu
# Receive UDP syslog from Debian installer (R320 diagnostics)
# Usage: ./scripts/syslog-receiver.sh [port] [logfile]
# The installer sends syslog via: syslogd -R <host>:<port>
# Run this before starting the install, then watch output in real time.

PORT="${1:-5514}"
LOG_FILE="${2:-}"

echo "Listening for installer syslog on UDP port $PORT..."
echo "Press Ctrl+C to stop."

if [ -n "$LOG_FILE" ]; then
    socat UDP-LISTEN:"$PORT",fork,reuseaddr - | tee "$LOG_FILE"
else
    socat UDP-LISTEN:"$PORT",fork,reuseaddr -
fi
