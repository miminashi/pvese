#!/bin/sh
set -eu

# irmc-ipxe-cd-deploy.sh — Deploy an iPXE-on-CD ISO via iRMC S4 Virtual Media (NFS)
# and boot it, so iPXE does the install (PXE-equivalent) without the OpenWrt TFTP
# dependency. Companion to scripts/build-ipxe-iso.sh and the pxe-deploy skill.
#
# Usage: irmc-ipxe-cd-deploy.sh <config.yml> [iso_basename]
#   Reads bmc_ip / bmc_user / bmc_pass / bmc_curl_opts / nfs_host / nfs_export_path
#   from config. iso_basename defaults to "ipxe-<hostname>.iso".
#
# Sequence (matches the FW 9.69F behaviour established in vmnfs531, 2026-05-31):
#   1. DisconnectCD            (clear any stale handle)
#   2. config CDImage = NFS:<iso>
#   3. FTSManager.VirtualMediaServiceRestart {VirtualMediaType:CD}
#        -> resets the Virtual Media worker so the media is actually presented to
#           the host (without this the iRMC reports IsAnyVirtualMediaActive but
#           /dev/sr0 shows "No medium found" — USB redirector degradation).
#   4. PowerOn                 (ConnectCD requires PowerState=On on FW 9.69F)
#   5. ConnectCD               (attach the NFS CD to the running host USB)
#   6. ForceOff -> poll Off
#   7. boot-override Cd UEFI   (must be set while Off, else it is consumed wrong)
#   8. PowerOn                 -> host boots iPXE from the CD
#
# The ISO must already be present at <nfs_host>:<nfs_export>/<iso_basename>.
# After install completes (auto-poweroff), boot the installed system with:
#   bmc-power.sh boot-override <ip> <u> <p> Hdd UEFI ; bmc-power.sh on ...

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"

CONFIG="${1:?usage: irmc-ipxe-cd-deploy.sh <config.yml> [iso_basename]}"
[ -f "$CONFIG" ] || { echo "ERROR: config not found: $CONFIG" >&2; exit 2; }

HOSTNAME=$("$YQ" '.hostname' "$CONFIG")
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
BMC_USER=$("$YQ" '.bmc_user' "$CONFIG")
BMC_PASS=$("$YQ" '.bmc_pass' "$CONFIG")
BMC_CURL_OPTS_CFG=$("$YQ" '.bmc_curl_opts // "--ciphers DEFAULT@SECLEVEL=0"' "$CONFIG")
NFS_HOST=$("$YQ" '.nfs_host // ""' "$CONFIG")
NFS_EXPORT=$("$YQ" '.nfs_export_path // ""' "$CONFIG")
ISO_BASENAME="${2:-ipxe-${HOSTNAME}.iso}"

[ -n "$NFS_HOST" ] && [ -n "$NFS_EXPORT" ] || { echo "ERROR: nfs_host / nfs_export_path required in $CONFIG" >&2; exit 3; }

# env required by the vendor-agnostic bmc-power.sh for iRMC S4.
export BMC_SCHEME=https
export BMC_CURL_OPTS="$BMC_CURL_OPTS_CFG"
export POWER_ON_RESET_TYPE=On
export BMC_PATCH_REQUIRES_ETAG=1
export BMC_BOOT_OVERRIDE_NO_DISABLED=1

SETTLE_WAIT=${SETTLE_WAIT:-20}

vm_service_restart() {
    # shellcheck disable=SC2086
    curl -sk $BMC_CURL_OPTS -u "$BMC_USER:$BMC_PASS" \
        -H "Content-Type: application/json" \
        -X POST "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.VirtualMediaServiceRestart" \
        -d '{"VirtualMediaType":"CD"}' -w "\n  HTTP %{http_code}\n"
}

