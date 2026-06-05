#!/bin/sh
set -eu

# tx1320-pve-setup.sh — Post-install PVE bring-up wrapper for training-tx1320.
#
# Debian install (iPXE-CD + storcli RAID10) leaves a base Debian 13 system that
# auto-poweroffs, then disk-boots and is reachable over SSH on its eno2 dark-net
# DHCP lease. This wrapper turns the manual os-setup "Phase 7" into one command:
#
#   1. pve-setup-remote.sh --phase pre-reboot   (PVE repo + PVE kernel + GRUB serial)
#   2. reboot -> wait SSH                        (boot into PVE kernel)
#   3. pve-setup-remote.sh --phase post-reboot   (install proxmox-ve, drop Debian kernel)
#   4. reboot -> wait SSH                         (boot clean PVE)
#   5. verify (pveversion / pveproxy / :8006 / RAID10)
#
# The eno2 lease can change across reboots (memory #12), so wait_ssh re-discovers
# the target IP via the neighbour table (eno2 MAC) when the known IP stops
# answering.
#
# Usage: tx1320-pve-setup.sh <config.yml> <target_ip>
#   Reads hostname / serial_unit / in_linstor / eno2_mac from config.
#   CODENAME env overrides the auto-detected Debian codename (default: trixie).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"
SSH_CONFIG="${PROJECT_DIR}/ssh/config"

CONFIG="${1:?usage: tx1320-pve-setup.sh <config.yml> <target_ip>}"
TARGET_IP="${2:?usage: tx1320-pve-setup.sh <config.yml> <target_ip>}"
[ -f "$CONFIG" ] || { echo "ERROR: config not found: $CONFIG" >&2; exit 2; }

HOSTNAME=$("$YQ" '.hostname' "$CONFIG")
SERIAL_UNIT=$("$YQ" '.serial_unit // 0' "$CONFIG")
[ "$SERIAL_UNIT" = "null" ] && SERIAL_UNIT=0
IN_LINSTOR=$("$YQ" '.in_linstor // false' "$CONFIG")
ENO2_MAC=$("$YQ" '.eno2_mac // ""' "$CONFIG")
[ "$ENO2_MAC" = "null" ] && ENO2_MAC=""

# The eno2 dark-net DHCP pool reuses IPs across reinstalls, so a previously
# learned host key for the same IP belongs to a now-wiped system. With only
# StrictHostKeyChecking=no, ssh still REFUSES the connection on a key MISMATCH
# ("REMOTE HOST IDENTIFICATION HAS CHANGED"). UserKnownHostsFile=/dev/null makes
# ssh ignore/forget host keys entirely, which is correct for these throwaway
# dark-net leases (trial 2 hit this: setup stalled until a manual ssh-keygen -R).
SSH_OPTS="-F $SSH_CONFIG -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# shellcheck disable=SC2086
ssh_t() { ssh $SSH_OPTS "root@${TARGET_IP}" "$@"; }

# Re-discover the eno2 dark-net lease by MAC. The kernel neighbour table only
# holds entries learned from recent traffic, so a /24 ping sweep is required to
# (re)populate it before grepping — without the sweep `ip neigh` is stale/empty
# after a reboot and the MAC is not found.
discover_by_mac() {
    [ -n "$ENO2_MAC" ] || return 1
    _j=1
    while [ "$_j" -lt 255 ]; do
        ping -c1 -W1 "10.254.254.${_j}" >/dev/null 2>&1 &
        _j=$((_j + 1))
    done
    wait
    ip neigh | grep -i "$ENO2_MAC" | awk '{print $1}' | grep -E '^10\.254\.254\.' | head -1
}

# Wait for SSH. The eno2 DHCP lease changes across reboots (memory #12), and the
# new lease appears on a DIFFERENT IP while the old one stops answering. Rather
# than block the full timeout on the dead old IP and only THEN re-discover (which
# wasted ~420s per IP-changing reboot, trial 5), interleave both each cycle: try
# the current TARGET_IP, and also re-discover by eno2 MAC. Whichever answers SSH
# first wins. Converges in ~boot-time regardless of whether the IP changed.
wait_ssh() {
    _timeout="${1:-420}"
    _cycles=$(( _timeout / 15 ))
    [ "$_cycles" -lt 1 ] && _cycles=1
    _c=0
    while [ "$_c" -lt "$_cycles" ]; do
        # (1) current known IP
        if ssh $SSH_OPTS -o BatchMode=yes "root@${TARGET_IP}" true 2>/dev/null; then
            return 0
        fi
        # (2) MAC re-discovery (ping-sweep populates neigh first)
        _new_ip=$(discover_by_mac || true)
        if [ -n "$_new_ip" ] && [ "$_new_ip" != "$TARGET_IP" ] && \
           ssh $SSH_OPTS -o BatchMode=yes "root@${_new_ip}" true 2>/dev/null; then
            echo "[pve-setup] eno2 lease changed: $TARGET_IP -> $_new_ip"
            TARGET_IP="$_new_ip"
            echo "[pve-setup] reconnected on $TARGET_IP"
            return 0
        fi
        _c=$(( _c + 1 ))
        echo "[pve-setup] wait_ssh cycle $_c/$_cycles: $TARGET_IP not ready (disc=${_new_ip:-none}), retry in 15s"
        sleep 15
    done
    echo "ERROR: target not reachable and MAC-based re-discovery failed" >&2
    return 1
}

