#!/bin/sh
set -u
# Members polling: 24 iter * 5s = 120s
# attach 成立 = Members>=1 で early exit

cd /home/ubuntu/projects/pvese

LOG=tmp/329269dc/phase2-poll.log
: > "$LOG"

i=1
while [ "$i" -le 24 ]; do
    ts=$(date +%H:%M:%S)
    members_raw=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 --max-time 10 \
        -u claude:Claude123 \
        'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' 2>&1)
    count=$(echo "$members_raw" | grep -oE '"Members@odata.count"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
    if [ -z "$count" ]; then count="?"; fi
    cd_raw=$(./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123 2>&1)
    echo "iter=$i  ts=$ts  Members.count=$count" >> "$LOG"
    echo "--cd_status--" >> "$LOG"
    echo "$cd_raw" >> "$LOG"
    echo "----" >> "$LOG"
    echo "iter=$i  ts=$ts  Members.count=$count"
    if [ "$count" != "?" ] && [ "$count" -ge 1 ] 2>/dev/null; then
        echo "ATTACH ESTABLISHED at iter=$i ($((i*5))s after polling start). Members.count=$count"
        echo "$members_raw" > tmp/329269dc/phase2-virtualmedia-final.json
        exit 0
    fi
    sleep 5
    i=$((i+1))
done
echo "ATTACH NOT ESTABLISHED within 120s (Members.count=0 throughout)"
exit 1
