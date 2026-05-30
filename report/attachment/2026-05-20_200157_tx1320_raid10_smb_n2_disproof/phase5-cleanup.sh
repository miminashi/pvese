#!/bin/sh
# Phase 5 cleanup — must be run as root (sudo)
set -u
PROJ=/home/ubuntu/projects/pvese
SID=0d1fb010
cd "$PROJ"

export BMC_SCHEME=https
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export BMC_PATCH_REQUIRES_ETAG=1

echo "==== Phase 5: Cleanup + 互換性復元 ===="
echo "Start: $(date +%H:%M:%S)"

echo "-- step 1: DisconnectCD --"
discode=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"VirtualMediaAction":"DisconnectCD"}' \
  -o /tmp/disc-out.json -w '%{http_code}' \
  'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia' || echo "curl_fail")
echo "DisconnectCD HTTP=$discode"

echo "-- step 2: smb.conf 復元 --"
cp "tmp/$SID/smb.conf.backup" /etc/samba/smb.conf
echo "   diff:"
diff "tmp/$SID/smb.conf.backup" /etc/samba/smb.conf || true

echo "-- step 3: smbcontrol reload + close-share --"
smbcontrol smbd reload-config
smbcontrol smbd close-share public

echo "-- step 4: 元 ISO に config 戻す --"
./scripts/irmc-virtualmedia.sh --type=CD config 10.254.254.9 claude Claude123 \
    10.1.6.1 public debian-training-tx1320-raid10.iso guest guest

echo "-- step 5: status 確認 --"
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123

echo "End: $(date +%H:%M:%S)"
