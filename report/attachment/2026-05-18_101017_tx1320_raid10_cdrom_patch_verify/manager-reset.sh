#!/bin/sh
set -eu

BMC_IP=10.254.254.9
USER=claude
PASS=Claude123

echo "[$(date '+%H:%M:%S')] Sending Manager.Reset GracefulRestart..."
code=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/reset-resp.json \
    -w '%{http_code}' \
    "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Manager.Reset")
echo "[$(date '+%H:%M:%S')] HTTP $code"
echo "$code" > /home/ubuntu/projects/pvese/tmp/9d15d229/reset-http-code.txt

if [ "$code" != "204" ] && [ "$code" != "200" ] && [ "$code" != "202" ]; then
    echo "[$(date '+%H:%M:%S')] Trying ForceRestart fallback..."
    code=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
        -X POST -H 'Content-Type: application/json' \
        -d '{"ResetType":"ForceRestart"}' \
        -o /home/ubuntu/projects/pvese/tmp/9d15d229/reset-resp2.json \
        -w '%{http_code}' \
        "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Manager.Reset")
    echo "[$(date '+%H:%M:%S')] ForceRestart HTTP $code"
fi

echo "[$(date '+%H:%M:%S')] Waiting 30s for reset to begin..."
sleep 30

echo "[$(date '+%H:%M:%S')] Polling BMC for recovery (max 240s)..."
start=$(date +%s)
while :; do
    sleep 5
    code=$(curl -sS -k --ciphers DEFAULT@SECLEVEL=0 \
        --connect-timeout 3 --max-time 8 \
        -o /dev/null -w '%{http_code}' \
        "https://$BMC_IP/redfish/v1/" 2>/dev/null || echo 000)
    now=$(date +%s)
    elapsed=$(( now - start ))
    echo "[$(date '+%H:%M:%S')] elapsed=${elapsed}s code=$code"
    if [ "$code" = "200" ]; then
        echo "[$(date '+%H:%M:%S')] BMC up after ${elapsed}s"
        echo "$elapsed" > /home/ubuntu/projects/pvese/tmp/9d15d229/reset-elapsed.txt
        break
    fi
    if [ "$elapsed" -ge 240 ]; then
        echo "[$(date '+%H:%M:%S')] TIMEOUT (240s) BMC did not come back"
        exit 1
    fi
done

echo "[$(date '+%H:%M:%S')] Verifying auth + VirtualMedia after reset..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC_IP/redfish/v1/Managers/iRMC/VirtualMedia" \
    > /home/ubuntu/projects/pvese/tmp/9d15d229/post-vm.json 2>&1
echo "[$(date '+%H:%M:%S')] Done."
