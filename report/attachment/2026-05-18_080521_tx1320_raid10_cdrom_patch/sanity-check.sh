#!/bin/sh
set -eu
WORK=/home/ubuntu/projects/pvese/tmp/6a031ae5/check
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "=== Sanity check (a)-(d) for patched ISO ==="

7z e -y /var/samba/public/debian-training-tx1320-raid10.iso install.amd/initrd.gz > /dev/null 2>&1
gunzip -c initrd.gz > initrd.cpio

echo "--- (a) decompressed cpio should have 2 TRAILER!!! markers ---"
COUNT_TRAILER=$(grep -aoF "TRAILER!!!" initrd.cpio | wc -l)
echo "TRAILER!!! count: $COUNT_TRAILER (expected: 2)"
[ "$COUNT_TRAILER" -ge 2 ] || { echo "FAIL: (a) TRAILER count < 2"; exit 1; }

echo ""
echo "--- (b) stream 2 should contain preseed.cfg + cdrom-detect.postinst ---"
python3 /home/ubuntu/projects/pvese/tmp/6a031ae5/list-cpio-streams.py initrd.cpio > stream-listing.txt
STREAM2_PRESEED=$(grep -c '^stream=2 size=.* name=preseed\.cfg$' stream-listing.txt || true)
STREAM2_POSTINST=$(grep -c '^stream=2 size=.* name=var/lib/dpkg/info/cdrom-detect\.postinst$' stream-listing.txt || true)
echo "Stream 2 preseed.cfg entries: $STREAM2_PRESEED (expected: 1)"
echo "Stream 2 cdrom-detect.postinst entries: $STREAM2_POSTINST (expected: 1)"
[ "$STREAM2_PRESEED" -eq 1 ] || { echo "FAIL: (b) preseed.cfg missing from stream 2"; exit 1; }
[ "$STREAM2_POSTINST" -eq 1 ] || { echo "FAIL: (b) cdrom-detect.postinst missing from stream 2"; exit 1; }

echo ""
echo "--- (c) initrd.cpio should contain 'pvese-patch v1' marker ---"
PATCH_MARKER=$(grep -aoF "pvese-patch v1" initrd.cpio | wc -l)
echo "pvese-patch v1 marker count: $PATCH_MARKER (expected: >=1)"
[ "$PATCH_MARKER" -ge 1 ] || { echo "FAIL: (c) patch marker missing"; exit 1; }

echo ""
echo "--- (d) initrd.cpio should reference /dev/sr1 ---"
DEV_SR1=$(grep -aoF "/dev/sr1" initrd.cpio | wc -l)
echo "/dev/sr1 reference count: $DEV_SR1 (expected: >=1)"
[ "$DEV_SR1" -ge 1 ] || { echo "FAIL: (d) /dev/sr1 reference missing"; exit 1; }

echo ""
echo "=== ALL SANITY CHECKS PASSED ==="
