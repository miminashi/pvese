#!/bin/sh
set -eu

echo "=== Phase 1: iRMC Manager.Reset GracefulRestart ==="
date

curl -sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30 \
    -u claude:Claude123 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"ResetType":"GracefulRestart"}' \
    -w '\nHTTP:%{http_code}\n' \
    'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset'

echo "=== Reset POST done. Sleeping 30s before polling ==="
sleep 30
echo "=== Sleep done ==="
date
