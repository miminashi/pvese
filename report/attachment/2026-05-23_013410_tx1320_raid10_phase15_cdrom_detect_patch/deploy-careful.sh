#!/bin/sh
# Careful manual deploy with extended waits.
set -eu
BMC=10.254.254.9
USER=claude
PASS=Claude123
ISO=debian-training-tx1320-raid10.iso
NFS_HOST=10.1.6.6
NFS_EXPORT=/var/samba/public

export BMC_CURL_OPTS='--ciphers DEFAULT@SECLEVEL=0'
export BMC_PATCH_REQUIRES_ETAG=1
export POWER_ON_RESET_TYPE=On

echo "=== Step 1: ForceOff host ==="
./scripts/bmc-power.sh forceoff "$BMC" "$USER" "$PASS" 2>&1 | tail -2

sh tmp/0bc594e7/wait-poweroff.sh

echo ""
echo "=== Step 2: Disconnect CD ==="
./scripts/irmc-virtualmedia.sh --share-type=NFS disconnect-cd "$BMC" "$USER" "$PASS" 2>&1 | tail -3

sh tmp/0bc594e7/check-vm-disconnected.sh

echo ""
echo "=== Step 3: Sleep 30s to let iRMC settle ==="
START=$(date +%s)
until [ "$(( $(date +%s) - START ))" -ge 30 ]; do
    sleep 5
    echo "  ...settle wait $(( $(date +%s) - START ))s"
done

echo ""
echo "=== Step 4: PATCH CDImage config (NFS) ==="
./scripts/irmc-virtualmedia.sh --share-type=NFS config "$BMC" "$USER" "$PASS" "$NFS_HOST" "$NFS_EXPORT" "$ISO" 2>&1 | tail -3

echo ""
echo "=== Step 5: ConnectCD ==="
./scripts/irmc-virtualmedia.sh --share-type=NFS connect-cd "$BMC" "$USER" "$PASS" 2>&1 | tail -3

echo ""
echo "=== Step 6: Wait for AllowableValues=DisconnectCD ==="
./scripts/irmc-virtualmedia.sh --share-type=NFS mount "$BMC" "$USER" "$PASS" 2>&1 | tail -3

echo ""
echo "=== Step 7: EXTRA 60s wait for USB redirector to fully stabilize ==="
START=$(date +%s)
until [ "$(( $(date +%s) - START ))" -ge 60 ]; do
    sleep 10
    echo "  ...USB stabilize $(( $(date +%s) - START ))s"
done

echo ""
echo "=== Step 8: Boot override Cd UEFI ==="
BMC_BOOT_OVERRIDE_NO_DISABLED=1 ./scripts/bmc-power.sh boot-override "$BMC" "$USER" "$PASS" Cd UEFI 2>&1 | tail -2

echo ""
echo "=== Step 9: EXTRA 15s wait before power on ==="
START=$(date +%s)
until [ "$(( $(date +%s) - START ))" -ge 15 ]; do
    sleep 5
    echo "  ...pre-power $(( $(date +%s) - START ))s"
done

echo ""
echo "=== Step 10: Power On ==="
./scripts/bmc-power.sh on "$BMC" "$USER" "$PASS" 2>&1 | tail -2

echo ""
echo "=== Deploy careful: complete at $(date) ==="
