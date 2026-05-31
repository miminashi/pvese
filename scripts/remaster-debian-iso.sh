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
    -e "EXTRA_CMDLINE=${EXTRA_CMDLINE:-}" \
    -e "PVESE_PATCH_CDROM_DETECT=${PVESE_PATCH_CDROM_DETECT:-0}" \
    -e "PVESE_KEEP_ORIG_EFI=${PVESE_KEEP_ORIG_EFI:-0}" \
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

# pvese-patch v1: patch var/lib/dpkg/info/cdrom-detect.postinst to prefer
# /dev/sr1 (iRMC OEM Virtual CDROM) over the empty physical /dev/sr0. Required
# for TX1320 M3 because list-devices does not return /dev/sr1 as a CD (likely
# udev removable= filter or SCSI ID quirk), so the main scan loop sees an
# empty devices list and falls through to the "No installation media" dialog.
# See report/2026-05-18_080521_tx1320_raid10_cdrom_patch.md (original design)
# and report/2026-05-22_154033_tx1320_raid10_phase14_install_completed.md
# (where this block was diagnosed end-to-end on real hardware).
if [ "${PVESE_PATCH_CDROM_DETECT:-0}" = "1" ]; then
    echo "--- pvese-patch v1: patching cdrom-detect.postinst (TX1320 /dev/sr1 priority) ---"
    mkdir -p "$WORK/irmod/orig-extract"
    (
        cd "$WORK/irmod/orig-extract"
        gunzip -c "$WORK/irmod/initrd-orig.gz" \
            | cpio -idm --quiet var/lib/dpkg/info/cdrom-detect.postinst
    )
    if [ ! -f "$WORK/irmod/orig-extract/var/lib/dpkg/info/cdrom-detect.postinst" ]; then
        echo "ERROR: cdrom-detect.postinst not found in original initrd" >&2
        exit 1
    fi
    cat > "$WORK/irmod/patch.awk" << "AWKEND"
BEGIN { inserted = 0 }
/^while true; do$/ && !inserted {
    print "# pvese-patch v1 - TX1320 /dev/sr1 priority"
    print "# /dev/sr0 = physical empty DVD drive (always fails to open)"
    print "# /dev/sr1 = iRMC OEM Virtual CDROM with the installer ISO"
    print "# Safe no-op when /dev/sr1 does not exist (other hardware)."
    print "if [ \"$OS\" = \"linux\" ]; then"
    print "    for count in 1 2 3 4 5; do"
    print "        [ -b /dev/sr1 ] && break"
    print "        sleep 1"
    print "    done"
    print "    if [ -b /dev/sr1 ] && try_mount /dev/sr1 $CDFS; then"
    print "        set_suite_and_codename"
    print "        log \"pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount\""
    print "        # Phase 17 F7: also write to /dev/console so the marker reaches SOL."
    print "        # busybox logger only goes to /var/log/syslog, which is invisible"
    print "        # until install completes. /dev/console is bound to ttyS\\${SERIAL}"
    print "        # via the kernel cmdline (console=ttyS0,115200n8)."
    print "        echo \"pvese-patch v1: bypassed list-devices via /dev/sr1 direct mount\" > /dev/console 2>/dev/null || true"
    print "        pvese_skip_main_loop=1"
    print "    fi"
    print "fi"
    print $0
    print "\t[ \"${pvese_skip_main_loop:-0}\" = 1 ] && break  # pvese-patch v1"
    inserted = 1
    next
}
{ print }
END {
    if (!inserted) {
        print "ERROR: insertion point \"while true; do\" not found" > "/dev/stderr"
        exit 1
    }
}
AWKEND
    mkdir -p "$WORK/irmod/inject/var/lib/dpkg/info"
    awk -f "$WORK/irmod/patch.awk" \
        "$WORK/irmod/orig-extract/var/lib/dpkg/info/cdrom-detect.postinst" \
        > "$WORK/irmod/inject/var/lib/dpkg/info/cdrom-detect.postinst"
    chmod +x "$WORK/irmod/inject/var/lib/dpkg/info/cdrom-detect.postinst"
    if ! sh -n "$WORK/irmod/inject/var/lib/dpkg/info/cdrom-detect.postinst"; then
        echo "ERROR: patched cdrom-detect.postinst sh -n failed" >&2
        exit 1
    fi
    PATCHED_LINES=$(wc -l < "$WORK/irmod/inject/var/lib/dpkg/info/cdrom-detect.postinst")
    PATCHED_SIZE=$(stat -c%s "$WORK/irmod/inject/var/lib/dpkg/info/cdrom-detect.postinst")
    echo "Patched postinst OK ($PATCHED_LINES lines, $PATCHED_SIZE bytes)"
fi

(
    cd "$WORK/irmod/inject"
    find . -mindepth 1 -print | sed "s|^\./||" | cpio -o -H newc > "$WORK/irmod/extra.cpio"
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
    linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=ttyS${SERIAL_UNIT},115200n8 earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ${EXTRA_CMDLINE} ---
    initrd /install.amd/initrd.gz
}
GRUBCFG

cat > "$WORK/mod/txt.cfg" << TXTCFG
default auto
label auto
  menu label ^Automated Install
  kernel /install.amd/vmlinuz
  append auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=ttyS${SERIAL_UNIT},115200n8 earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ${EXTRA_CMDLINE} initrd=/install.amd/initrd.gz ---
label install
  menu label ^Install
  kernel /install.amd/vmlinuz
  append initrd=/install.amd/initrd.gz earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ---
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
elif [ "${PVESE_KEEP_ORIG_EFI:-0}" = "1" ]; then
    # Keep the original Debian signed shim+grub EFI boot image untouched.
    # The signed grubx64.efi (prefix=/EFI/debian) chains:
    #   /EFI/debian/grub.cfg -> /boot/grub/${grub_cpu}-efi/grub.cfg -> /boot/grub/grub.cfg
    # i.e. it sources the ISO /boot/grub/grub.cfg that we overwrite below, so the
    # serial console + auto-boot menuentry take effect WITHOUT rebuilding the EFI
    # image. Rebuilding it with grub-mkstandalone (Option B) produces an UNSIGNED
    # GRUB loaded directly by firmware (no shim); on the Fujitsu D3373 / iRMC S4
    # (BIOS R1.22.0 2018, iRMC FW 9.69F) that GRUB fails to start the kernel EFI
    # image with "start_image() returned 0x8000000000000001" (EFI_LOAD_ERROR) and
    # triple-fault reset-loops at the GRUB->kernel handoff. Keeping the shim chain
    # fixes it. EFI_UPDATE_ARGS stays empty so xorriso preserves the original
    # /boot/grub/efi.img. (2026-05-31 vmnfs531, TX1320 Virtual Media install.)
    echo "--- Keeping original signed EFI boot image (shim chain); serial via /boot/grub/grub.cfg ---"
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
    linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=us netcfg/choose_interface=auto cdrom-detect/try-usb=true cdrom-detect/scan=true hw-detect/load_media=false console=ttyS${SERIAL_UNIT},115200n8 earlyprintk=ttyS${SERIAL_UNIT},115200n8 loglevel=8 ignore_loglevel ${EXTRA_CMDLINE} ---
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
