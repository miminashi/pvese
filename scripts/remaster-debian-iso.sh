#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

LEGACY_ONLY=false
SERIAL_UNIT=1
INCLUDE_FILES=""
POSITIONAL=""
for arg in "$@"; do
    case "$arg" in
        --legacy-only) LEGACY_ONLY=true ;;
        --serial-unit=*) SERIAL_UNIT="${arg#--serial-unit=}" ;;
        --include=*)
            inc="${arg#--include=}"
            INCLUDE_FILES="${INCLUDE_FILES:+$INCLUDE_FILES }$inc"
            ;;
        *) POSITIONAL="${POSITIONAL:+$POSITIONAL }$arg" ;;
    esac
done
set -- $POSITIONAL

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
if [ "$LEGACY_ONLY" = true ]; then
    echo "Mode:       Legacy BIOS only (EFI patch skipped)"
fi

OUTPUT_BASENAME=$(basename "$OUTPUT_ISO")

INCLUDE_VOLS=""
INCLUDE_BASENAMES=""
if [ -n "$INCLUDE_FILES" ]; then
    for f in $INCLUDE_FILES; do
        case "$f" in /*) ;; *) f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" ;; esac
        if [ ! -f "$f" ]; then
            echo "ERROR: --include file not found: $f" >&2
            exit 1
        fi
        bn=$(basename "$f")
        INCLUDE_VOLS="$INCLUDE_VOLS -v $f:/include/$bn:ro"
        INCLUDE_BASENAMES="${INCLUDE_BASENAMES:+$INCLUDE_BASENAMES }$bn"
        echo "Include:    $f -> /$bn"
    done
fi

docker run --rm --dns 8.8.8.8 \
    -e "LEGACY_ONLY=$LEGACY_ONLY" \
    -e "SERIAL_UNIT=$SERIAL_UNIT" \
    -e "OUTPUT_BASENAME=$OUTPUT_BASENAME" \
    -e "INCLUDE_BASENAMES=$INCLUDE_BASENAMES" \
    -v "$ORIG_ISO:/input.iso:ro" \
    -v "$PRESEED:/preseed.cfg:ro" \
    -v "$(dirname "$OUTPUT_ISO"):/output" \
    $INCLUDE_VOLS \
    debian:trixie sh -c '
set -eu

apt-get update -qq
apt-get install -y -qq xorriso cpio gzip mtools > /dev/null 2>&1

WORK=/tmp/isowork
mkdir -p "$WORK/irmod" "$WORK/mod" "$WORK/efi"

# Inject /preseed.cfg into install.amd/initrd.gz so debian-installer auto-loads
# preseed BEFORE cdrom-detect runs. Required for cdrom-detect-skip via
# preseed/early_command (chicken-and-egg with /cdrom/preseed.cfg path).
# See report/2026-05-18_025914_tx1320_raid10_cdrom_detect_cmdline_failed.md.
#
# Method: Linux kernel initramfs supports CONCATENATED gzipped cpio archives
# (each stream processed in turn, later files override earlier). Build a tiny
# cpio with just preseed.cfg, gzip -9 it, and append to the original initrd.gz
# byte-for-byte. Avoids mutating the original archive internal trailer or
# padding, which can produce subtly-malformed initrds that crash kernel boot
# (observed 2026-05-18 followup, cpio -A approach: GRUB boot loops).
echo "--- Injecting /preseed.cfg into install.amd/initrd.gz (concatenated archive) ---"
xorriso -osirrox on -indev /input.iso \
    -extract /install.amd/initrd.gz "$WORK/irmod/initrd-orig.gz" 2>&1 | tail -1
mkdir -p "$WORK/irmod/inject"
cp /preseed.cfg "$WORK/irmod/inject/preseed.cfg"
(
    cd "$WORK/irmod/inject"
    echo preseed.cfg | cpio -o -H newc > "$WORK/irmod/extra.cpio"
) 2>&1 | tail -2
gzip -9 -f "$WORK/irmod/extra.cpio"
cat "$WORK/irmod/initrd-orig.gz" "$WORK/irmod/extra.cpio.gz" > "$WORK/irmod/initrd.gz"
INITRD_UPDATE_ARGS="-update $WORK/irmod/initrd.gz /install.amd/initrd.gz"
echo "Initrd patched, orig=$(stat -c%s "$WORK/irmod/initrd-orig.gz") extra=$(stat -c%s "$WORK/irmod/extra.cpio.gz") total=$(stat -c%s "$WORK/irmod/initrd.gz") bytes"

echo "--- Preparing modified config files ---"
cat > "$WORK/mod/grub.cfg" << GRUBCFG
set default=0
set timeout=3

serial --speed=115200 --unit=${SERIAL_UNIT} --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

search --file --set=root /install.amd/vmlinuz

menuentry "Automated Install" {
    linux /install.amd/vmlinuz vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS${SERIAL_UNIT},115200n8 --- quiet
    initrd /install.amd/initrd.gz
}
GRUBCFG

cat > "$WORK/mod/txt.cfg" << TXTCFG
default auto
label auto
  menu label ^Automated Install
  kernel /install.amd/vmlinuz
  append vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS${SERIAL_UNIT},115200n8 initrd=/install.amd/initrd.gz --- quiet
label install
  menu label ^Install
  kernel /install.amd/vmlinuz
  append vga=normal nomodeset initrd=/install.amd/initrd.gz --- quiet
TXTCFG

cat > "$WORK/mod/isolinux.cfg" << ISOCFG
serial ${SERIAL_UNIT} 115200
timeout 30
default auto
include txt.cfg
ISOCFG

cp /preseed.cfg "$WORK/mod/preseed.cfg"

EFI_UPDATE_ARGS=""
if [ "$LEGACY_ONLY" = "true" ]; then
    echo "--- Skipping EFI patch (--legacy-only mode) ---"
else
    echo "--- Patching efi.img for serial console (Option A: mtools) ---"
    xorriso -osirrox on -indev /input.iso \
        -extract /boot/grub/efi.img "$WORK/efi/efi.img" \
        2>&1 | tail -1

    EFI_PATCHED=false

    mdir -i "$WORK/efi/efi.img" ::/EFI/boot/ 2>&1 || true

    cat > "$WORK/efi/serial-grub.cfg" << SERIALCFG
serial --speed=115200 --unit=${SERIAL_UNIT} --word=8 --parity=no --stop=1
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
serial --speed=115200 --unit=${SERIAL_UNIT} --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set default=0
set timeout=3

search --file --set=root /install.amd/vmlinuz

menuentry "Automated Install" {
    linux /install.amd/vmlinuz vga=normal nomodeset auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=tty0 console=ttyS${SERIAL_UNIT},115200n8 --- quiet
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
    EFI_UPDATE_ARGS="-update $WORK/efi/efi.img /boot/grub/efi.img"
fi

INCLUDE_MAP_ARGS=""
if [ -n "${INCLUDE_BASENAMES:-}" ]; then
    for bn in $INCLUDE_BASENAMES; do
        INCLUDE_MAP_ARGS="$INCLUDE_MAP_ARGS -map /include/$bn /$bn"
        echo "ISO include: /$bn"
    done
fi

echo "--- Rebuilding ISO (preserving original boot structure) ---"
rm -f "/output/$OUTPUT_BASENAME"
xorriso -indev /input.iso \
    -outdev "/output/$OUTPUT_BASENAME" \
    -boot_image any replay \
    -joliet on \
    -update "$WORK/mod/grub.cfg" /boot/grub/grub.cfg \
    -update "$WORK/mod/txt.cfg" /isolinux/txt.cfg \
    -update "$WORK/mod/isolinux.cfg" /isolinux/isolinux.cfg \
    $EFI_UPDATE_ARGS \
    $INITRD_UPDATE_ARGS \
    -map "$WORK/mod/preseed.cfg" /preseed.cfg \
    $INCLUDE_MAP_ARGS \
    2>&1

echo "--- Done ---"
ls -lh "/output/$OUTPUT_BASENAME"
'

echo "=== Output: $OUTPUT_ISO ==="
ls -lh "$OUTPUT_ISO"
