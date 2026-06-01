#!/bin/sh
set -eu
# Reset the iRMC BMC (Manager.Reset / GracefulRestart), retrying while the
# controller answers "Blocked" (it refuses a reset while certain operations are
# in flight; with the host powered Off it normally accepts within a few tries).
#
# Promoted from tmp/503d9361/bmc-reset-retry.sh (2026-06-01 503d9361, issue #73).
# Parameterized: BMC IP / user / pass are positional; TLS/curl extras come from
# BMC_CURL_OPTS (iRMC S4 needs "--ciphers DEFAULT@SECLEVEL=0" for its old DH key).
#
# Usage:
#   BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0' \
#       ./scripts/irmc-bmc-reset-retry.sh <bmc_ip> <user> <pass> [max_tries=10] [wait_s=20]
: "${BMC_CURL_OPTS:=}"
BMC_IP="${1:?bmc_ip}"
USER="${2:?user}"
PASS="${3:?pass}"
MAX_TRIES="${4:-10}"
WAIT_S="${5:-20}"

URL="https://${BMC_IP}/redfish/v1/Managers/iRMC/Actions/Manager.Reset"
i=0
while [ "$i" -lt "$MAX_TRIES" ]; do
    i=$((i + 1))
    out=$(curl -sS -k ${BMC_CURL_OPTS} --max-time 30 -u "${USER}:${PASS}" \
        -X POST -H 'Content-Type: application/json' \
        -d '{"ResetType":"GracefulRestart"}' "$URL" || true)
    if printf '%s' "$out" | grep -q "Blocked"; then
        echo "attempt $i/$MAX_TRIES: still blocked, wait ${WAIT_S}s"
        sleep "$WAIT_S"
        continue
    fi
    echo "attempt $i/$MAX_TRIES: reset accepted (no block). response:"
    printf '%s\n' "$out"
    exit 0
done
echo "FAILED: still blocked after $i attempts"
exit 1
