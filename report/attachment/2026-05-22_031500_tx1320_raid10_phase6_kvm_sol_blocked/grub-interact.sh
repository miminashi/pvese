#!/bin/sh
# GRUB shell driving via iRMC KVM (Playwright)
# Workflow:
#   wait 140s (BIOS POST) → screenshot pre
#   wait 30s (menu appears, timeout=300 keeps it open) → screenshot menu
#   sendkeys c (enter command line) → wait 3s → screenshot shell prompt
#   type ls + Enter → check device names (could be (cd0), (memdisk), (usb0), ...)
#   type ls (cd0)/install.amd/ + Enter → file listing with sizes
#   type ls (cd0)/install.amd/vmlinuz + Enter → vmlinuz size alone
#   type ls (cd0)/install.amd/initrd.gz + Enter → initrd size alone
#   type cat (cd0)/install.amd/vmlinuz + Enter → full read test (60s+60s observation)
#
# Note: irmc-kvm-interact.py shell parses on ';' so we cannot embed ';' in args.
# GRUB commands do not need ';' so all GRUB strings are safe.
set -eu
SID=phase6a01
.venv/bin/python scripts/irmc-kvm-interact.py \
    --bmc-ip 10.254.254.9 --bmc-user claude --bmc-pass Claude123 \
    --capture-mode=locator --focus-mode=hittest --timeout 600 \
    shell "wait:140; screenshot:tmp/${SID}/kvm-grub-pre.png; wait:30; screenshot:tmp/${SID}/kvm-grub-menu.png; sendkeys:c; wait:3; screenshot:tmp/${SID}/kvm-grub-shell.png; type:ls; sendkeys:Enter; wait:3; screenshot:tmp/${SID}/kvm-grub-ls-devices.png; type:ls (cd0)/install.amd/; sendkeys:Enter; wait:5; screenshot:tmp/${SID}/kvm-grub-ls-amd.png; type:ls (cd0)/install.amd/vmlinuz; sendkeys:Enter; wait:5; screenshot:tmp/${SID}/kvm-grub-ls-vmlinuz.png; type:ls (cd0)/install.amd/initrd.gz; sendkeys:Enter; wait:5; screenshot:tmp/${SID}/kvm-grub-ls-initrd.png; type:cat (cd0)/install.amd/vmlinuz; sendkeys:Enter; wait:60; screenshot:tmp/${SID}/kvm-grub-cat-mid.png; wait:60; screenshot:tmp/${SID}/kvm-grub-cat-late.png"
