#!/bin/sh
set -eu

usage() {
    echo "Usage: bmc-virtualmedia.sh <command> <args...>"
    echo ""
    echo "Commands:"
    echo "  config <bmc_ip> <cookie_file> <csrf> <smb_host> <smb_path>"
    echo "    Configure VirtualMedia ISO share (smb_path uses single backslashes: \\public\\file.iso)"
    echo ""
    echo "  mount  <bmc_ip> <cookie_file> <csrf>"
    echo "    Mount the configured ISO"
    echo ""
    echo "  umount <bmc_ip> <cookie_file> <csrf>"
    echo "    Unmount the ISO"
    echo ""
    echo "  status <bmc_ip> <cookie_file> <csrf>"
    echo "    Show VirtualMedia status"
    echo ""
    echo "  verify <bmc_ip> <bmc_user> <bmc_pass>"
    echo "    Verify VirtualMedia mount via Redfish (exit 0=mounted, 1=not mounted)"
    exit 1
}

cgi_post() {
    bmc_ip="$1"
    cookie_file="$2"
    csrf="$3"
    endpoint="$4"
    data="$5"

    result=$(curl -sk -w '\n%{http_code}' \
        -X POST "https://${bmc_ip}/cgi/${endpoint}" \
        -b "$cookie_file" \
        -H "CSRF_TOKEN: ${csrf}" \
        -d "$data")

    body=$(echo "$result" | sed '$d')
    http_code=$(echo "$result" | tail -1)

    if echo "$body" | grep -q "Token Value is not matched"; then
        echo "ERROR: CSRF token mismatch. Re-run bmc-session.sh login + csrf" >&2
        exit 1
    fi

    echo "$body"
}

cmd_config() {
    # WARNING: smb_path must use single backslashes (e.g. \public\file.iso).
    # Double backslashes (\\public\\file.iso) cause silent mount failure:
    # CGI returns VMCOMCODE=001 (success) but VirtualMedia is NOT actually mounted.
    # Always use yq to read the path from config YAML, never hardcode with shell literals.
    bmc_ip="$1"
    cookie_file="$2"
    csrf="$3"
    smb_host="$4"
    smb_path="$5"

    data="op=config_iso&host=${smb_host}&path=${smb_path}&user=&pwd="
    result=$(cgi_post "$bmc_ip" "$cookie_file" "$csrf" "op.cgi" "$data")
    echo "Config result: $result"
}

cmd_mount() {
    bmc_ip="$1"
    cookie_file="$2"
    csrf="$3"

    result=$(cgi_post "$bmc_ip" "$cookie_file" "$csrf" "op.cgi" "op=mount_iso")
    echo "Mount result: $result"
}

cmd_umount() {
    bmc_ip="$1"
    cookie_file="$2"
    csrf="$3"

    result=$(cgi_post "$bmc_ip" "$cookie_file" "$csrf" "op.cgi" "op=umount_iso")
    echo "Umount result: $result"
}

cmd_status() {
    bmc_ip="$1"
    cookie_file="$2"
    csrf="$3"

    result=$(cgi_post "$bmc_ip" "$cookie_file" "$csrf" "op.cgi" "op=vm_status")
    echo "$result"
}

cmd_verify() {
    bmc_ip="$1"
    bmc_user="$2"
    bmc_pass="$3"

    result=$(curl -sk -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_ip}/redfish/v1/Managers/1/VirtualMedia/CD1")

    inserted=$(echo "$result" | sed -n 's/.*"Inserted"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
    connected=$(echo "$result" | sed -n 's/.*"ConnectedVia"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    echo "Inserted: $inserted, ConnectedVia: $connected"

    if [ "$inserted" = "true" ]; then
        return 0
    else
        echo "ERROR: VirtualMedia not inserted (CSRF token may have expired)" >&2
        return 1
    fi
}

if [ $# -lt 1 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    config)
        if [ $# -lt 5 ]; then usage; fi
        cmd_config "$1" "$2" "$3" "$4" "$5"
        ;;
    mount)
        if [ $# -lt 3 ]; then usage; fi
        cmd_mount "$1" "$2" "$3"
        ;;
    umount)
        if [ $# -lt 3 ]; then usage; fi
        cmd_umount "$1" "$2" "$3"
        ;;
    status)
        if [ $# -lt 3 ]; then usage; fi
        cmd_status "$1" "$2" "$3"
        ;;
    verify)
        if [ $# -lt 3 ]; then usage; fi
        cmd_verify "$1" "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
