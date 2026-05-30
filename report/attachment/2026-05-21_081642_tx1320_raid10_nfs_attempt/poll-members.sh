#!/bin/sh
set -eu

BMC=10.254.254.9
USER=claude
PASS=Claude123
COPTS='-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30'
OUT=/home/ubuntu/projects/pvese/tmp/snuggly1

I=0
MAX=24
while [ $I -lt $MAX ]; do
    BODY=$(curl $COPTS -u "${USER}:${PASS}" \
        "https://${BMC}/redfish/v1/Managers/iRMC/VirtualMedia")
    COUNT=$(echo "$BODY" | tr -d '\n\r' \
        | sed -n 's/.*"Members@odata.count":\([0-9]*\).*/\1/p')
    AV=$(curl $COPTS -u "${USER}:${PASS}" \
        "https://${BMC}/redfish/v1/Systems/0" \
        | tr -d '\n\r' \
        | sed -n 's/.*"VirtualMediaAction@Redfish.AllowableValues":\(\[[^]]*\]\).*/\1/p')
    echo "[$(date +%H:%M:%S)] iter=${I} Members.count=${COUNT} AllowableValues=${AV}"
    if [ "$COUNT" -gt 0 ] 2>/dev/null; then
        echo "Members populated"
        break
    fi
    I=$((I+1))
    sleep 5
done

echo "=== final Members ==="
curl $COPTS -u "${USER}:${PASS}" \
    "https://${BMC}/redfish/v1/Managers/iRMC/VirtualMedia" > "$OUT/members-final.json"
cat "$OUT/members-final.json"

if [ -n "$BODY" ]; then
    LINKS=$(echo "$BODY" | tr -d '\n\r' \
        | sed -n 's/.*"Members":\(\[[^]]*\]\).*/\1/p')
    echo "Members links: $LINKS"
fi
