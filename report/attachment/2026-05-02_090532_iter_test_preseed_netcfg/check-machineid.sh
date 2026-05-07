#!/bin/sh
set -eu
INSTALL_START=$(cat state/os-setup/server10/install-monitor.start)
REMOTE_MID=$(ssh -F ssh/config root@10.10.10.210 stat -c %Y /etc/machine-id)
REMOTE_HOST=$(ssh -F ssh/config root@10.10.10.210 stat -c %Y /etc/hostname)
echo "install-monitor.start = ${INSTALL_START} ($(date -d @${INSTALL_START}))"
echo "remote /etc/machine-id mtime = ${REMOTE_MID} ($(date -d @${REMOTE_MID}))"
echo "remote /etc/hostname  mtime = ${REMOTE_HOST} ($(date -d @${REMOTE_HOST}))"
if [ "${REMOTE_MID}" -lt "${INSTALL_START}" ]; then
    echo "ERROR: machine-id predates install-monitor start — FALSE POSITIVE"
    exit 1
fi
if [ "${REMOTE_HOST}" -lt "${INSTALL_START}" ]; then
    echo "ERROR: hostname predates install-monitor start — FALSE POSITIVE"
    exit 1
fi
echo "OK: install verified (machine-id and hostname created after install-monitor start)"
