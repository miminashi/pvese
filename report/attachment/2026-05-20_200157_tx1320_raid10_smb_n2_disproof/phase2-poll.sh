#!/bin/sh
# Phase 2 Members polling — sudo 不要
PROJ=/home/ubuntu/projects/pvese
SID=0d1fb010
cd "$PROJ"

echo "==== Phase 2: Members polling (24 iter * 5s = 120s) ===="
echo "Start: $(date +%H:%M:%S)"

i=1
while [ "$i" -le 24 ]; do
  ts=$(date +%H:%M:%S)
  body=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/VirtualMedia' 2>/dev/null || true)
  count=$(printf '%s' "$body" | grep -oE '"Members@odata.count":[ ]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
  count=${count:-?}
  echo "[iter=$i] $ts members=$count"
  i=$((i + 1))
  sleep 5
done
echo "End: $(date +%H:%M:%S)"
