#!/bin/sh
# SOL background capture (sol-monitor.py uses named args)
set -eu
SID=phase6a01
.venv/bin/python scripts/sol-monitor.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --log-file "tmp/${SID}/sol-grub.log" \
    --timeout 600
