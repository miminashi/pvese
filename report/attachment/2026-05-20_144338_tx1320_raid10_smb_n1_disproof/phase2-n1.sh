#!/bin/sh
set -eu

echo "=== Phase 2 step 1: chown ISO to nobody:nogroup (N1 setup) ==="
chown nobody:nogroup /var/samba/public/debian-training-tx1320-raid10.iso
ls -la /var/samba/public/debian-training-tx1320-raid10.iso

echo
echo "=== Phase 2 step 2: install smb.conf.test-n1 (log level=10 + force user=nobody) ==="
cp /home/ubuntu/projects/pvese/tmp/329269dc/smb.conf.test-n1 /etc/samba/smb.conf
echo "smb.conf installed. diff against backup:"
diff /home/ubuntu/projects/pvese/tmp/329269dc/smb.conf.backup /etc/samba/smb.conf || true

echo
echo "=== Phase 2 step 3: truncate Samba debug logs ==="
truncate -s 0 /var/log/samba/log.10.254.254.9 2>/dev/null || true
truncate -s 0 /var/log/samba/log. 2>/dev/null || true
ls -la /var/log/samba/ | head -20

echo
echo "=== Phase 2 step 4: reload smbd + close-share public ==="
smbcontrol smbd reload-config
sleep 1
smbcontrol smbd close-share public
sleep 3

echo
echo "=== Phase 2 step 5: iRMC DisconnectCD (clear current session) ==="
curl -sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30 \
    -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"DisconnectCD"}' \
    -w '\nHTTP:%{http_code}\n' \
    'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia' || true

echo
echo "Sleeping 10s for DisconnectCD to settle..."
sleep 10

echo
echo "=== Phase 2 step 6: iRMC ConnectCD (N1 trigger) ==="
date
curl -sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30 \
    -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"ConnectCD"}' \
    -w '\nHTTP:%{http_code}\n' \
    'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia'

echo
echo "=== Phase 2 trigger complete. Members polling starts next. ==="
date