push_setup() {
    # shellcheck disable=SC2086
    scp $SSH_OPTS "${SCRIPT_DIR}/pve-setup-remote.sh" "root@${TARGET_IP}:/tmp/pve-setup-remote.sh"
}

echo "[pve-setup] target=$HOSTNAME @ $TARGET_IP, serial_unit=$SERIAL_UNIT, in_linstor=$IN_LINSTOR"

echo "[pve-setup] 0. wait for initial SSH"
wait_ssh 420

# Detect Debian codename from the running target (fallback: trixie / Debian 13).
CODENAME="${CODENAME:-}"
if [ -z "$CODENAME" ]; then
    CODENAME=$(ssh_t cat /etc/os-release 2>/dev/null | sed -n 's/^VERSION_CODENAME=//p' | head -1 || true)
fi
[ -z "$CODENAME" ] && CODENAME=trixie
echo "[pve-setup] codename=$CODENAME"

# Use the ACTUAL running hostname for /etc/hosts, not the config value. PVE
# resolves its own `hostname` to a non-loopback IP via /etc/hosts; if they
# disagree (the installer set hostname=tx1320 while config says
# training-tx1320), pve-cluster fails to start. Query the live hostname.
REMOTE_HOSTNAME=$(ssh_t hostname 2>/dev/null | tr -d '[:space:]' || true)
[ -z "$REMOTE_HOSTNAME" ] && REMOTE_HOSTNAME="$HOSTNAME"
if [ "$REMOTE_HOSTNAME" != "$HOSTNAME" ]; then
    echo "[pve-setup] NOTE: live hostname '$REMOTE_HOSTNAME' != config '$HOSTNAME' — using live hostname for /etc/hosts"
fi
HOSTNAME="$REMOTE_HOSTNAME"
echo "[pve-setup] hostname=$HOSTNAME"

echo "[pve-setup] route before pre-reboot:"
ssh_t ip route show default || true

echo "[pve-setup] 1. pve-setup-remote.sh --phase pre-reboot"
push_setup
ssh_t "sh /tmp/pve-setup-remote.sh --phase pre-reboot --hostname $HOSTNAME --ip $TARGET_IP --codename $CODENAME --serial-unit $SERIAL_UNIT"

echo "[pve-setup] 2. reboot into PVE kernel"
ssh_t reboot || true
sleep 20
wait_ssh 420

echo "[pve-setup] route after first reboot (must reach internet for apt):"
ssh_t ip route show default || true

echo "[pve-setup] 3. pve-setup-remote.sh --phase post-reboot"
push_setup
LINSTOR_FLAG=""
[ "$IN_LINSTOR" = "true" ] && LINSTOR_FLAG="--linstor"
ssh_t "sh /tmp/pve-setup-remote.sh --phase post-reboot --hostname $HOSTNAME --ip $TARGET_IP --codename $CODENAME --serial-unit $SERIAL_UNIT $LINSTOR_FLAG"

echo "[pve-setup] 4. reboot into clean PVE"
ssh_t reboot || true
sleep 20
wait_ssh 420

echo "[pve-setup] 5. verify"
echo "--- pveversion ---"
ssh_t pveversion || echo "WARN: pveversion failed"
echo "--- pve services ---"
ssh_t systemctl is-active pveproxy pvedaemon pve-cluster || true
echo "--- block devices ---"
ssh_t lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT || true
echo "--- storcli RAID state ---"
# storcli64 is not part of the base install; fetch it from the playground over
# the dark-net (same source the installer used) so the RAID10 "Optimal" state is
# read directly here instead of being skipped (trial 1/2 needed a separate
# verify-raid.sh). Override the URL with STORCLI_URL if the playground differs.
STORCLI_URL="${STORCLI_URL:-http://10.1.6.6/firmware/storcli64.bin}"
ssh_t "test -x /usr/local/bin/storcli64 || (wget -q -O /usr/local/bin/storcli64 $STORCLI_URL && chmod +x /usr/local/bin/storcli64); /usr/local/bin/storcli64 /c0/vall show" 2>/dev/null || echo "(storcli unavailable — RAID check skipped)"
echo "--- PVE web UI ---"
curl -sk --max-time 15 "https://${TARGET_IP}:8006" -o /dev/null -w "PVE web UI HTTP %{http_code}\n" || echo "WARN: web UI probe failed"

echo "[pve-setup] DONE. Final reachable IP: $TARGET_IP"
