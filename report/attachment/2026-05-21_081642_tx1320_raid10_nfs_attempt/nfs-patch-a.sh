#!/bin/sh
set -eu

BMC=10.254.254.9
USER=claude
PASS=Claude123
COPTS='-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30'
PATH_VM='/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia'
OUT=/home/ubuntu/projects/pvese/tmp/snuggly1

echo "=== Step A1: Get current ETag ==="
ETAG=$(curl $COPTS -u "${USER}:${PASS}" -D - -o /dev/null "https://${BMC}${PATH_VM}" \
    | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*\(.*\)\r\?$/\1/p' \
    | head -1 \
    | tr -d '\r"')
if [ -z "$ETAG" ]; then
    BODY=$(curl $COPTS -u "${USER}:${PASS}" "https://${BMC}${PATH_VM}")
    ETAG=$(echo "$BODY" | tr -d '\n\r' \
        | sed -n 's/.*"@odata.etag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
echo "ETag: ${ETAG}"

echo "=== Step A2: PATCH with ShareType=NFS ==="
PAYLOAD='{"CDImage":{"Server":"10.1.6.6","UserName":"","Password":"","UserDomain":"","ShareType":"NFS","ShareName":"/var/samba/public","ImageName":"debian-preseed-tx1320.iso"},"RemoteMountEnabled":true}'
echo "Payload: ${PAYLOAD}"

curl $COPTS -u "${USER}:${PASS}" \
    -X PATCH "https://${BMC}${PATH_VM}" \
    -H 'Content-Type: application/json' \
    -H "If-Match: ${ETAG}" \
    -w '\nHTTP %{http_code}\n' \
    -d "$PAYLOAD" > "$OUT/nfs-patch-a-response.txt"

cat "$OUT/nfs-patch-a-response.txt"

echo "=== Step A3: sleep 5s ==="
sleep 5

echo "=== Step A4: GET after PATCH ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}${PATH_VM}" > "$OUT/oem-after-a.json"
cat "$OUT/oem-after-a.json"

echo ""
echo "=== Step A5: Action AllowableValues check ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Systems/0" \
    | tr -d '\n\r' \
    | sed -n 's/.*"VirtualMediaAction@Redfish.AllowableValues":\(\[[^]]*\]\).*/\1/p' \
    | tee "$OUT/allowable-after-a.txt"

echo ""
echo "=== Step A6: Members count check ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Managers/iRMC/VirtualMedia" > "$OUT/members-after-a.json"
cat "$OUT/members-after-a.json"

echo "DONE"
