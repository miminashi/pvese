#!/bin/sh
set -eu

usage() {
    echo "Usage: pve-bridge-setup.sh --static-iface <name> --static-ip <ip/mask> --dhcp-iface <name>"
    echo ""
    echo "Create vmbr0 (static) and vmbr1 (DHCP) bridges for PVE."
    echo "Idempotent: skips if bridges already exist in /etc/network/interfaces."
    echo ""
    echo "Options:"
    echo "  --static-iface <name>   Physical interface for vmbr0 (e.g. eno1, eno2np1)"
    echo "  --static-ip <ip/mask>   Static IP with prefix length (e.g. 10.10.10.207/8)"
    echo "  --dhcp-iface <name>     Physical interface for vmbr1 (e.g. eno2, eno1np0)"
    exit 1
}

static_iface=""
static_ip=""
dhcp_iface=""

while [ $# -gt 0 ]; do
    case "$1" in
        --static-iface) static_iface="$2"; shift 2 ;;
        --static-ip)    static_ip="$2";    shift 2 ;;
        --dhcp-iface)   dhcp_iface="$2";   shift 2 ;;
        *)              echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$static_iface" ] || [ -z "$static_ip" ] || [ -z "$dhcp_iface" ]; then
    echo "ERROR: --static-iface, --static-ip, --dhcp-iface are required" >&2
    usage
fi

if grep -q 'auto vmbr0' /etc/network/interfaces && grep -q 'auto vmbr1' /etc/network/interfaces; then
    echo "=== Bridges already configured, skipping ==="
    ip -brief link show type bridge
    ip -brief addr show vmbr0
    ip -brief addr show vmbr1
    exit 0
fi

echo "=== Backing up /etc/network/interfaces ==="
cp /etc/network/interfaces /etc/network/interfaces.bak

echo "=== Writing bridge configuration ==="
cat > /etc/network/interfaces <<IFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface ${static_iface} inet manual

iface ${dhcp_iface} inet manual

auto vmbr0
iface vmbr0 inet static
	address ${static_ip}
	bridge-ports ${static_iface}
	bridge-stp off
	bridge-fd 0

auto vmbr1
iface vmbr1 inet dhcp
	bridge-ports ${dhcp_iface}
	bridge-stp off
	bridge-fd 0
IFACES

echo "=== New interfaces config ==="
cat /etc/network/interfaces

echo "=== Applying ==="
ifreload -a

echo "=== Bridge status ==="
ip -brief link show type bridge
ip -brief addr show vmbr0
ip -brief addr show vmbr1
