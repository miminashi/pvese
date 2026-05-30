#!/bin/sh
set -eu
cd /home/ubuntu/projects/pvese
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export BMC_PATCH_REQUIRES_ETAG=1

BMC=10.254.254.9
USER=claude
PASS=Claude123

echo "[$(date '+%H:%M:%S')] State check..."
./scripts/bmc-power.sh status "$BMC" "$USER" "$PASS"

echo "[$(date '+%H:%M:%S')] ForceOff host (try ResetType=ForceOff)..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"ForceOff"}' \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC/redfish/v1/Systems/0/Actions/ComputerSystem.Reset" || true

echo "[$(date '+%H:%M:%S')] Wait for Off state..."
for i in $(seq 1 30); do
    sleep 3
    s=$(./scripts/bmc-power.sh status "$BMC" "$USER" "$PASS" 2>&1 | head -1)
    echo "[$(date '+%H:%M:%S')] iter=$i state=$s"
    [ "$s" = "Off" ] && break
done

echo "[$(date '+%H:%M:%S')] DisconnectCD to ensure clean state..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"DisconnectCD"}' \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/disc-attach.json || true
echo

echo "[$(date '+%H:%M:%S')] PATCH CDImage with debian-training-tx1320-raid10.iso..."
./scripts/irmc-virtualmedia.sh config "$BMC" "$USER" "$PASS" \
    10.1.6.1 public debian-training-tx1320-raid10.iso guest guest \
    > /home/ubuntu/projects/pvese/tmp/9d15d229/patch-attach.json 2>&1

echo "[$(date '+%H:%M:%S')] ConnectCD..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/conn-attach.json
echo

echo "[$(date '+%H:%M:%S')] Members poll for 90s (5s interval)..."
for i in $(seq 1 18); do
    sleep 5
    curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
        'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' \
        -o /home/ubuntu/projects/pvese/tmp/9d15d229/vm-poll-$i.json 2>/dev/null
    count=$(python3 -c "import json; d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/vm-poll-$i.json')); print(d.get('Members@odata.count', 'ERR'))" 2>/dev/null || echo "?")
    echo "[$(date '+%H:%M:%S')] iter=$i Members=$count"
    if [ "$count" != "0" ] && [ "$count" != "?" ] && [ "$count" != "ERR" ]; then
        echo "[$(date '+%H:%M:%S')] *** Members became non-zero ***"
        break
    fi
done

echo "[$(date '+%H:%M:%S')] Final TCP stats..."
ss -nti dst 10.254.254.9 2>/dev/null | head -3 || echo "no conn"

echo "[$(date '+%H:%M:%S')] Done."
