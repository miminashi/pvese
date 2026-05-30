#!/bin/sh
# iter4: cmdline から console=tty0 を除去 → ttyS 単独
# 仮説 9 (multi-console hand-off race) の切り分け
set -eu

TARGET=scripts/remaster-debian-iso.sh

# L193 (BIOS GRUB), L203 (SYSLINUX), L266 (EFI embed) の 3 箇所すべて
# `console=tty0 console=ttyS${SERIAL_UNIT},115200n8` → `console=ttyS${SERIAL_UNIT},115200n8`
sed -i 's|console=tty0 console=ttyS\${SERIAL_UNIT},115200n8|console=ttyS\${SERIAL_UNIT},115200n8|g' "$TARGET"

echo "iter4 patch applied"
grep -n "console=ttyS" "$TARGET" | head -5
