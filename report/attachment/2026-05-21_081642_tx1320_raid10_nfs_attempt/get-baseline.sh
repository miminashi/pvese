#!/bin/sh
set -eu

BMC=10.254.254.9
USER=claude
PASS=Claude123
COPTS='-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30'

OUT=/home/ubuntu/projects/pvese/tmp/snuggly1

echo "=== baseline: OEM VirtualMedia GET ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia" > "$OUT/oem-vm-baseline.json"
ls -la "$OUT/oem-vm-baseline.json"

echo "=== baseline: Actions OEM GET ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" > "$OUT/action-baseline.json"
ls -la "$OUT/action-baseline.json"

echo "=== baseline: Managers/iRMC/VirtualMedia GET ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Managers/iRMC/VirtualMedia" > "$OUT/members-baseline.json"
ls -la "$OUT/members-baseline.json"

echo "=== power state ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0" > "$OUT/system-baseline.json"

echo "DONE"
