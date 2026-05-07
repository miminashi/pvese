#!/bin/sh
set -u

echo "===== uname/os ====="
uname -a
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID)='
echo
echo "===== pveversion ====="
pveversion 2>/dev/null || echo "(pveversion not available)"
echo
echo "===== lsblk -o NAME,SIZE,ROTA,MODEL,SERIAL,TRAN,TYPE,MOUNTPOINTS,FSTYPE ====="
lsblk -o NAME,SIZE,ROTA,MODEL,SERIAL,TRAN,TYPE,MOUNTPOINTS,FSTYPE
echo
echo "===== lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL,TRAN,VENDOR,REV ====="
lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL,TRAN,VENDOR,REV
echo
echo "===== df -hT ====="
df -hT --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=overlay
echo
echo "===== pvs / vgs / lvs ====="
pvs 2>/dev/null || echo "(pvs not available)"
echo
vgs 2>/dev/null || echo "(vgs not available)"
echo
lvs 2>/dev/null || echo "(lvs not available)"
echo
echo "===== ZFS pools ====="
zpool list 2>/dev/null || echo "(zpool not available or no pools)"
echo
zfs list 2>/dev/null || echo "(zfs not available or no datasets)"
echo
echo "===== lspci storage ====="
lspci -nn | grep -iE 'sas|raid|sata|nvme|scsi|storage' || echo "(no matches)"
echo
echo "===== smartctl --scan ====="
smartctl --scan 2>/dev/null || echo "(smartctl not available)"
echo
echo "===== /proc/mdstat ====="
cat /proc/mdstat 2>/dev/null || echo "(no mdstat)"
echo
echo "===== mount summary ====="
mount | grep -vE '^(tmpfs|devtmpfs|proc|sysfs|cgroup|securityfs|pstore|debugfs|configfs|tracefs|fusectl|nsfs|bpf|systemd-1|none|mqueue|hugetlbfs|binfmt_misc|ramfs|autofs)' | sort
echo
echo "===== smartctl per-disk (model/serial/size/state) ====="
for dev in $(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    echo "--- /dev/$dev ---"
    smartctl -i "/dev/$dev" 2>/dev/null | grep -E '^(Model Family|Device Model|Vendor|Product|Serial Number|User Capacity|Rotation Rate|Form Factor|SATA Version|SAS|Transport protocol|Logical block size)' || echo "(smartctl info unavailable)"
done
