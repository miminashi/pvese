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
    exit 1
}

phase=""
hostname=""
ip=""
codename=""
serial_unit=1

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)       phase="$2";       shift 2 ;;
        --hostname)    hostname="$2";    shift 2 ;;
        --ip)          ip="$2";          shift 2 ;;
        --codename)    codename="$2";    shift 2 ;;
        --serial-unit) serial_unit="$2"; shift 2 ;;
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

    echo "--- Installing proxmox-ve ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y install proxmox-ve postfix open-iscsi chrony

    echo "--- Removing Debian kernel ---"
    DEBIAN_FRONTEND=noninteractive apt-get -y remove linux-image-amd64 'linux-image-6.*' 2>/dev/null || true
    update-grub

    echo "=== post-reboot phase complete ==="
    echo "PVE version:"
    pveversion 2>/dev/null || echo "(pveversion not available yet)"
}

case "$phase" in
    pre-reboot)  phase_pre_reboot ;;
    post-reboot) phase_post_reboot ;;
    *)           echo "Unknown phase: $phase" >&2; usage ;;
esac
