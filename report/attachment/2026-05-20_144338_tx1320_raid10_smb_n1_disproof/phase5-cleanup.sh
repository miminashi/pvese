#!/bin/sh
set -eu

echo "=== Phase 5 step 1: restore smb.conf from backup ==="
cp /home/ubuntu/projects/pvese/tmp/329269dc/smb.conf.backup /etc/samba/smb.conf
smbcontrol smbd reload-config
sleep 1
smbcontrol smbd close-share public

echo
echo "=== Phase 5 step 2: restore ISO ownership to root:root ==="
chown root:root /var/samba/public/debian-training-tx1320-raid10.iso
ls -la /var/samba/public/debian-training-tx1320-raid10.iso

echo
echo "=== Phase 5 step 3: verify smb.conf == backup ==="
diff /etc/samba/smb.conf /home/ubuntu/projects/pvese/tmp/329269dc/smb.conf.backup
echo "smb.conf diff exit=$?"

echo
echo "=== Phase 5 step 4: iRMC DisconnectCD (clean state) ==="
curl -sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30 \
    -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"VirtualMediaAction":"DisconnectCD"}' \
    -w '\nHTTP:%{http_code}\n' \
    'https://10.254.254.9/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia' || true

echo
echo "=== Phase 5 cleanup complete ==="
date
