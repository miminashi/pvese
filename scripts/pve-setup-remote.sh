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
    exit 1
}

phase=""
hostname=""
ip=""
codename=""

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)    phase="$2";    shift 2 ;;
        --hostname) hostname="$2"; shift 2 ;;
        --ip)       ip="$2";      shift 2 ;;
        --codename) codename="$2"; shift 2 ;;
        *)          echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$phase" ] || [ -z "$hostname" ] || [ -z "$ip" ] || [ -z "$codename" ]; then
    echo "ERROR: All options are required" >&2
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

    echo "--- Configuring GRUB for serial console ---"
    if ! grep -q 'GRUB_TERMINAL=' /etc/default/grub; then
        cat >> /etc/default/grub << 'GRUBCONF'
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=1 --speed=115200 --word=8 --parity=no --stop=1"
GRUBCONF
    fi
    if ! grep -q 'console=ttyS1' /etc/default/grub; then
        sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS1,115200n8"/' /etc/default/grub
    fi
    update-grub

    echo "=== pre-reboot phase complete. Reboot required. ==="
}

phase_post_reboot() {
    echo "=== Phase: post-reboot ==="

    echo "--- Installing proxmox-ve ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y install proxmox-ve postfix open-iscsi chrony

    echo "--- Removing Debian kernel ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y remove linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
    update-grub

    echo "--- Fixing locale ---"
    if ! locale -a 2>/dev/null | grep -q en_US.utf8; then
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        locale-gen
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
