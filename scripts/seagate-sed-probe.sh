#!/bin/sh
# Probe Seagate SED Lock state and SCSI vendor pages on a remote pve node.
# Usage: ./scripts/seagate-sed-probe.sh <ssh_host> <device> [output_dir]
#   ssh_host    : SSH alias (e.g. pve10) or root@10.10.10.210
#   device      : block device path on remote (/dev/sdb)
#   output_dir  : local dir to save probe output (default: tmp/<sid>/probe)
#
# Read-only — does not modify drive state.
set -eu

if [ $# -lt 2 ]; then
    echo "Usage: $0 <ssh_host> <device> [output_dir]" >&2
    exit 1
fi

ssh_host=$1
dev=$2
out_dir=${3:-tmp/probe}

mkdir -p "$out_dir"
dev_safe=$(echo "$dev" | tr '/' '_')

remote_script=$(mktemp)
trap 'rm -f "$remote_script"' EXIT

cat > "$remote_script" <<EOF
#!/bin/sh
DEV="$dev"
echo "===== uname / kernel ====="
uname -a
echo
echo "===== sg_inq (standard) ====="
sg_inq "\$DEV" || true
echo
echo "===== sg_inq -p sinq (serial / WWN / firmware) ====="
sg_inq -p 0x80 "\$DEV" || true
sg_inq -p 0x83 "\$DEV" || true
sg_inq -p 0xb0 "\$DEV" || true
sg_inq -p 0xb1 "\$DEV" || true
sg_inq -p 0xb2 "\$DEV" || true
echo
echo "===== sedutil-cli --query (TCG SED state) ====="
sedutil-cli --query "\$DEV" || true
echo
echo "===== sedutil-cli --scan (SED capability summary) ====="
sedutil-cli --scan || true
echo
echo "===== sg_persist --in --read-keys ====="
sg_persist --in --read-keys "\$DEV" || true
echo
echo "===== sg_persist --in --read-reservation ====="
sg_persist --in --read-reservation "\$DEV" || true
echo
echo "===== sg_modes --all (mode pages) ====="
sg_modes --all "\$DEV" || true
echo
echo "===== sg_logs --all (log pages) ====="
sg_logs --all "\$DEV" || true
echo
echo "===== sg_senddiag -l (supported diag pages) ====="
sg_senddiag -l "\$DEV" || true
echo
echo "===== smartctl -a (full SMART) ====="
smartctl -a "\$DEV" || true
echo
echo "===== smartctl -l background (background scan log) ====="
smartctl -l background "\$DEV" || true
echo
echo "===== dmesg | grep sd  (latest 30 lines) ====="
dmesg -T | grep -E "sd[a-z]" | tail -30 || true
EOF

scp -F ssh/config "$remote_script" "$ssh_host":/tmp/sed-probe.sh
ssh -F ssh/config "$ssh_host" sh /tmp/sed-probe.sh > "$out_dir/probe${dev_safe}.txt"

echo "Probe output saved to: $out_dir/probe${dev_safe}.txt"
echo "Size: $(wc -c < "$out_dir/probe${dev_safe}.txt") bytes"
