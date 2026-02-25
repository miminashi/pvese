#!/bin/sh
set -eu

usage() {
    echo "Usage: ib-setup-remote.sh --ip <addr/mask> [--mode connected|datagram] [--mtu <mtu>]"
    echo ""
    echo "Configure IPoIB interface on this host."
    echo ""
    echo "Options:"
    echo "  --ip <addr/mask>       IP address with prefix (e.g. 192.168.100.1/24) (required)"
    echo "  --mode <mode>          IPoIB mode: connected or datagram (default: connected)"
    echo "  --mtu <mtu>            MTU size (default: 65520 for connected, 2044 for datagram)"
    echo "  --persist              Write /etc/network/interfaces.d/ib0 for boot persistence"
    exit 1
}

ip_addr=""
ib_mode="connected"
mtu=""
persist=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ip)      ip_addr="$2"; shift 2 ;;
        --mode)    ib_mode="$2"; shift 2 ;;
        --mtu)     mtu="$2";    shift 2 ;;
        --persist) persist=1;   shift ;;
        *)         echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$ip_addr" ]; then
    echo "ERROR: --ip is required" >&2
    usage
fi

if [ "$ib_mode" != "connected" ] && [ "$ib_mode" != "datagram" ]; then
    echo "ERROR: --mode must be connected or datagram" >&2
    exit 1
fi

if [ -z "$mtu" ]; then
    if [ "$ib_mode" = "connected" ]; then
        mtu=65520
    else
        mtu=2044
    fi
fi

echo "=== IPoIB Setup ==="
echo "IP: $ip_addr"
echo "Mode: $ib_mode"
echo "MTU: $mtu"

echo "--- Detecting IPoIB interface ---"
iface=""
for dev in /sys/class/net/*; do
    name=$(basename "$dev")
    type_file="$dev/type"
    if [ -f "$type_file" ]; then
        devtype=$(cat "$type_file")
        if [ "$devtype" = "32" ]; then
            parent_file="$dev/parent"
            if [ -f "$parent_file" ]; then
                continue
            fi
            mode_file="$dev/mode"
            if [ -f "$mode_file" ]; then
                iface="$name"
                echo "Found IPoIB interface: $iface"
                break
            fi
        fi
    fi
done

if [ -z "$iface" ]; then
    echo "ERROR: No IPoIB interface found" >&2
    exit 1
fi

echo "--- Loading ib_ipoib module ---"
modprobe ib_ipoib

echo "--- Bringing up interface ---"
ip link set "$iface" up

echo "--- Setting mode: $ib_mode ---"
echo "$ib_mode" > "/sys/class/net/$iface/mode"

echo "--- Setting MTU: $mtu ---"
ip link set "$iface" mtu "$mtu"

echo "--- Flushing existing addresses ---"
ip addr flush dev "$iface"

echo "--- Assigning IP: $ip_addr ---"
ip addr add "$ip_addr" dev "$iface"

echo "--- Verifying ---"
ip addr show dev "$iface"
cat "/sys/class/net/$iface/mode"

if [ "$persist" = "1" ]; then
    echo "--- Writing persistent config ---"
    addr_only=$(echo "$ip_addr" | cut -d/ -f1)
    prefix=$(echo "$ip_addr" | cut -d/ -f2)

    cat > /etc/network/interfaces.d/ib0 <<ENDCONF
auto $iface
iface $iface inet static
    address $addr_only/$prefix
    mtu $mtu
    pre-up modprobe ib_ipoib
    pre-up echo $ib_mode > /sys/class/net/$iface/mode || true
ENDCONF

    echo "Written to /etc/network/interfaces.d/ib0"
    cat /etc/network/interfaces.d/ib0
fi

echo "=== IPoIB Setup Complete ==="
