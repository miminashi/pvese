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
static_ip=$("$YQ" '.static_ip' "$CONFIG")
static_netmask=$("$YQ" '.static_netmask' "$CONFIG")
static_iface=$("$YQ" '.static_iface' "$CONFIG")

console_order="console=tty0 console=ttyS1,115200n8"

SSH_PUBKEY_FILE="${PROJECT_DIR}/ssh/id_ed25519.pub"
if [ -f "$SSH_PUBKEY_FILE" ]; then
    ssh_public_key=$(cat "$SSH_PUBKEY_FILE" | tr -d '\n')
else
    echo "WARNING: SSH public key not found at: $SSH_PUBKEY_FILE" >&2
    ssh_public_key=""
fi

result=$(sed \
    -e "s|%%HOSTNAME%%|${hostname}|g" \
    -e "s|%%DOMAIN%%|${domain}|g" \
    -e "s|%%DISK%%|${disk}|g" \
    -e "s|%%ROOT_PASSWORD%%|${root_password}|g" \
    -e "s|%%USER_NAME%%|${user_name}|g" \
    -e "s|%%USER_PASSWORD%%|${user_password}|g" \
    -e "s|%%CONSOLE_ORDER%%|${console_order}|g" \
    -e "s|%%SSH_PUBLIC_KEY%%|${ssh_public_key}|g" \
    -e "s|%%STATIC_IP%%|${static_ip}|g" \
    -e "s|%%STATIC_NETMASK%%|${static_netmask}|g" \
    -e "s|%%STATIC_IFACE%%|${static_iface}|g" \
    "$TEMPLATE")

if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$result" > "$OUTPUT"
    echo "Generated: $OUTPUT"
else
    printf '%s\n' "$result"
fi
