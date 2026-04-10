#!/bin/sh
set -eu

usage() {
    echo "Usage: pve-setup-remote.sh --phase <phase> [options]"
    echo ""
    echo "Phases:"
    echo "  pre-reboot    /etc/hosts, PVE repo, kernel install, GRUB serial config"
    echo "  post-reboot   proxmox-ve install, Debian kernel removal, locale fix"
    echo ""
    echo "Options:"
    echo "  --hostname <name>       Hostname (required)"
    echo "  --ip <addr>             Static IP for /etc/hosts (required)"
    echo "  --codename <name>       Debian codename, e.g. trixie (required)"
    echo "  --serial-unit <N>       Serial console unit number (default: 1)"
    echo "  --linstor               Install LINBIT repo + DRBD/LINSTOR packages"
    exit 1
}

phase=""
hostname=""
ip=""
codename=""
serial_unit=1
linstor=0

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)       phase="$2";       shift 2 ;;
        --hostname)    hostname="$2";    shift 2 ;;
        --ip)          ip="$2";          shift 2 ;;
        --codename)    codename="$2";    shift 2 ;;
        --serial-unit) serial_unit="$2"; shift 2 ;;
        --linstor)     linstor=1;        shift ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$phase" ] || [ -z "$hostname" ] || [ -z "$ip" ] || [ -z "$codename" ]; then
    echo "ERROR: --phase, --hostname, --ip, --codename are required" >&2
    usage
fi

phase_pre_reboot() {
    echo "=== Phase: pre-reboot ==="

    echo "--- Configuring /etc/hosts ---"
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/${ip} ${hostname}.local ${hostname}/" /etc/hosts
    elif ! grep -q "${ip}" /etc/hosts; then
        echo "${ip} ${hostname}.local ${hostname}" >> /etc/hosts
    fi
    cat /etc/hosts

    echo "--- Disabling cdrom repository ---"
    sed -i '/^deb cdrom:/d' /etc/apt/sources.list

    echo "--- Adding PVE repository ---"
    echo "deb [arch=amd64] http://download.proxmox.com/debian/pve ${codename} pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
    wget -q "https://enterprise.proxmox.com/debian/proxmox-release-${codename}.gpg" -O "/etc/apt/trusted.gpg.d/proxmox-release-${codename}.gpg"
    echo "Repository added"

    echo "--- Updating packages ---"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

    echo "--- Installing PVE kernel ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y install proxmox-default-kernel

    echo "--- Configuring GRUB for serial console (unit=${serial_unit}) ---"
    if ! grep -q 'GRUB_TERMINAL=' /etc/default/grub; then
        printf '\nGRUB_TERMINAL="console serial"\nGRUB_SERIAL_COMMAND="serial --unit=%s --speed=115200 --word=8 --parity=no --stop=1"\n' "$serial_unit" >> /etc/default/grub
    fi
    if ! grep -q 'console=ttyS' /etc/default/grub; then
        sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS${serial_unit},115200n8\"/" /etc/default/grub
    fi
    update-grub

    echo "=== pre-reboot phase complete. Reboot required. ==="
}

phase_post_reboot() {
    echo "=== Phase: post-reboot ==="

    echo "--- Fixing locale ---"
    if ! locale -a 2>/dev/null | grep -q en_US.utf8; then
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        locale-gen
    fi
    printf 'LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n' > /etc/default/locale
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    echo "--- Removing enterprise repositories ---"
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    rm -f /etc/apt/sources.list.d/pve-enterprise.sources

    echo "--- Updating package lists ---"
    apt-get update

    echo "--- Installing proxmox-ve ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y install proxmox-ve postfix open-iscsi chrony

    echo "--- Removing Debian kernel ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y remove linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
    update-grub

    echo "--- Installing durable default-route fix hook ---"
    mkdir -p /etc/network/if-up.d
    cat > /etc/network/if-up.d/z-fix-default-route << 'HOOK_EOF'
#!/bin/sh
# Persistent default route fix for lab environment.
# Management network 10.0.0.0/8 has no internet; 192.168.39.0/24 (DHCP)
# is the only internet-capable path. ifupdown2 sometimes sets default via
# 10.10.10.1 during re-evaluation; this hook reverts on every interface up.
ip route del default via 10.10.10.1 2>/dev/null || true
if ! ip route show default | grep -q 'default'; then
    ip route add default via 192.168.39.1 2>/dev/null || true
fi
HOOK_EOF
    chmod 0755 /etc/network/if-up.d/z-fix-default-route
    /etc/network/if-up.d/z-fix-default-route || true
    echo "Default-route fix hook installed at /etc/network/if-up.d/z-fix-default-route"

    if [ "$linstor" = "1" ]; then
        echo "--- Setting up LINBIT repository ---"
        echo "deb [signed-by=/usr/share/keyrings/linbit-keyring.gpg] http://packages.linbit.com/public/ proxmox-9 drbd-9" > /etc/apt/sources.list.d/linbit.list
        if [ ! -f /usr/share/keyrings/linbit-keyring.gpg ]; then
            echo "Fetching LINBIT GPG key..."
            if ! wget -qO /usr/share/keyrings/linbit-keyring.gpg https://packages.linbit.com/package-signing-pubkey.gpg || [ ! -s /usr/share/keyrings/linbit-keyring.gpg ]; then
                echo "Direct URL failed, trying keyserver..."
                rm -f /usr/share/keyrings/linbit-keyring.gpg
                DEBIAN_FRONTEND=noninteractive apt-get -y install gnupg dirmngr
                gpg --batch --no-default-keyring --keyring /tmp/linbit-tmp.gpg --keyserver keyserver.ubuntu.com --recv-keys 4E5385546726D13CB649872CFC05A31DB826FE48
                gpg --batch --no-default-keyring --keyring /tmp/linbit-tmp.gpg --export 4E5385546726D13CB649872CFC05A31DB826FE48 > /usr/share/keyrings/linbit-keyring.gpg
                rm -f /tmp/linbit-tmp.gpg /tmp/linbit-tmp.gpg~
            fi
            chmod a+r /usr/share/keyrings/linbit-keyring.gpg
        fi
        rm -f /etc/apt/sources.list.d/pve-enterprise.sources
        apt-get update
        pve_kernel=$(uname -r)
        DEBIAN_FRONTEND=noninteractive apt-get -y install gcc "proxmox-headers-${pve_kernel}" drbd-dkms drbd-utils linstor-satellite linstor-client linstor-proxmox
        dkms autoinstall || true
        systemctl enable linstor-satellite
        echo "LINSTOR/DRBD setup complete"
    fi

    echo "=== post-reboot phase complete ==="
    echo "PVE version:"
    pveversion 2>/dev/null || echo "(pveversion not available yet)"
}

case "$phase" in
    pre-reboot)  phase_pre_reboot ;;
    post-reboot) phase_post_reboot ;;
    *)           echo "Unknown phase: $phase" >&2; usage ;;
esac
