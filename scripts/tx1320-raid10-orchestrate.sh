#!/bin/sh
set -eu

# tx1320-raid10-orchestrate.sh — End-to-end TX1320 RAID10 + OS install driver.
#
# Bundles the steps that proved out in 2026-05-17 d-eager-island into a single
# script that:
#   1. Fetches storcli64.deb (Phase 1, idempotent — skipped if file exists)
#   2. Generates preseed.cfg with --with-raid10-storcli (Phase 3)
#   3. Remasters the Debian netinst ISO with storcli64.deb +
#      setup-raid10-storcli.sh + preseed.cfg bundled (Phase 4)
#   4. Configures iRMC Virtual Media (SMB CDImage)
#   5. Sets boot-override Cd UEFI + power cycle
#   6. (optional) Runs sol-monitor.py to track installer progress
#
# Verification (SSH + storcli + lsblk) is left to the caller — DHCP IP must be
# discovered first (SOL log → `Configuring DHCP networking` line, or arp).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"

usage() {
    cat <<EOF
Usage: tx1320-raid10-orchestrate.sh <command> [args]

Commands:
  build    <config.yml> [output_iso_path]
      Phase 1-3: fetch storcli, generate preseed, remaster ISO.
      Default output: /var/samba/public/debian-<hostname>-raid10.iso

  deploy   <config.yml> [output_iso_path]
      Phase 4-5: configure Virtual Media, boot-override Cd UEFI, power cycle.
      The ISO must already be present at output path (use 'build' first or
      together via 'apply').

  monitor  <config.yml> [--timeout N] [--log PATH]
      Phase 6: passive SOL monitor (calls sol-monitor.py).

  apply    <config.yml> [output_iso_path]
      build + deploy.

Env:
  STORCLI_DEB_PATH   Where to write/find storcli64.deb (default /var/samba/public/storcli64.deb)
  SKIP_STORCLI_FETCH 1 = use existing storcli64.deb without re-downloading
EOF
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

CMD="$1"
CONFIG="$2"
OUTPUT_ISO="${3:-}"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: config not found: $CONFIG" >&2
    exit 2
fi

HOSTNAME=$("$YQ" '.hostname' "$CONFIG")
BMC_IP=$("$YQ" '.bmc_ip' "$CONFIG")
BMC_USER=$("$YQ" '.bmc_user' "$CONFIG")
BMC_PASS=$("$YQ" '.bmc_pass' "$CONFIG")
BMC_CURL_OPTS_CFG=$("$YQ" '.bmc_curl_opts' "$CONFIG")
VM_TYPE_CFG=$("$YQ" '.virtual_media_type // "smb"' "$CONFIG")
NFS_HOST=$("$YQ" '.nfs_host // ""' "$CONFIG")
NFS_EXPORT=$("$YQ" '.nfs_export_path // ""' "$CONFIG")
SMB_HOST=$("$YQ" '.smb_host' "$CONFIG")
SMB_SHARE=$("$YQ" '.smb_share_path' "$CONFIG")
SMB_USER=$("$YQ" '.smb_user // "guest"' "$CONFIG")
SMB_PASS=$("$YQ" '.smb_pass // "guest"' "$CONFIG")
SERIAL_UNIT=$("$YQ" '.serial_unit' "$CONFIG")
[ "$SERIAL_UNIT" = "null" ] && SERIAL_UNIT=1

case "$SMB_SHARE" in
    /*) SMB_SHARE_BARE="${SMB_SHARE#/}" ;;
    \\*) SMB_SHARE_BARE="${SMB_SHARE#\\}" ;;
    *) SMB_SHARE_BARE="$SMB_SHARE" ;;
esac

OUTPUT_BASENAME="debian-${HOSTNAME}-raid10.iso"
if [ -z "$OUTPUT_ISO" ]; then
    OUTPUT_ISO="/var/samba/public/${OUTPUT_BASENAME}"
fi
OUTPUT_BASENAME=$(basename "$OUTPUT_ISO")

STORCLI_DEB_PATH=${STORCLI_DEB_PATH:-/var/samba/public/storcli64.deb}
# Phase 14: pre-extracted bare binary (no dpkg dependency in d-i busybox).
STORCLI_BIN_PATH=${STORCLI_BIN_PATH:-/var/samba/public/storcli64.bin}
SKIP_STORCLI_FETCH=${SKIP_STORCLI_FETCH:-0}

export BMC_CURL_OPTS="$BMC_CURL_OPTS_CFG"
export BMC_PATCH_REQUIRES_ETAG=1
export POWER_ON_RESET_TYPE=On

PRESEED_OUT="${PROJECT_DIR}/tmp/${HOSTNAME}-preseed-raid10.cfg"

build() {
    if [ "$SKIP_STORCLI_FETCH" != "1" ] && [ ! -f "$STORCLI_DEB_PATH" ]; then
        echo "[orchestrate] Phase 1: fetch storcli64.deb -> $STORCLI_DEB_PATH"
        "${SCRIPT_DIR}/fetch-storcli-deb.sh" "$STORCLI_DEB_PATH"
    else
        echo "[orchestrate] Phase 1: storcli64.deb present ($STORCLI_DEB_PATH, $(stat -c%s "$STORCLI_DEB_PATH") bytes)"
    fi

    # Phase 2.5: extract storcli64 binary from the .deb on the build host where
    # dpkg-deb is available. d-i busybox initramfs lacks dpkg/dpkg-deb, so the
    # original `sh setup-raid10-storcli.sh /cdrom/storcli64.deb` path exited
    # with rc=127 ("command not found") in partman/early_command — discovered
    # in Phase 13 silly-rocket. Bundling the bare binary into the ISO avoids
    # any package tooling at install time.
    if [ ! -f "$STORCLI_BIN_PATH" ] || [ "$STORCLI_DEB_PATH" -nt "$STORCLI_BIN_PATH" ]; then
        echo "[orchestrate] Phase 2.5: extract storcli64 binary -> $STORCLI_BIN_PATH"
        TMPEXTRACT=$(mktemp -d "${TMPDIR:-/tmp}/storcli-extract.XXXXXX")
        dpkg-deb -x "$STORCLI_DEB_PATH" "$TMPEXTRACT"
        SRC_BIN="$TMPEXTRACT/opt/MegaRAID/storcli/storcli64"
        if [ ! -f "$SRC_BIN" ]; then
            echo "ERROR: storcli64 binary not found in $STORCLI_DEB_PATH" >&2
            rm -rf "$TMPEXTRACT"
            exit 5
        fi
        cp "$SRC_BIN" "$STORCLI_BIN_PATH"
        chmod +x "$STORCLI_BIN_PATH"
        rm -rf "$TMPEXTRACT"
        echo "[orchestrate] Phase 2.5: storcli64 binary ready ($(stat -c%s "$STORCLI_BIN_PATH") bytes)"
    else
        echo "[orchestrate] Phase 2.5: storcli64 binary present ($STORCLI_BIN_PATH, $(stat -c%s "$STORCLI_BIN_PATH") bytes)"
    fi

    echo "[orchestrate] Phase 3: generate preseed -> $PRESEED_OUT"
    mkdir -p "$(dirname "$PRESEED_OUT")"
    "${SCRIPT_DIR}/generate-preseed.sh" --with-raid10-storcli "$CONFIG" "$PRESEED_OUT"

    # Phase 15: pvese-patch v1 — patch cdrom-detect.postinst so it tries
    # /dev/sr1 (iRMC OEM Virtual CDROM) before falling through to the empty
    # /dev/sr0 (physical DVD drive). Without this, d-i blocks on the "No
    # installation media was detected" dialog because list-devices does not
    # return /dev/sr1 as a CD device on this hardware. See
    # report/2026-05-22_154033_tx1320_raid10_phase14_install_completed.md.
    export PVESE_PATCH_CDROM_DETECT=1
    echo "[orchestrate] Phase 4: remaster ISO -> $OUTPUT_ISO (PVESE_PATCH_CDROM_DETECT=$PVESE_PATCH_CDROM_DETECT)"
    "${SCRIPT_DIR}/remaster-debian-iso.sh" \
        --serial-unit="$SERIAL_UNIT" \
        --include="$STORCLI_DEB_PATH" \
        --include="$STORCLI_BIN_PATH" \
        --include="${SCRIPT_DIR}/setup-raid10-storcli.sh" \
        /var/samba/public/debian-13.3.0-amd64-netinst.iso \
        "$PRESEED_OUT" \
        "$OUTPUT_ISO"
    echo "[orchestrate] build OK (local): $OUTPUT_ISO"

    # Phase 4.5: sync ISO to NFS host (= playground for training-tx1320).
    # iRMC reads the ISO from NFS_HOST:NFS_EXPORT, not from local path. Without
    # this sync, Phase 3-12-era cmdline patch attempts silently boot the stale
    # ISO on playground (real failure mode discovered in Phase 13 silly-rocket).
    # Skipped when virtual_media_type != "nfs" or NFS_HOST is local.
    if [ "$VM_TYPE_CFG" = "nfs" ] && [ -n "$NFS_HOST" ] && [ -n "$NFS_EXPORT" ]; then
        case "$NFS_HOST" in
            127.0.0.1|localhost|"")
                echo "[orchestrate] Phase 4.5: NFS_HOST is local, skip sync"
                ;;
            *)
                echo "[orchestrate] Phase 4.5: sync ISO to ${NFS_HOST}:${NFS_EXPORT}/${OUTPUT_BASENAME}"
                SSH_OPTS="-F ${PROJECT_DIR}/ssh/config -o StrictHostKeyChecking=accept-new"
                # Stage to /tmp first to avoid partial-write on the NFS export.
                # shellcheck disable=SC2086
                scp $SSH_OPTS "$OUTPUT_ISO" "ubuntu@${NFS_HOST}:/tmp/${OUTPUT_BASENAME}"
                # shellcheck disable=SC2086
                ssh $SSH_OPTS "ubuntu@${NFS_HOST}" "sudo mv /tmp/${OUTPUT_BASENAME} ${NFS_EXPORT}/${OUTPUT_BASENAME} && sudo chmod 0644 ${NFS_EXPORT}/${OUTPUT_BASENAME}"
                echo "[orchestrate] Phase 4.5: sync OK"
                ;;
        esac
    fi
}

deploy() {
    if [ ! -f "$OUTPUT_ISO" ]; then
        echo "ERROR: ISO not found: $OUTPUT_ISO (run 'build' first)" >&2
        exit 3
    fi

    if [ "$VM_TYPE_CFG" = "nfs" ]; then
        if [ -z "$NFS_HOST" ] || [ -z "$NFS_EXPORT" ]; then
            echo "ERROR: virtual_media_type=nfs requires nfs_host and nfs_export_path in $CONFIG" >&2
            exit 4
        fi
        echo "[orchestrate] Phase 5a: configure Virtual Media (NFS ${NFS_HOST}:${NFS_EXPORT})"
        "${SCRIPT_DIR}/irmc-virtualmedia.sh" --share-type=NFS config \
            "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
            "$NFS_HOST" "$NFS_EXPORT" "$OUTPUT_BASENAME"
        echo "[orchestrate] Phase 5a: ConnectCD (NFS is not AutoAttached)"
        "${SCRIPT_DIR}/irmc-virtualmedia.sh" connect-cd "$BMC_IP" "$BMC_USER" "$BMC_PASS"
        echo "[orchestrate] Phase 5a: wait for AllowableValues=DisconnectCD"
        "${SCRIPT_DIR}/irmc-virtualmedia.sh" --share-type=NFS mount "$BMC_IP" "$BMC_USER" "$BMC_PASS"
    else
        echo "[orchestrate] Phase 5a: configure Virtual Media (smb_user=$SMB_USER)"
        "${SCRIPT_DIR}/irmc-virtualmedia.sh" config "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
            "$SMB_HOST" "$SMB_SHARE_BARE" "$OUTPUT_BASENAME" "$SMB_USER" "$SMB_PASS"
    fi

    echo "[orchestrate] Phase 5b: boot-override Cd UEFI"
    BMC_BOOT_OVERRIDE_NO_DISABLED=1 \
        "${SCRIPT_DIR}/bmc-power.sh" boot-override "$BMC_IP" "$BMC_USER" "$BMC_PASS" Cd UEFI

    echo "[orchestrate] Phase 5c: power cycle (ForceOff + On)"
    "${SCRIPT_DIR}/bmc-power.sh" forceoff "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true
    sleep 8
    "${SCRIPT_DIR}/bmc-power.sh" on "$BMC_IP" "$BMC_USER" "$BMC_PASS"

    echo "[orchestrate] deploy OK — host is booting from CD UEFI"
    echo "[orchestrate] Monitor progress with: $0 monitor $CONFIG"
}

monitor() {
    LOG_PATH="${PROJECT_DIR}/tmp/${HOSTNAME}-sol.log"
    TIMEOUT=2700
    shift 2 || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) TIMEOUT="$2"; shift 2 ;;
            --log) LOG_PATH="$2"; shift 2 ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
    done

    ipmitool -I lanplus -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" sol payload enable 2 4 >/dev/null 2>&1 || true

    echo "[orchestrate] Phase 6: SOL monitor (timeout=${TIMEOUT}s, log=$LOG_PATH)"
    .venv/bin/python "${SCRIPT_DIR}/sol-monitor.py" \
        --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
        --log-file "$LOG_PATH" --timeout "$TIMEOUT" --powerstate-interval 30
}

case "$CMD" in
    build) build ;;
    deploy) deploy ;;
    monitor) monitor "$@" ;;
    apply) build; deploy ;;
    *) usage ;;
esac
