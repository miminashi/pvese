#!/bin/sh
set -eu
# Recover an iRMC host to a clean "BIOS Setup + KVM master obtainable" state.
#
# This is the validated recovery flow from the TX1320 3-cycle RAID validation
# (2026-06-01 503d9361, issue #73), promoted into one config-driven script. It
# combines the former tmp/503d9361 helpers killall.sh + bmc-reset-retry.sh +
# wait-bmc-boot.sh + wait-post-snap.sh. RAID configuration is NVRAM-persistent,
# so this is non-destructive to any existing virtual drive.
#
# Steps: (1) kill any persistent KVM server, (2) force host Off, (3) Manager.Reset
# (retry while Blocked — host Off makes it accept), (4) poll until BMC responds,
# (5) set boot-override BiosSetup UEFI + power On, (6) wait for POST -> BIOS Setup,
# (7) OEM (true-VGA) screenshot to confirm BIOS Setup was reached.
#
# Usage:
#   ./scripts/irmc-kvm-recover.sh <config.yml> [out_screenshot.jpg] [post_wait_s=170]
# Example:
#   ./scripts/irmc-kvm-recover.sh config/training_tx1320.yml

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJ_DIR=$(dirname -- "$SCRIPT_DIR")
YQ="$PROJ_DIR/bin/yq"

CFG="${1:?config.yml}"
OUT="${2:-tmp/irmc-recover/pre-run.jpg}"
POST_WAIT="${3:-170}"

BMC_IP=$("$YQ" '.bmc_ip' "$CFG")
BMC_USER=$("$YQ" '.bmc_user' "$CFG")
BMC_PASS=$("$YQ" '.bmc_pass' "$CFG")
export BMC_SCHEME=$("$YQ" '.bmc_scheme' "$CFG")
export BMC_CURL_OPTS=$("$YQ" '.bmc_curl_opts' "$CFG")
export POWER_ON_RESET_TYPE=$("$YQ" '.power_on_reset_type' "$CFG")
export BMC_PATCH_REQUIRES_ETAG=$("$YQ" '.bmc_patch_requires_etag' "$CFG")
export BMC_BOOT_OVERRIDE_NO_DISABLED=$("$YQ" '.bmc_boot_override_no_disabled' "$CFG")

PW="./scripts/bmc-power.sh"

echo "=== [1/7] kill any persistent KVM server ==="
pkill -9 -f "irmc-kvm/server.py" || true
pkill -9 -f "kvm_server.py" || true
sleep 3
echo "kvm server procs remaining: $(pgrep -f 'irmc-kvm/server.py' | wc -l)"

echo "=== [2/7] force host Off ==="
"$PW" forceoff "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true
echo "wait 15s for power Off to settle"
sleep 15
echo "power state: $("$PW" status "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true)"

echo "=== [3/7] Manager.Reset (retry while Blocked) ==="
"$SCRIPT_DIR/irmc-bmc-reset-retry.sh" "$BMC_IP" "$BMC_USER" "$BMC_PASS"
# Manager.Reset is async: the BMC stays up briefly, then reboots and is
# unreachable for ~60-120s. Without this settle wait, the poll below would
# exit immediately (BMC still answering pre-reboot) and the next Redfish call
# would hit the BMC mid-reset (connection refused).
echo "wait 90s for BMC to go down + start rebooting"
sleep 90

echo "=== [4/7] poll until BMC responsive ==="
until "$PW" status "$BMC_IP" "$BMC_USER" "$BMC_PASS" 2>/dev/null | grep -qE "Off|On"; do
    sleep 10
done
echo "BMC back: $("$PW" status "$BMC_IP" "$BMC_USER" "$BMC_PASS")"
echo "wait 10s for Redfish to fully settle"
sleep 10

echo "=== [5/7] boot-override BiosSetup UEFI + power On ==="
i=0
until "$PW" boot-override "$BMC_IP" "$BMC_USER" "$BMC_PASS" BiosSetup UEFI; do
    i=$((i + 1))
    [ "$i" -ge 6 ] && { echo "boot-override failed after $i tries"; exit 1; }
    echo "boot-override retry $i (Redfish not ready), wait 15s"
    sleep 15
done
"$PW" on "$BMC_IP" "$BMC_USER" "$BMC_PASS"
echo "powered on"

echo "=== [6/7] wait ${POST_WAIT}s for POST -> BIOS Setup ==="
sleep "$POST_WAIT"

echo "=== [7/7] OEM true-VGA screenshot -> $OUT ==="
mkdir -p "$(dirname -- "$OUT")"
"$SCRIPT_DIR/irmc-oem-screenshot.sh" "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$OUT" 12 5
echo "recover complete: review $OUT to confirm BIOS Setup screen"
