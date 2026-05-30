#!/bin/sh
set -eu

OUT=/home/ubuntu/projects/pvese/tmp/snuggly1
BMC=10.254.254.9
USER=claude
PASS=Claude123
COPTS='-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30'

echo "=== Step R1: DisconnectCD (release NFS attach) ==="
curl $COPTS -u "${USER}:${PASS}" \
    -X POST "https://${BMC}/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" \
    -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"DisconnectCD"}' \
    -w '\nHTTP %{http_code}\n' > "$OUT/disconnectcd-response.txt"

cat "$OUT/disconnectcd-response.txt"

echo "=== Step R2: PATCH back to SMB baseline ==="
./scripts/irmc-virtualmedia.sh config 10.254.254.9 claude Claude123 \
    10.1.6.1 public debian-training-tx1320-raid10.iso guest guest > "$OUT/restore-smb.log"

cat "$OUT/restore-smb.log"

echo "=== Step R3: GET final state ==="
./scripts/irmc-virtualmedia.sh status 10.254.254.9 claude Claude123 > "$OUT/final-status.log"
cat "$OUT/final-status.log"

echo "=== Step R4: AllowableValues check ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0" \
    | tr -d '\n\r' \
    | sed -n 's/.*"VirtualMediaAction@Redfish.AllowableValues":\(\[[^]]*\]\).*/\1/p' \
    | tee "$OUT/allowable-final.txt"

echo "DONE"
