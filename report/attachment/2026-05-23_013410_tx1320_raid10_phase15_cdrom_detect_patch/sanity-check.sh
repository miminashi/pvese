#!/bin/sh
set -eu
SID=0bc594e7
WORK=/home/ubuntu/projects/pvese/tmp/${SID}/check
ISO=/var/samba/public/debian-training-tx1320-raid10.iso
STREAM_LISTER=/home/ubuntu/projects/pvese/report/attachment/2026-05-18_080521_tx1320_raid10_cdrom_patch/list-cpio-streams.py
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "=== Sanity check (a)-(e) for patched ISO: $ISO ==="

7z e -y "$ISO" install.amd/initrd.gz > /dev/null 2>&1
gunzip -c initrd.gz > initrd.cpio

echo "--- (a) decompressed cpio should have 2 TRAILER!!! markers ---"
COUNT_TRAILER=$(grep -aoF "TRAILER!!!" initrd.cpio | wc -l)
echo "TRAILER!!! count: $COUNT_TRAILER (expected: 2)"
if [ "$COUNT_TRAILER" -lt 2 ]; then
    echo "FAIL: (a) TRAILER count < 2" >&2
    exit 1
fi

echo ""
echo "--- (b) stream 2 should contain preseed.cfg + cdrom-detect.postinst ---"
python3 "$STREAM_LISTER" initrd.cpio > stream-listing.txt
STREAM2_PRESEED=$(grep -c '^stream=2 size=.* name=preseed\.cfg$' stream-listing.txt || true)
STREAM2_POSTINST=$(grep -c '^stream=2 size=.* name=var/lib/dpkg/info/cdrom-detect\.postinst$' stream-listing.txt || true)
echo "Stream 2 preseed.cfg entries: $STREAM2_PRESEED (expected: 1)"
echo "Stream 2 cdrom-detect.postinst entries: $STREAM2_POSTINST (expected: 1)"
if [ "$STREAM2_PRESEED" -ne 1 ]; then
    echo "FAIL: (b) preseed.cfg missing from stream 2" >&2
    exit 1
fi
if [ "$STREAM2_POSTINST" -ne 1 ]; then
    echo "FAIL: (b) cdrom-detect.postinst missing from stream 2" >&2
    exit 1
fi

echo ""
echo "--- (c) initrd.cpio should contain 'pvese-patch v1' marker ---"
PATCH_MARKER=$(grep -aoF "pvese-patch v1" initrd.cpio | wc -l)
echo "pvese-patch v1 marker count: $PATCH_MARKER (expected: >=1)"
if [ "$PATCH_MARKER" -lt 1 ]; then
    echo "FAIL: (c) patch marker missing" >&2
    exit 1
fi

echo ""
echo "--- (d) initrd.cpio should reference /dev/sr1 ---"
DEV_SR1=$(grep -aoF "/dev/sr1" initrd.cpio | wc -l)
echo "/dev/sr1 reference count: $DEV_SR1 (expected: >=1)"
if [ "$DEV_SR1" -lt 1 ]; then
    echo "FAIL: (d) /dev/sr1 reference missing" >&2
    exit 1
fi

echo ""
echo "--- (e) patched postinst from stream 2 should pass sh -n + carry marker ---"
EXTRACTOR=/home/ubuntu/projects/pvese/tmp/${SID}/extract-cpio-file.py
python3 "$EXTRACTOR" initrd.cpio 2 var/lib/dpkg/info/cdrom-detect.postinst > postinst-stream2
if [ ! -s postinst-stream2 ]; then
    echo "FAIL: (e) stream-2 postinst extraction empty" >&2
    exit 1
fi
if ! sh -n postinst-stream2; then
    echo "FAIL: (e) stream-2 postinst sh -n failed" >&2
    exit 1
fi
PATCHED_LINES=$(wc -l < postinst-stream2)
PATCHED_SIZE=$(stat -c%s postinst-stream2)
echo "stream-2 postinst sh -n: OK ($PATCHED_LINES lines, $PATCHED_SIZE bytes)"
if ! grep -q "pvese-patch v1: bypassed list-devices" postinst-stream2; then
    echo "FAIL: (e) stream-2 postinst missing patch marker line" >&2
    exit 1
fi
if ! grep -q '\[ "${pvese_skip_main_loop:-0}" = 1 \] && break' postinst-stream2; then
    echo "FAIL: (e) stream-2 postinst missing short-circuit break line" >&2
    exit 1
fi

echo ""
echo "=== ALL SANITY CHECKS PASSED ==="
