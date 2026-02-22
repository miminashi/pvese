#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"

usage() {
    echo "Usage: generate-preseed.sh <config.yml> [output_file]"
    echo ""
    echo "Generate preseed.cfg from template using config values."
    echo "If output_file is omitted, writes to stdout."
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

CONFIG="$1"
OUTPUT="${2:-}"
TEMPLATE="${PROJECT_DIR}/preseed/preseed.cfg.template"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file not found: $CONFIG" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

if [ ! -x "$YQ" ]; then
    echo "ERROR: yq not found at: $YQ" >&2
    exit 1
fi

hostname=$("$YQ" '.hostname' "$CONFIG")
domain=$("$YQ" '.domain' "$CONFIG")
disk=$("$YQ" '.disk' "$CONFIG")
root_password=$("$YQ" '.root_password' "$CONFIG")
user_name=$("$YQ" '.user_name' "$CONFIG")
user_password=$("$YQ" '.user_password' "$CONFIG")

console_order="console=tty0 console=ttyS1,115200n8"

result=$(sed \
    -e "s|%%HOSTNAME%%|${hostname}|g" \
    -e "s|%%DOMAIN%%|${domain}|g" \
    -e "s|%%DISK%%|${disk}|g" \
    -e "s|%%ROOT_PASSWORD%%|${root_password}|g" \
    -e "s|%%USER_NAME%%|${user_name}|g" \
    -e "s|%%USER_PASSWORD%%|${user_password}|g" \
    -e "s|%%CONSOLE_ORDER%%|${console_order}|g" \
    "$TEMPLATE")

if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$result" > "$OUTPUT"
    echo "Generated: $OUTPUT"
else
    printf '%s\n' "$result"
fi
