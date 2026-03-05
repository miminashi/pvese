#!/bin/sh
set -eu

usage() {
    echo "Usage: idrac-virtualmedia.sh <command> <bmc_ip> [args...]"
    echo ""
    echo "VirtualMedia Commands:"
    echo "  mount   <bmc_ip> <uri> [smb_user] [smb_pass]   Mount remote ISO via racadm remoteimage"
    echo "  umount  <bmc_ip>                                 Unmount remote ISO"
    echo "  status  <bmc_ip>                                 Show VirtualMedia status"
    echo "  verify  <bmc_ip>                                 Verify ISO is mounted (exit 1 if not)"
    echo ""
    echo "Boot Control Commands:"
    echo "  boot-once  <bmc_ip> <device>   Set one-time boot device (HDD, VCD-DVD, PXE, Normal)"
    echo "  boot-reset <bmc_ip>            Clear boot-once, restore normal boot sequence"
    echo "  boot-status <bmc_ip>           Show current boot settings"
    echo ""
    echo "Boot Devices: Normal, PXE, BIOS, VCD-DVD, Floppy, HDD"
    echo ""
    echo "Requires SSH host 'idrac7' configured in ~/.ssh/config"
    echo "(User claude, IdentityFile ~/.ssh/idrac_rsa, legacy KexAlgorithms)"
    exit 1
}

ssh_idrac() {
    ssh -o ConnectTimeout=10 idrac7 "$@"
}

cmd_mount() {
    bmc_ip="$1"
    uri="$2"
    smb_user="${3:-guest}"
    smb_pass="${4:-guest}"

    ssh_idrac racadm remoteimage -c -u "$smb_user" -p "$smb_pass" -l "$uri"
}

cmd_umount() {
    ssh_idrac racadm remoteimage -d
}

cmd_status() {
    ssh_idrac racadm remoteimage -s
}

cmd_verify() {
    output=$(ssh_idrac racadm remoteimage -s)
    echo "$output"

    case "$output" in
        *"Enabled"*)
            echo "OK: Remote image is connected"
            return 0
            ;;
        *)
            echo "ERROR: Remote image is NOT connected" >&2
            return 1
            ;;
    esac
}

cmd_boot_once() {
    device="$1"
    ssh_idrac racadm set iDRAC.ServerBoot.FirstBootDevice "$device"
    ssh_idrac racadm config -g cfgServerInfo -o cfgServerBootOnce 1
    echo "Boot-once set to: $device"
}

cmd_boot_reset() {
    ssh_idrac racadm config -g cfgServerInfo -o cfgServerBootOnce 0
    ssh_idrac racadm set iDRAC.ServerBoot.FirstBootDevice Normal
    echo "Boot-once cleared. Normal boot sequence restored."
}

cmd_boot_status() {
    echo "=== iDRAC ServerBoot ==="
    ssh_idrac racadm get iDRAC.ServerBoot
    echo ""
    echo "=== BIOS BootSeq ==="
    ssh_idrac racadm get BIOS.BiosBootSettings.BootSeq
    echo ""
    echo "=== BIOS BootMode ==="
    ssh_idrac racadm get BIOS.BiosBootSettings.BootMode
    echo ""
    echo "=== HDD Sequence ==="
    ssh_idrac racadm get BIOS.BiosBootSettings.HddSeq
}

if [ $# -lt 2 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    mount)
        if [ $# -lt 2 ]; then usage; fi
        cmd_mount "$@"
        ;;
    umount)
        cmd_umount
        ;;
    status)
        cmd_status
        ;;
    verify)
        cmd_verify
        ;;
    boot-once)
        if [ $# -lt 2 ]; then usage; fi
        shift
        cmd_boot_once "$@"
        ;;
    boot-reset)
        cmd_boot_reset
        ;;
    boot-status)
        cmd_boot_status
        ;;
    *)
        usage
        ;;
esac