# ConnectCD can return HTTP 500 when issued right after a ForceOff (the iRMC CD
# worker is left in an inconsistent state — seen on the #15 escape path where we
# ForceOff and immediately re-deploy, trial 9). The bare "connect-cd || true"
# then silently leaves the CD UNattached while boot-override Cd is still set, so
# the host falls through to the leftover HDD GRUB (which fails because the RAID
# was just cleared) — a silent deploy failure. Retry with a fresh media worker
# (VirtualMediaServiceRestart) until ConnectCD returns 204, then confirm via
# verify (AllowableValues flips to "DisconnectCD" once the CD is attached).
connect_cd_with_retry() {
    _n=0
    while [ "$_n" -lt 4 ]; do
        out=$("${SCRIPT_DIR}/irmc-virtualmedia.sh" connect-cd "$BMC_IP" "$BMC_USER" "$BMC_PASS" 2>&1 || true)
        echo "$out"
        # HTTP 204 = ConnectCD accepted. (Already-attached also returns 204 / the
        # OEM action drops to DisconnectCD-only — treat any non-error 204 as ok.)
        case "$out" in
            *"HTTP 204"*) echo "[ipxe-cd]   ConnectCD ok (204)"; return 0 ;;
        esac
        _n=$((_n + 1))
        echo "[ipxe-cd]   ConnectCD failed (attempt $_n/4, likely HTTP 500 after ForceOff) — VirtualMediaServiceRestart + retry"
        vm_service_restart
        sleep "$SETTLE_WAIT"
    done
    echo "ERROR: ConnectCD did not return 204 after retries — aborting deploy to avoid silent HDD fall-through" >&2
    return 1
}

poll_off() {
    i=0
    while [ "$i" -lt 24 ]; do
        # shellcheck disable=SC2086
        st=$(curl -sk $BMC_CURL_OPTS -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP/redfish/v1/Systems/0" \
            | grep -aoE "\"PowerState\":\"[A-Za-z]+\"" | head -1)
        echo "  power: $st"
        case "$st" in *Off*) return 0 ;; esac
        i=$((i + 1)); sleep 5
    done
    echo "WARN: PowerState did not reach Off within timeout" >&2
}

echo "[ipxe-cd] target: $HOSTNAME @ $BMC_IP, ISO $NFS_HOST:$NFS_EXPORT/$ISO_BASENAME"

echo "[ipxe-cd] 1. DisconnectCD (clear stale handle)"
"${SCRIPT_DIR}/irmc-virtualmedia.sh" disconnect-cd "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true
sleep 5

echo "[ipxe-cd] 2. config CDImage = NFS:$ISO_BASENAME"
"${SCRIPT_DIR}/irmc-virtualmedia.sh" --share-type=NFS config \
    "$BMC_IP" "$BMC_USER" "$BMC_PASS" "$NFS_HOST" "$NFS_EXPORT" "$ISO_BASENAME"

echo "[ipxe-cd] 3. VirtualMediaServiceRestart (fresh media worker)"
vm_service_restart
sleep "$SETTLE_WAIT"

echo "[ipxe-cd] 4. PowerOn (ConnectCD requires PowerState=On)"
"${SCRIPT_DIR}/bmc-power.sh" on "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true
sleep "$SETTLE_WAIT"

echo "[ipxe-cd] 5. ConnectCD (verify + retry on HTTP 500)"
connect_cd_with_retry
sleep 8

echo "[ipxe-cd] 6. ForceOff -> wait Off"
"${SCRIPT_DIR}/bmc-power.sh" forceoff "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true
sleep 5
poll_off

echo "[ipxe-cd] 7. boot-override Cd UEFI (set while Off)"
"${SCRIPT_DIR}/bmc-power.sh" boot-override "$BMC_IP" "$BMC_USER" "$BMC_PASS" Cd UEFI
sleep 10

echo "[ipxe-cd] 8. PowerOn -> host boots iPXE from CD"
"${SCRIPT_DIR}/bmc-power.sh" on "$BMC_IP" "$BMC_USER" "$BMC_PASS"

echo "[ipxe-cd] done. Monitor: .venv/bin/python scripts/sol-monitor.py --bmc-ip $BMC_IP --bmc-user $BMC_USER --bmc-pass <pass> --log-file install.log --timeout 1800"
echo "[ipxe-cd] true progress = playground nginx access.log (preseed/storcli/phonehome GET)"
