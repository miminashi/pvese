#!/bin/sh
# Run TCG SED PSID Revert on a remote drive, then verify write capability.
# Usage: ./scripts/seagate-psid-revert.sh <ssh_host> <device> <psid> [output_dir]
#   ssh_host    : SSH alias (e.g. pve10) or root@10.10.10.210
#   device      : block device path on remote (/dev/sdb)
#   psid        : 32-character PSID from drive label
#   output_dir  : local dir to save logs (default: tmp/revert)
#
# DESTRUCTIVE: erases all data and resets all SPs to factory state.
# Must be wrapped via ./pve-lock.sh and ./oplog.sh per CLAUDE.md rules.
set -eu

if [ $# -lt 3 ]; then
    echo "Usage: $0 <ssh_host> <device> <psid> [output_dir]" >&2
    exit 1
fi

ssh_host=$1
dev=$2
psid=$3
out_dir=${4:-tmp/revert}

if [ ${#psid} -ne 32 ]; then
    echo "ERROR: PSID must be exactly 32 characters, got ${#psid}" >&2
    exit 1
fi

mkdir -p "$out_dir"
dev_safe=$(echo "$dev" | tr '/' '_')
log="$out_dir/revert${dev_safe}.log"

remote_script=$(mktemp)
trap 'rm -f "$remote_script"' EXIT

cat > "$remote_script" <<EOF
#!/bin/sh
DEV="$dev"
PSID="$psid"
echo "===== timestamp ====="
date -u
echo
echo "===== Pre-revert SED state ====="
sedutil-cli --query "\$DEV" || true
echo
echo "===== Pre-revert dd write probe (expected to fail with I/O error) ====="
dd if=/dev/zero of="\$DEV" bs=512 count=1 oflag=direct seek=10000
echo "rc=\$?"
echo
echo "===== sedutil-cli --PSIDrevert ====="
sedutil-cli --yesIreallywanttodothis --PSIDrevert "\$PSID" "\$DEV"
echo "rc=\$?"
echo
echo "===== Post-revert SED state ====="
sedutil-cli --query "\$DEV" || true
echo
echo "===== Post-revert dd write probe (expected to succeed) ====="
sleep 2
dd if=/dev/zero of="\$DEV" bs=512 count=1 oflag=direct seek=10000
echo "rc=\$?"
echo
echo "===== Post-revert dmesg sense codes ====="
dmesg -T | grep -E "sd[a-z]" | tail -20 || true
EOF

scp -F ssh/config "$remote_script" "$ssh_host":/tmp/psid-revert.sh
ssh -F ssh/config "$ssh_host" sh /tmp/psid-revert.sh > "$log" 2>&1 || rc=$?
rc=${rc:-0}

echo "PSID revert log saved to: $log"
echo "Exit code: $rc"
exit $rc
