#!/bin/sh
set -eu

usage() {
    echo "Usage: pre-pve-setup.sh --dhcp-iface <iface> --static-gw <gw> --codename <codename>"
    echo ""
    echo "Prepare a fresh Debian install for PVE installation (R320 / CD-only preseed)."
    echo "Enables DHCP interface, fixes default route, configures apt, installs prerequisites."
    echo ""
    echo "Options:"
    echo "  --dhcp-iface <iface>  DHCP interface name (e.g. eno2)"
    echo "  --static-gw <gw>     Static gateway to remove (e.g. 10.10.10.1)"
    echo "  --codename <codename> Debian codename (e.g. trixie)"
    exit 1
}

dhcp_iface=""
static_gw=""
codename=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dhcp-iface) dhcp_iface="$2"; shift 2 ;;
        --static-gw)  static_gw="$2";  shift 2 ;;
        --codename)   codename="$2";   shift 2 ;;
        *)            echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$dhcp_iface" ] || [ -z "$static_gw" ] || [ -z "$codename" ]; then
    echo "ERROR: All options are required" >&2
    usage
fi

echo "=== pre-pve-setup: DHCP + apt configuration ==="

echo "--- Step 1: Configure DHCP interface ---"
if grep -q "iface ${dhcp_iface}" /etc/network/interfaces; then
    echo "DHCP interface ${dhcp_iface} already configured"
else
    printf "\nauto %s\niface %s inet dhcp\n" "$dhcp_iface" "$dhcp_iface" >> /etc/network/interfaces
    echo "Added DHCP config for ${dhcp_iface}"
fi

echo "--- Step 2: Bring up DHCP interface ---"
ifup "$dhcp_iface" 2>/dev/null || true

echo "--- Step 3: Wait for DHCP IPv4 ---"
dhcp_wait=0
dhcp_max=30
dhcp_got=""
while [ "$dhcp_wait" -lt "$dhcp_max" ]; do
    addr=$(ip -4 addr show "$dhcp_iface" 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | awk '{print $2}')
    if [ -n "$addr" ]; then
        echo "DHCP IPv4 acquired: ${addr} (${dhcp_wait}s)"
        dhcp_got="yes"
        break
    fi
    sleep 5
    dhcp_wait=$((dhcp_wait + 5))
    echo "Waiting for DHCP... (${dhcp_wait}s/${dhcp_max}s)"
done

if [ -z "$dhcp_got" ]; then
    echo "DHCP timeout, trying dhclient as fallback..."
    dhclient "$dhcp_iface" 2>/dev/null || true
    sleep 5
    addr=$(ip -4 addr show "$dhcp_iface" 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | awk '{print $2}')
    if [ -n "$addr" ]; then
        echo "DHCP IPv4 acquired via dhclient: ${addr}"
    else
        echo "WARNING: Could not acquire DHCP IPv4 on ${dhcp_iface}"
    fi
fi

echo "--- Step 4: Fix default route ---"
if ip route show default | grep -q "via ${static_gw}"; then
    ip route del default via "$static_gw" || true
    echo "Removed default route via ${static_gw}"
else
    echo "No default route via ${static_gw} found"
fi
dhcp_gw=$(ip route show dev "$dhcp_iface" 2>/dev/null | grep -o 'default via [0-9.]*' | awk '{print $3}')
if [ -z "$dhcp_gw" ]; then
    dhcp_gw=$(ip route show dev "$dhcp_iface" 2>/dev/null | grep -o '[0-9.]*/[0-9]*' | head -1 | sed 's|/.*||; s|\.[0-9]*$|.1|')
fi
if [ -n "$dhcp_gw" ]; then
    if ! ip route show default | grep -q 'default'; then
        ip route add default via "$dhcp_gw" dev "$dhcp_iface" || true
        echo "Added default route via ${dhcp_gw} dev ${dhcp_iface}"
    fi
else
    echo "WARNING: Could not determine DHCP gateway"
fi

echo "--- Step 5: Configure apt sources ---"
cat > /etc/apt/sources.list << APTEOF
deb http://deb.debian.org/debian ${codename} main contrib non-free-firmware
deb http://deb.debian.org/debian-security ${codename}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free-firmware
APTEOF
echo "apt sources.list updated for ${codename}"

echo "--- Step 6: apt-get update (with retry) ---"
apt_try=0
apt_max=3
apt_ok=""
while [ "$apt_try" -lt "$apt_max" ]; do
    apt_try=$((apt_try + 1))
    if apt-get update; then
        apt_ok="yes"
        break
    fi
    echo "apt-get update failed (attempt ${apt_try}/${apt_max}), retrying in 5s..."
    sleep 5
done
if [ -z "$apt_ok" ]; then
    echo "ERROR: apt-get update failed after ${apt_max} attempts" >&2
    exit 1
fi

echo "--- Step 7: Install prerequisites ---"
DEBIAN_FRONTEND=noninteractive apt-get -y install wget ca-certificates isc-dhcp-client

echo "=== pre-pve-setup complete ==="
