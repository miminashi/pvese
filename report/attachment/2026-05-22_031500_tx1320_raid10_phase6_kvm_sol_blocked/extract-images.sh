#!/bin/sh
# Extract vmlinuz + initrd.gz from local ISO using docker (xorriso in debian:trixie)
set -eu
ISO=/var/samba/public/debian-training-tx1320-raid10.iso
HOST_OUT="$(pwd)/tmp/phase6a01"
docker run --rm \
    -v "$ISO":/input.iso:ro \
    -v "$HOST_OUT":/output \
    debian:trixie sh -c '
        apt-get update -qq
        apt-get install -y -qq xorriso > /dev/null 2>&1
        xorriso -osirrox on -indev /input.iso -extract /install.amd/vmlinuz /output/local-vmlinuz 2>&1 | tail -3
        xorriso -osirrox on -indev /input.iso -extract /install.amd/initrd.gz /output/local-initrd.gz 2>&1 | tail -3
        stat -c "%n %s" /output/local-vmlinuz /output/local-initrd.gz
        sha256sum /output/local-vmlinuz /output/local-initrd.gz
    ' | tee "$HOST_OUT/local-image-sizes.txt"
