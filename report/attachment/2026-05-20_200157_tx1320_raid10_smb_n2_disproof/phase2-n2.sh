#!/bin/sh
# Phase 2 N2 trigger script — must be run as root (sudo)
# 1) smb.conf に log level=10 を適用
# 2) Samba debug log を truncate
# 3) smbcontrol reload + close-share
# 4) iRMC DisconnectCD (HTTP 400 = 既 disconnected 想定内)
# 5) 10s 待機
# 6) irmc-virtualmedia.sh config で ISO を debian-13.3.0-amd64-netinst.iso に切り替え
# 7) iRMC ConnectCD (HTTP 204 期待)

set -u
PROJ=/home/ubuntu/projects/pvese
SID=0d1fb010
cd "$PROJ"

export BMC_SCHEME=https
export BMC_CURL_OPTS="--ciphers DEFAULT@SECLEVEL=0"
export BMC_PATCH_REQUIRES_ETAG=1

echo "==== Phase 2: N2 trigger ===="
echo "Start: $(date +%H:%M:%S)"

echo "-- step 1: smb.conf 切替 (log level=10) --"
cp "tmp/$SID/smb.conf.test-n2" /etc/samba/smb.conf
echo "   diff:"
diff "tmp/$SID/smb.conf.backup" /etc/samba/smb.conf || true

echo "-- step 2: Samba log truncate --"
truncate -s 0 /var/log/samba/log.10.254.254.9 2>/dev/null || true
truncate -s 0 /var/log/samba/log. 2>/dev/null || true

echo "-- step 3: smbcontrol reload + close-share --"
smbcontrol smbd reload-config
smbcontrol smbd close-share public

echo "-- step 4: DisconnectCD --"
discode=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"VirtualMediaAction":"DisconnectCD"}' \
  -o /tmp/disc-out.json -w '%{http_code}' \
  'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia' || echo "curl_fail")
echo "DisconnectCD HTTP=$discode"
cat /tmp/disc-out.json 2>/dev/null || true
echo ""

echo "-- step 5: 10s 待機 --"
sleep 10

echo "-- step 6: ISO 切替 config --"
./scripts/irmc-virtualmedia.sh --type=CD config 10.254.254.9 claude Claude123 \
    10.1.6.1 public debian-13.3.0-amd64-netinst.iso guest guest

echo "-- step 6b: status 確認 --"
./scripts/irmc-virtualmedia.sh --type=CD status 10.254.254.9 claude Claude123

echo "-- step 7: ConnectCD --"
connect_code=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"VirtualMediaAction":"ConnectCD"}' \
  -o /tmp/conn-out.json -w '%{http_code}' \
  'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia' || echo "curl_fail")
echo "ConnectCD HTTP=$connect_code"
cat /tmp/conn-out.json 2>/dev/null || true
echo ""

echo "End: $(date +%H:%M:%S)"
