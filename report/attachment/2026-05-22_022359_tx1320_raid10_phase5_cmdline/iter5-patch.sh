#!/bin/sh
# iter5: Phase 3 cmdline (= Phase 4 と同じ) を復元 + nousb 追加
# Phase 3 修正は uncommitted のため git checkout で消えていた → 復元する
# nousb は仮説 7 (USB controller quirk) の切り分け
set -eu

TARGET=scripts/remaster-debian-iso.sh

# Phase 3 復元 + iter5 nousb 追加を同時に:
# - GRUB / EFI: `--- quiet` → `earlyprintk=ttyS\${SERIAL_UNIT},115200n8,keep nousb ---`
# - SYSLINUX: `initrd=/install.amd/initrd.gz --- quiet` → `initrd=/install.amd/initrd.gz nousb ---`
# GRUB と EFI line は `console=ttyS\${SERIAL_UNIT},115200n8 --- quiet` で終わる
# SYSLINUX line は `initrd=/install.amd/initrd.gz --- quiet` で終わる
sed -i 's|console=ttyS\${SERIAL_UNIT},115200n8 --- quiet|console=ttyS\${SERIAL_UNIT},115200n8 earlyprintk=ttyS\${SERIAL_UNIT},115200n8,keep nousb ---|g' "$TARGET"
sed -i 's|initrd=/install.amd/initrd.gz --- quiet|initrd=/install.amd/initrd.gz nousb ---|g' "$TARGET"

echo "iter5 patch applied"
grep -nE "console=ttyS|nousb" "$TARGET" | head -10
