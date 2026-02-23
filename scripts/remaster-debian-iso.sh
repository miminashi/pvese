#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

ORIG_ISO="${1:-/var/samba/public/debian-13.3.0-amd64-netinst.iso}"
PRESEED="${2:-${PROJECT_DIR}/preseed/preseed.cfg}"
OUTPUT_ISO="${3:-/var/samba/public/debian-preseed.iso}"

case "$ORIG_ISO" in /*) ;; *) ORIG_ISO="$(cd "$(dirname "$ORIG_ISO")" && pwd)/$(basename "$ORIG_ISO")" ;; esac
case "$PRESEED" in /*) ;; *) PRESEED="$(cd "$(dirname "$PRESEED")" && pwd)/$(basename "$PRESEED")" ;; esac
case "$OUTPUT_ISO" in /*) ;; *) OUTPUT_ISO="$(cd "$(dirname "$OUTPUT_ISO")" && pwd)/$(basename "$OUTPUT_ISO")" ;; esac

if [ ! -f "$ORIG_ISO" ]; then
    echo "ERROR: Original ISO not found: $ORIG_ISO" >&2
    exit 1
fi

if [ ! -f "$PRESEED" ]; then
    echo "ERROR: Preseed file not found: $PRESEED" >&2
    exit 1
fi

echo "=== Debian ISO Remaster (boot_image replay) ==="
echo "Source ISO: $ORIG_ISO"
echo "Preseed:    $PRESEED"
echo "Output ISO: $OUTPUT_ISO"

docker run --rm \
    -v "$ORIG_ISO:/input.iso:ro" \
    -v "$PRESEED:/preseed.cfg:ro" \
    -v "$(dirname "$OUTPUT_ISO"):/output" \
    debian:trixie sh -c '
set -eu

apt-get update -qq
apt-get install -y -qq xorriso cpio gzip mtools > /dev/null 2>&1

WORK=/tmp/isowork
mkdir -p "$WORK/irmod" "$WORK/mod" "$WORK/efi"

echo "--- Extracting initrd from ISO ---"
xorriso -osirrox on -indev /input.iso \
    -extract /install.amd/initrd.gz "$WORK/initrd.gz.orig" \
    2>&1 | tail -1

echo "--- Injecting preseed.cfg into initrd ---"
cd "$WORK/irmod"
gunzip -c "$WORK/initrd.gz.orig" > initrd.cpio
cp /preseed.cfg .
echo preseed.cfg | cpio -H newc -o -A -F initrd.cpio 2>&1
gzip -c initrd.cpio > "$WORK/mod/initrd.gz"
cd /

echo "--- Preparing modified config files ---"
cat > "$WORK/mod/grub.cfg" << GRUBCFG
set default=0
set timeout=3

serial --speed=115200 --unit=1 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

search --file --set=root /install.amd/vmlinuz

menuentry "Automated Install" {
    linux /install.amd/vmlinuz auto=true priority=critical locale=en_US.UTF-8 keymap=us console=tty0 console=ttyS1,115200n8 ---
    initrd /install.amd/initrd.gz
}
GRUBCFG

cat > "$WORK/mod/txt.cfg" << TXTCFG
default auto
label auto
  menu label ^Automated Install
  kernel /install.amd/vmlinuz
  append auto=true priority=critical locale=en_US.UTF-8 keymap=us console=tty0 console=ttyS1,115200n8 initrd=/install.amd/initrd.gz ---
TXTCFG

cat > "$WORK/mod/isolinux.cfg" << ISOCFG
serial 1 115200
console 1
timeout 30
default auto
include txt.cfg
ISOCFG

cp /preseed.cfg "$WORK/mod/preseed.cfg"

echo "--- Patching efi.img for serial console (Option A: mtools) ---"
xorriso -osirrox on -indev /input.iso \
    -extract /boot/grub/efi.img "$WORK/efi/efi.img" \
    2>&1 | tail -1

EFI_PATCHED=false

mdir -i "$WORK/efi/efi.img" ::/EFI/boot/ 2>&1 || true

cat > "$WORK/efi/serial-grub.cfg" << SERIALCFG
serial --speed=115200 --unit=1 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console
SERIALCFG

if mcopy -i "$WORK/efi/efi.img" ::/EFI/boot/grub.cfg "$WORK/efi/grub-efi-orig.cfg" 2>/dev/null; then
    echo "Found grub.cfg inside efi.img, patching..."
    cat "$WORK/efi/serial-grub.cfg" "$WORK/efi/grub-efi-orig.cfg" > "$WORK/efi/grub-efi-new.cfg"
    if mcopy -o -i "$WORK/efi/efi.img" "$WORK/efi/grub-efi-new.cfg" ::/EFI/boot/grub.cfg 2>/dev/null; then
        echo "Option A succeeded: efi.img grub.cfg patched with serial console"
        EFI_PATCHED=true
    else
        echo "Option A failed: not enough space in efi.img FAT, trying Option B..."
    fi
else
    echo "No grub.cfg in efi.img, need Option B (rebuild with grub-mkstandalone)..."
fi

if [ "$EFI_PATCHED" = false ]; then
    echo "--- Option B: Rebuilding efi.img with grub-mkstandalone ---"
    apt-get install -y -qq grub-efi-amd64-bin dosfstools > /dev/null 2>&1

    cat > "$WORK/efi/embed.cfg" << EMBEDCFG
serial --speed=115200 --unit=1 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set default=0
set timeout=3

search --file --set=root /install.amd/vmlinuz

menuentry "Automated Install" {
    linux /install.amd/vmlinuz auto=true priority=critical locale=en_US.UTF-8 keymap=us console=tty0 console=ttyS1,115200n8 ---
    initrd /install.amd/initrd.gz
}
EMBEDCFG

    grub-mkstandalone --format=x86_64-efi \
        --modules="serial terminal search search_fs_file search_label part_gpt part_msdos fat iso9660 normal linux" \
        --output="$WORK/efi/bootx64.efi" \
        "boot/grub/grub.cfg=$WORK/efi/embed.cfg"

    efi_file_size=$(wc -c < "$WORK/efi/bootx64.efi")
    efi_size_kb=$(( (efi_file_size / 1024) + 512 ))
    orig_size=$(wc -c < "$WORK/efi/efi.img")
    orig_size_kb=$((orig_size / 1024))
    if [ "$efi_size_kb" -lt "$orig_size_kb" ]; then
        efi_size_kb="$orig_size_kb"
    fi
    if [ "$efi_size_kb" -lt 2048 ]; then
        efi_size_kb=2048
    fi
    echo "EFI standalone size: ${efi_file_size}B, FAT image: ${efi_size_kb}KB"

    rm -f "$WORK/efi/efi.img"
    mkfs.vfat -C "$WORK/efi/efi.img" "$efi_size_kb"
    mmd -i "$WORK/efi/efi.img" ::/EFI
    mmd -i "$WORK/efi/efi.img" ::/EFI/boot
    mcopy -i "$WORK/efi/efi.img" "$WORK/efi/bootx64.efi" ::/EFI/boot/bootx64.efi
    echo "Option B succeeded: efi.img rebuilt with serial console"
    EFI_PATCHED=true
fi

echo "--- Rebuilding ISO (preserving original boot structure) ---"
rm -f "/output/debian-preseed.iso"
xorriso -indev /input.iso \
    -outdev "/output/debian-preseed.iso" \
    -boot_image any replay \
    -joliet on \
    -update "$WORK/mod/initrd.gz" /install.amd/initrd.gz \
    -update "$WORK/mod/grub.cfg" /boot/grub/grub.cfg \
    -update "$WORK/mod/txt.cfg" /isolinux/txt.cfg \
    -update "$WORK/mod/isolinux.cfg" /isolinux/isolinux.cfg \
    -update "$WORK/efi/efi.img" /boot/grub/efi.img \
    -map "$WORK/mod/preseed.cfg" /preseed.cfg \
    2>&1

echo "--- Done ---"
ls -lh /output/debian-preseed.iso
'

echo "=== Output: $OUTPUT_ISO ==="
ls -lh "$OUTPUT_ISO"
