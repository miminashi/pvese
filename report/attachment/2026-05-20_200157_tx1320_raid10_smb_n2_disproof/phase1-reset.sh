#!/bin/sh
set -eu

echo "==== Phase 1: BMC Manager.Reset (GracefulRestart) ===="
echo "Start: $(date +%H:%M:%S)"

http_code=$(curl -sk --ciphers DEFAULT@SECLEVEL=0 -u claude:Claude123 \
  -X POST -H 'Content-Type: application/json' \
  -d '{"ResetType":"GracefulRestart"}' \
  -o /dev/null -w '%{http_code}' \
  'https://10.254.254.9/redfish/v1/Managers/iRMC/Actions/Manager.Reset' || echo "curl_exit=$?")

echo "Manager.Reset HTTP=$http_code (204 expected)"
echo "End: $(date +%H:%M:%S)"
