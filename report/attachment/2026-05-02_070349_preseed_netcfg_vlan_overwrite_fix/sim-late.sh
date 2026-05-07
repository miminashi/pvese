#!/bin/sh
# Simulate the VLAN late_command writes against a temp interfaces file.
# Pre-populates the file with the contents that d-i netcfg would write
# (a static IP block on the physical NIC) — the late_command is supposed
# to overwrite that.
set -eu

OUT="$(dirname "$0")/sim-interfaces"

# Pre-populate with the netcfg-written content that we observed during
# the 2026-05-02 install. This is what we expect the overwrite to clobber.
cat > "$OUT" <<'NETCFG'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug eno1
iface eno1 inet static
        address 10.10.10.210/8
        gateway 10.10.10.1
NETCFG

echo "=== Pre-populated /etc/network/interfaces (netcfg-written) ==="
cat "$OUT"

echo ""
echo "=== Running late_command echo chain (substituted for OUT) ==="

# This is the exact echo chain from the new VLAN late_network, with
# /target/etc/network/interfaces -> $OUT and /target/etc/modules -> /dev/null.
NWFILE="$OUT"
echo 8021q >> /dev/null
echo 'source /etc/network/interfaces.d/*' > "$NWFILE"
echo '' >> "$NWFILE"
echo 'auto lo' >> "$NWFILE"
echo 'iface lo inet loopback' >> "$NWFILE"
echo '' >> "$NWFILE"
echo 'auto eno1' >> "$NWFILE"
echo 'iface eno1 inet manual' >> "$NWFILE"
echo '' >> "$NWFILE"
echo 'auto eno1.1120' >> "$NWFILE"
echo 'iface eno1.1120 inet dhcp' >> "$NWFILE"
echo '    vlan-raw-device eno1' >> "$NWFILE"
echo '' >> "$NWFILE"
echo 'auto eno1.1083' >> "$NWFILE"
echo 'iface eno1.1083 inet static' >> "$NWFILE"
echo '    address 10.10.10.210/8' >> "$NWFILE"
echo '    vlan-raw-device eno1' >> "$NWFILE"

echo ""
echo "=== Final /etc/network/interfaces (after VLAN late_command) ==="
cat "$OUT"

echo ""
echo "=== Sanity checks ==="
if grep -q 'iface eno1 inet static' "$OUT"; then
    echo "FAIL: untagged eno1 still has static IP block (duplicate IP would result)"
    exit 1
fi
if ! grep -q 'iface eno1 inet manual' "$OUT"; then
    echo "FAIL: untagged eno1 not declared inet manual"
    exit 1
fi
if ! grep -q 'iface eno1.1083 inet static' "$OUT"; then
    echo "FAIL: VLAN 1083 static block missing"
    exit 1
fi
if ! grep -q 'address 10.10.10.210/8' "$OUT"; then
    echo "FAIL: static IP 10.10.10.210/8 missing"
    exit 1
fi
if ! grep -q 'iface eno1.1120 inet dhcp' "$OUT"; then
    echo "FAIL: VLAN 1120 dhcp block missing"
    exit 1
fi
if ! grep -q 'iface lo inet loopback' "$OUT"; then
    echo "FAIL: loopback missing"
    exit 1
fi
echo "OK: overwrite produced expected VLAN-only interfaces file"
