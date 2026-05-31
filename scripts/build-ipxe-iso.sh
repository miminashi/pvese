#!/bin/sh
set -eu

# build-ipxe-iso.sh — Wrap an embedded ipxe.efi into a minimal UEFI-bootable ISO
# whose EFI bootloader (/EFI/BOOT/BOOTX64.EFI) is that ipxe.efi.
#
# Why: booting this ISO via BMC Virtual Media starts iPXE directly (no GRUB).
# On the Fujitsu TX1320 M3 / iRMC S4 (BIOS R1.22.0 2018, FW 9.69F) GRUB 2.12
# cannot hand off to the Debian 13 (6.12) kernel — it loads the kernel via the
# firmware StartImage which returns "start_image() returned 0x8000000000000001"
# (EFI_LOAD_ERROR) and triple-fault reset-loops. iPXE uses its own loader and
# boots the same kernel fine (this is why PXE works). Delivering iPXE on a CD
# lets Virtual Media reach a working install path WITHOUT the OpenWrt TFTP
# dependency that firmware PXE-ROM boot requires — iPXE only needs a normal DHCP
# lease + HTTP (kernel/initrd from a public mirror, preseed/storcli from the
# playground), exactly like the pxe-deploy skill. See report
# 2026-05-31_073936_tx1320_virtualmedia_ipxe_cd_install.md.
#
# Usage: build-ipxe-iso.sh <ipxe.efi> <output.iso>
#   <ipxe.efi>    Path to an embedded iPXE EFI binary (built per pxe-deploy skill,
#                 e.g. with EMBED=<host>-embed.ipxe and interface=<PXE NIC>).
#   <output.iso>  Output ISO path (place it where the BMC reads it, e.g. the NFS
#                 export the iRMC mounts).
#
# The ISO is built in a debian:trixie container (xorriso + mtools + dosfstools),
# matching scripts/remaster-debian-iso.sh's toolchain.

IPXE_EFI="${1:?usage: build-ipxe-iso.sh <ipxe.efi> <output.iso>}"
OUTPUT_ISO="${2:?usage: build-ipxe-iso.sh <ipxe.efi> <output.iso>}"

case "$IPXE_EFI" in /*) ;; *) IPXE_EFI="$(cd "$(dirname "$IPXE_EFI")" && pwd)/$(basename "$IPXE_EFI")" ;; esac
case "$OUTPUT_ISO" in /*) ;; *) OUTPUT_ISO="$(cd "$(dirname "$OUTPUT_ISO")" && pwd)/$(basename "$OUTPUT_ISO")" ;; esac

[ -f "$IPXE_EFI" ] || { echo "ERROR: ipxe.efi not found: $IPXE_EFI" >&2; exit 1; }
OUTPUT_BASENAME=$(basename "$OUTPUT_ISO")

echo "=== build iPXE UEFI ISO ==="
echo "ipxe.efi: $IPXE_EFI"
echo "output:   $OUTPUT_ISO"

docker run --rm \
    -e "OUTPUT_BASENAME=$OUTPUT_BASENAME" \
    -v "$IPXE_EFI:/input/ipxe.efi:ro" \
    -v "$(dirname "$OUTPUT_ISO"):/output" \
    debian:trixie sh -c '
set -eu
apt-get update -qq
apt-get install -y -qq xorriso mtools dosfstools > /dev/null 2>&1

WORK=/tmp/ipxeiso
mkdir -p "$WORK/iso/EFI/BOOT"
cp /input/ipxe.efi "$WORK/iso/EFI/BOOT/BOOTX64.EFI"

# El Torito EFI boot image (FAT) containing the same bootx64.efi.
dd if=/dev/zero of="$WORK/iso/efi.img" bs=1M count=4 status=none
mkfs.vfat "$WORK/iso/efi.img" > /dev/null
mmd -i "$WORK/iso/efi.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK/iso/efi.img" /input/ipxe.efi ::/EFI/BOOT/BOOTX64.EFI

xorriso -as mkisofs -V IPXE_BOOT -J -R \
    -e efi.img -no-emul-boot \
    -o "/output/$OUTPUT_BASENAME" "$WORK/iso" 2>&1 | tail -3
ls -lh "/output/$OUTPUT_BASENAME"
'
echo "=== done: $OUTPUT_ISO ==="
