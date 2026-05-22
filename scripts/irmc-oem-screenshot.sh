#!/bin/sh
# Fujitsu iRMC S4 OEM screenshot: Make → poll AllowableValues → Preview.
# Usage: irmc-oem-screenshot.sh <bmc> <user> <pass> <out.jpg> [poll_timeout=15] [max_attempts=4]
#
# Retries: each Make-attempt polls up to poll_timeout seconds for Preview
# AllowableValues; if Preview never appears, we re-POST Make and try again
# (up to max_attempts). In practice on iRMC S4 (BIOS Setup HII) the
# Make-Preview transition succeeds ~1 in 3 attempts; with retries we
# converge close to 100%.
set -eu

BMC="${1:?bmc ip}"
USR="${2:?user}"
PSW="${3:?pass}"
OUT="${4:?output path}"
POLL_TIMEOUT="${5:-8}"
MAX_ATTEMPTS="${6:-4}"

CURL="curl -sS -k --ciphers DEFAULT@SECLEVEL=0 --max-time 15 -u $USR:$PSW"
SHOT_URL="https://$BMC/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.Screenshot"
SYS_URL="https://$BMC/redfish/v1/Systems/0"

attempt=0
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    $CURL -X POST -H 'Content-Type: application/json' \
        -d '{"FTSScreenshotType":"Make"}' "$SHOT_URL" >/dev/null || true
    start_t=$(date +%s)
    got_preview=0
    while :; do
        if $CURL "$SYS_URL" | grep -q '"Preview"'; then
            got_preview=1
            break
        fi
        sleep 1
        now_t=$(date +%s)
        if [ $((now_t - start_t)) -ge "$POLL_TIMEOUT" ]; then
            break
        fi
    done
    if [ "$got_preview" = 1 ]; then
        break
    fi
    echo "(attempt $attempt/$MAX_ATTEMPTS: Preview not available after ${POLL_TIMEOUT}s, retrying Make...)" >&2
done

if [ "$got_preview" != 1 ]; then
    echo "ERROR: screenshot did not become available after $MAX_ATTEMPTS attempts" >&2
    exit 2
fi

$CURL -X POST -H 'Content-Type: application/json' \
    -d '{"FTSScreenshotType":"Preview"}' \
    -o "$OUT" "$SHOT_URL"

sz=$(wc -c < "$OUT")
if [ "$sz" -lt 1000 ]; then
    echo "ERROR: screenshot too small ($sz bytes), likely an error" >&2
    cat "$OUT" >&2
    exit 3
fi
echo "Saved $OUT ($sz bytes, attempt $attempt)"
