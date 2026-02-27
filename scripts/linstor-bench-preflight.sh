#!/bin/sh
set -eu

usage() {
    echo "Usage: linstor-bench-preflight.sh /dev/sda /dev/sdb ..."
    echo "Check SMART health of storage disks before benchmark."
    echo "Exit 0: all disks healthy"
    echo "Exit 1: bad sectors detected (details on stdout)"
    exit 2
}

if [ $# -eq 0 ]; then
    usage
fi

bad_count=0
checked=0

for disk in "$@"; do
    if [ ! -b "$disk" ]; then
        echo "SKIP: $disk is not a block device"
        continue
    fi

    checked=$((checked + 1))
    pending=$(smartctl -A "$disk" | awk '/Current_Pending_Sector/ {print $10}')
    reallocated=$(smartctl -A "$disk" | awk '/Reallocated_Sector_Ct/ {print $10}')
    offline=$(smartctl -A "$disk" | awk '/Offline_Uncorrectable/ {print $10}')

    pending=${pending:-0}
    reallocated=${reallocated:-0}
    offline=${offline:-0}

    if [ "$pending" -gt 0 ] || [ "$offline" -gt 0 ]; then
        echo "BAD: $disk — Current_Pending=$pending Reallocated=$reallocated Offline_Uncorrectable=$offline"
        bad_count=$((bad_count + 1))
    else
        echo "OK:  $disk — Current_Pending=$pending Reallocated=$reallocated Offline_Uncorrectable=$offline"
    fi
done

echo ""
echo "Checked $checked disks, $bad_count with bad sectors"

if [ "$bad_count" -gt 0 ]; then
    echo "ACTION: Zero-fill bad disks to force sector reallocation"
    exit 1
fi

exit 0
