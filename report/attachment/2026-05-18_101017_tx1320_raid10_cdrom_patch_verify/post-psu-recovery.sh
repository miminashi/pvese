#!/bin/sh
set -eu
cd /home/ubuntu/projects/pvese
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export BMC_PATCH_REQUIRES_ETAG=1

BMC=10.254.254.9
USER=claude
PASS=Claude123

echo "[$(date '+%H:%M:%S')] Step 1: Wait for iRMC reachable..."
start=$(date +%s)
while :; do
    sleep 5
    code=$(curl -sS -k --ciphers DEFAULT@SECLEVEL=0 --connect-timeout 3 --max-time 8 \
        -o /dev/null -w '%{http_code}' \
        "https://$BMC/redfish/v1/" 2>/dev/null || echo 000)
    now=$(date +%s)
    elapsed=$(( now - start ))
    echo "[$(date '+%H:%M:%S')] elapsed=${elapsed}s code=$code"
    if [ "$code" = "200" ]; then
        echo "[$(date '+%H:%M:%S')] iRMC up after ${elapsed}s"
        break
    fi
    if [ "$elapsed" -ge 300 ]; then
        echo "[$(date '+%H:%M:%S')] TIMEOUT (300s) — iRMC not responding"
        exit 1
    fi
done

echo "[$(date '+%H:%M:%S')] Step 2: Initial state checks..."
./scripts/bmc-power.sh status "$BMC" "$USER" "$PASS"
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/vm-post-psu.json
python3 -c "import json; d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/vm-post-psu.json')); print('Members=', d.get('Members@odata.count'))"

./scripts/irmc-virtualmedia.sh --type=CD status "$BMC" "$USER" "$PASS"

echo "[$(date '+%H:%M:%S')] Step 3: Re-PATCH CDImage (use original ISO name)..."
./scripts/irmc-virtualmedia.sh config "$BMC" "$USER" "$PASS" \
    10.1.6.1 public debian-training-tx1320-raid10.iso guest guest \
    > /home/ubuntu/projects/pvese/tmp/9d15d229/patch-post-psu.json 2>&1

echo "[$(date '+%H:%M:%S')] Step 4: ConnectCD..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia" \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/conn-post-psu.json
echo

echo "[$(date '+%H:%M:%S')] Step 5: sleep 10s + Members check..."
sleep 10
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/vm-after-connect-post-psu.json
python3 -c "import json; d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/vm-after-connect-post-psu.json')); print('Members=', d.get('Members@odata.count'))"

echo "[$(date '+%H:%M:%S')] Step 6: Samba log..."
ls -la /var/log/samba/log.10.254.254.9
echo "--- log content (last 30 lines) ---"
tail -n 30 /var/log/samba/log.10.254.254.9 || true

echo "[$(date '+%H:%M:%S')] Done — ready to deploy if Members > 0"
