#!/bin/sh
set -eu

BMC=10.254.254.9
USER=claude
PASS=Claude123
COPTS='-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30'
OUT=/home/ubuntu/projects/pvese/tmp/snuggly1

echo "=== Step C1: POST ConnectCD ==="
curl $COPTS -u "${USER}:${PASS}" \
    -X POST "https://${BMC}/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" \
    -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    -w '\nHTTP %{http_code}\n' > "$OUT/connectcd-response.txt"

cat "$OUT/connectcd-response.txt"

echo "=== Step C2: sleep 15s ==="
sleep 15

echo "=== Step C3: GET Action AllowableValues ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0" \
    | tr -d '\n\r' \
    | sed -n 's/.*"VirtualMediaAction@Redfish.AllowableValues":\(\[[^]]*\]\).*/\1/p' \
    | tee "$OUT/allowable-after-c.txt"

echo ""
echo "=== Step C4: Members count ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Managers/iRMC/VirtualMedia" > "$OUT/members-after-c.json"
cat "$OUT/members-after-c.json"

echo ""
echo "=== Step C5: Re-GET OEM VM (final state) ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia" > "$OUT/oem-after-c.json"
cat "$OUT/oem-after-c.json"

echo "DONE"
