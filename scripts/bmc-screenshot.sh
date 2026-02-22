#!/bin/sh
set -eu

usage() {
    echo "Usage: bmc-screenshot.sh <bmc_ip> <cookie_file> <csrf> [output_file]"
    echo ""
    echo "Capture a screenshot from BMC remote console."
    echo "Tries CapturePreview.cgi (older BMC) and falls back to noVNC info."
    echo ""
    echo "Arguments:"
    echo "  bmc_ip       BMC IP address"
    echo "  cookie_file  Cookie file from bmc-session.sh login"
    echo "  csrf         CSRF token from bmc-session.sh csrf"
    echo "  output_file  Output file path (default: /tmp/bmc-screenshot.bmp)"
    exit 1
}

if [ $# -lt 3 ]; then
    usage
fi

BMC_IP="$1"
COOKIE_FILE="$2"
CSRF="$3"
OUTPUT_FILE="${4:-/tmp/bmc-screenshot.bmp}"

TMP_FILE="/tmp/bmc-screenshot-tmp.$$"
trap 'rm -f "$TMP_FILE"' EXIT

resp=$(curl -sk -o "$TMP_FILE" -w '%{http_code} %{content_type}' \
    -b "$COOKIE_FILE" \
    -H "CSRF_TOKEN: ${CSRF}" \
    "https://${BMC_IP}/cgi/CapturePreview.cgi")

http_code=$(echo "$resp" | cut -d' ' -f1)
content_type=$(echo "$resp" | cut -d' ' -f2-)

case "$content_type" in
    image/*)
        cp "$TMP_FILE" "$OUTPUT_FILE"
        file_size=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
        echo "Screenshot saved: $OUTPUT_FILE (${file_size} bytes, ${content_type})"
        ;;
    *)
        if [ "$http_code" = "404" ]; then
            echo "ERROR: CapturePreview.cgi not found (HTTP 404)" >&2
            echo "" >&2
            echo "This BMC uses HTML5 iKVM (noVNC) which only supports" >&2
            echo "client-side screenshots via the web browser." >&2
            echo "" >&2
            echo "To view the console, open in a browser:" >&2
            echo "  https://${BMC_IP} -> Remote Console -> iKVM/HTML5" >&2
            echo "" >&2
            echo "Alternative monitoring methods:" >&2
            echo "  - POST code: bmc-power.sh postcode <bmc_ip> <user> <pass>" >&2
            echo "  - SOL: ipmitool -I lanplus -H <bmc_ip> -U <user> -P <pass> sol activate" >&2
        else
            echo "ERROR: Screenshot capture failed (HTTP $http_code, Content-Type: $content_type)" >&2
            echo "" >&2
            echo "Possible causes:" >&2
            echo "  - DCMS license not activated (Supermicro SFT-DCMS-SINGLE required)" >&2
            echo "  - Session expired (re-login with bmc-session.sh)" >&2
        fi
        exit 1
        ;;
esac
