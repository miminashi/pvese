#!/bin/sh
set -eu
BMC=10.254.254.9
USER=claude
PASS=Claude123
ENDPOINT="https://${BMC}/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia"
CURL="curl -sk --ciphers DEFAULT@SECLEVEL=0 -u ${USER}:${PASS} -H Content-Type:application/json -X POST -w \\nHTTP=%{http_code}\\n ${ENDPOINT}"

echo "--- DisconnectCD ---"
$CURL -d '{"VirtualMediaAction":"DisconnectCD"}'

sleep 2

echo "--- ConnectCD ---"
$CURL -d '{"VirtualMediaAction":"ConnectCD"}'
