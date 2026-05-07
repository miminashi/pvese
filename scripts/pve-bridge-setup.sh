#!/bin/sh
set -eu

usage() {
    echo "Usage:"
    echo "  Legacy (non-VLAN):"
    echo "    pve-bridge-setup.sh --static-iface <name> --static-ip <ip/mask> --dhcp-iface <name>"
    echo ""
    echo "  VLAN trunk (10号機 etc.):"
    echo "    pve-bridge-setup.sh --vlan-iface <phy> --internet-vlan-id <N> --internal-vlan-id <N> \\"
    echo "        --static-ip <ip/mask>"
    echo ""
    echo "Create vmbr0 (static) and vmbr1 (DHCP) bridges for PVE."
    echo "Idempotent: skips if both bridges already exist in /etc/network/interfaces."
    echo ""
    echo "Legacy mode binds physical NICs directly to the bridges."
    echo "VLAN mode binds <phy>.<internal_vlan> to vmbr0 and <phy>.<internet_vlan> to vmbr1,"
    echo "and persists the 8021q kernel module via /etc/modules."
    exit 1
}

static_iface=""
static_ip=""
dhcp_iface=""
vlan_iface=""
internet_vlan_id=""
internal_vlan_id=""

while [ $# -gt 0 ]; do
    case "$1" in
        --static-iface)      static_iface="$2";      shift 2 ;;
        --static-ip)         static_ip="$2";         shift 2 ;;
        --dhcp-iface)        dhcp_iface="$2";        shift 2 ;;
        --vlan-iface)        vlan_iface="$2";        shift 2 ;;
        --internet-vlan-id)  internet_vlan_id="$2";  shift 2 ;;
        --internal-vlan-id)  internal_vlan_id="$2";  shift 2 ;;
        *)                   echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$static_ip" ]; then
    echo "ERROR: --static-ip is required" >&2
    usage
fi

vlan_mode=false
if [ -n "$vlan_iface" ] || [ -n "$internet_vlan_id" ] || [ -n "$internal_vlan_id" ]; then
    if [ -z "$vlan_iface" ] || [ -z "$internet_vlan_id" ] || [ -z "$internal_vlan_id" ]; then
        echo "ERROR: VLAN mode requires --vlan-iface, --internet-vlan-id, --internal-vlan-id together" >&2
        usage
    fi
    vlan_mode=true
fi

if [ "$vlan_mode" = false ]; then
    if [ -z "$static_iface" ] || [ -z "$dhcp_iface" ]; then
        echo "ERROR: legacy mode requires --static-iface and --dhcp-iface" >&2
        usage
    fi
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

if [ "$vlan_mode" = true ]; then
    echo "=== Persisting 8021q module ==="
    if [ -f /etc/modules ] && grep -qE '^8021q$' /etc/modules; then
        echo "8021q already in /etc/modules"
    else
        echo "8021q" >> /etc/modules
        echo "Added 8021q to /etc/modules"
    fi
    modprobe 8021q || true

    echo "=== Writing VLAN-aware bridge configuration ==="
    cat > /etc/network/interfaces <<IFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${vlan_iface}
iface ${vlan_iface} inet manual

auto ${vlan_iface}.${internal_vlan_id}
iface ${vlan_iface}.${internal_vlan_id} inet manual
	vlan-raw-device ${vlan_iface}

auto ${vlan_iface}.${internet_vlan_id}
iface ${vlan_iface}.${internet_vlan_id} inet manual
	vlan-raw-device ${vlan_iface}

auto vmbr0
iface vmbr0 inet static
	address ${static_ip}
	bridge-ports ${vlan_iface}.${internal_vlan_id}
	bridge-stp off
	bridge-fd 0

auto vmbr1
iface vmbr1 inet dhcp
	bridge-ports ${vlan_iface}.${internet_vlan_id}
	bridge-stp off
	bridge-fd 0
IFACES
else
    echo "=== Writing legacy bridge configuration ==="
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
fi

echo "=== New interfaces config ==="
cat /etc/network/interfaces

echo "=== Applying ==="
ifreload -a

echo "=== Bridge status ==="
ip -brief link show type bridge
ip -brief addr show vmbr0
ip -brief addr show vmbr1
