#!/bin/sh
set -eu

BMC_IP=10.254.254.9
USER=claude
PASS=Claude123

echo "[$(date '+%H:%M:%S')] ForceOff host first..."
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"ForceOff"}' \
    -w '\nHTTP %{http_code}\n' \
    "https://$BMC_IP/redfish/v1/Systems/0/Actions/ComputerSystem.Reset" || true

echo "[$(date '+%H:%M:%S')] wait 15s..."
sleep 15

echo "[$(date '+%H:%M:%S')] Sending Manager.Reset ForceRestart..."
code=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"ForceRestart"}' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/reset2-resp.json \
    -w '%{http_code}' \
    "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Manager.Reset")
echo "[$(date '+%H:%M:%S')] HTTP $code"

echo "[$(date '+%H:%M:%S')] Waiting 30s for reset to begin..."
sleep 30

echo "[$(date '+%H:%M:%S')] Polling BMC for recovery (max 300s)..."
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
        echo "$elapsed" > /home/ubuntu/projects/pvese/tmp/9d15d229/reset2-elapsed.txt
        break
    fi
    if [ "$elapsed" -ge 300 ]; then
        echo "[$(date '+%H:%M:%S')] TIMEOUT (300s)"
        exit 1
    fi
done

echo "[$(date '+%H:%M:%S')] State checks after reset:"
curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/vm-after-reset2.json
python3 -c "import json; d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/vm-after-reset2.json')); print('Members=', d.get('Members@odata.count'))"

curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    'https://10.254.254.9/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/oem-vm-after-reset2.json
python3 -c "
import json
d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/oem-vm-after-reset2.json'))
print('UsbAttachMode=', d.get('UsbAttachMode'))
print('RemoteMountEnabled=', d.get('RemoteMountEnabled'))
print('CDImage=', d.get('CDImage'))
"

curl -sk --ciphers DEFAULT@SECLEVEL=0 -u "$USER:$PASS" \
    'https://10.254.254.9/redfish/v1/Systems/0' \
    -o /home/ubuntu/projects/pvese/tmp/9d15d229/system0-after-reset2.json
python3 -c "
import json
d=json.load(open('/home/ubuntu/projects/pvese/tmp/9d15d229/system0-after-reset2.json'))
print('PowerState=', d.get('PowerState'))
oem=d.get('Actions',{}).get('Oem',{})
for k,v in oem.items():
    if 'VirtualMedia' in k:
        print('VirtualMediaAction.AllowableValues=', v.get('VirtualMediaAction@Redfish.AllowableValues'))
"
echo "[$(date '+%H:%M:%S')] Done."
