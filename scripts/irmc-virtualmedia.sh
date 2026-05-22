#!/bin/sh
set -eu

# Fujitsu iRMC S4 Virtual Media operations via Redfish OEM (ts_fujitsu).
# Endpoint: /redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia
# - HTTPS + Basic Auth + --ciphers DEFAULT@SECLEVEL=0 (legacy DH keys)
# - Share types: SMB (default, AutoAttach) or NFS (requires explicit ConnectCD).
# - SMB: PATCH writes the SMB credentials; iRMC auto-attaches on
#   RemoteMountEnabled=true + UsbAttachMode=AutoAttach.
# - NFS: PATCH writes the export path (UserName/Password ignored). NFS is NOT
#   AutoAttached; caller must POST OEM Action ConnectCD afterwards.
#   See report/2026-05-21_081642_tx1320_raid10_nfs_attempt.md.

usage() {
    cat <<EOF
Usage: irmc-virtualmedia.sh [--type=CD|HD|FD] [--share-type=SMB|NFS] <command> <bmc_ip> <bmc_user> <bmc_pass> [args...]

Options:
  --type=CD|HD|FD       Virtual media slot to operate on (default: CD).
                        HD = HDImage (USB Mass Storage), FD = FDImage (USB Floppy).
                        Note: iRMC S4 with KVM+MEDIA license typically only allows
                        CD (MaximumNumberOfDevices=2); HD/FD report 0 slots and
                        PATCH may be silently rejected.
  --share-type=SMB|NFS  Remote share protocol (default: SMB).
                        SMB: traditional Fujitsu OEM share, AutoAttach enabled.
                        NFS: NFSv4 export (iRMC S4 FW 9.08F supports NFS even
                        when SMB worker is dead). NOT AutoAttached — caller must
                        invoke "connect-cd" after "config".

Commands:
  status  <bmc_ip> <bmc_user> <bmc_pass>
      Show <Type>Image configuration (Server / ShareName / ImageName) and
      RemoteMountEnabled.

  config  <bmc_ip> <bmc_user> <bmc_pass> <host> <share> <image_name> [user] [pass]
      PATCH the <Type>Image entry.
      SMB: ShareName is the share *name* without backslashes (e.g. "public" —
           NOT "\\\\public"). Empty user/pass = guest.
      NFS: <share> is the NFS export path (e.g. "/var/samba/public"). user/pass
           arguments are ignored (NFS uses IP-based authorization).
      SMB iRMC auto-attaches once credentials are valid (UsbAttachMode=AutoAttach).
      NFS requires a separate "connect-cd" call afterwards.

  connect-cd  <bmc_ip> <bmc_user> <bmc_pass>
      POST OEM Action FTSComputerSystem.VirtualMedia { VirtualMediaAction:
      "ConnectCD" }. Required for NFS (which has no AutoAttach). HTTP 204
      indicates the action was accepted; verify with "mount" or "status".

  disconnect-cd  <bmc_ip> <bmc_user> <bmc_pass>
      POST OEM Action FTSComputerSystem.VirtualMedia { VirtualMediaAction:
      "DisconnectCD" }. Used to release an attached NFS or SMB CD.

  mount   <bmc_ip> <bmc_user> <bmc_pass>
      Wait until attachment is detected. For SMB this is functionally identical
      to "verify" with a short retry window (Server non-empty). For NFS this
      polls the OEM Action AllowableValues for "DisconnectCD" presence
      (= ConnectCD has taken effect).

  umount  <bmc_ip> <bmc_user> <bmc_pass>
      Clear <Type>Image configuration (PATCH with empty fields). Effectively
      detaches. NFS callers should typically use "disconnect-cd" first.

  verify  <bmc_ip> <bmc_user> <bmc_pass>
      Exit 0 if <Type>Image.Server is non-empty, exit 1 otherwise.

Notes:
  - SMB ShareName format differs from Supermicro bmc-virtualmedia.sh:
    Supermicro takes "\\\\public" (single backslash on disk via YAML literal),
    iRMC takes "public" (bare share name). Caller must strip backslashes.
  - NFS export path is given as POSIX path (e.g. "/var/samba/public"). iRMC
    negotiates NFSv4 with the server-side v4root pseudo-fs.
  - Requires curl >= 7.85 with --ciphers DEFAULT@SECLEVEL=0 support.
EOF
    exit 1
}

# Virtual media slot type — set by --type=<X> flag, defaults to CDImage.
VM_TYPE="CDImage"

# Remote share protocol — set by --share-type=<X> flag, defaults to SMB.
SHARE_TYPE="SMB"

# Common curl options for iRMC S4 (HTTPS + legacy DH ciphers)
IRMC_CURL_OPTS="-sk --ciphers DEFAULT@SECLEVEL=0 --max-time 30"

# OEM Action endpoint for ConnectCD / DisconnectCD
IRMC_OEM_ACTION_PATH="/redfish/v1/Systems/0/Actions/Oem/FTSComputerSystem.VirtualMedia"
IRMC_OEM_VM_PATH="/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia"
# The OEM Action AllowableValues live on the System resource (not the OEM VM
# sub-resource): /redfish/v1/Systems/0 → Actions.Oem.#FTSComputerSystem.VirtualMedia
# .VirtualMediaAction@Redfish.AllowableValues.
IRMC_SYSTEM_PATH="/redfish/v1/Systems/0"

irmc_get() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; path="$4"
    curl $IRMC_CURL_OPTS -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_ip}${path}"
}

irmc_get_etag() {
    # Fujitsu OEM resources require If-Match on PATCH. The ETag is exposed both
    # via the HTTP ETag header and the @odata.etag JSON field.
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; path="$4"
    etag=$(curl $IRMC_CURL_OPTS -u "${bmc_user}:${bmc_pass}" \
        -D - -o /dev/null "https://${bmc_ip}${path}" \
        | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*\(.*\)\r\?$/\1/p' \
        | head -1 \
        | tr -d '\r"')
    if [ -z "$etag" ]; then
        body=$(curl $IRMC_CURL_OPTS -u "${bmc_user}:${bmc_pass}" \
            "https://${bmc_ip}${path}")
        etag=$(echo "$body" | tr -d '\n\r' \
            | sed -n 's/.*"@odata.etag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    echo "$etag"
}

irmc_patch() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; path="$4"; payload="$5"
    etag=$(irmc_get_etag "$bmc_ip" "$bmc_user" "$bmc_pass" "$path")
    if [ -z "$etag" ]; then
        echo "WARNING: failed to obtain ETag for $path — attempting If-Match: *" >&2
        etag='*'
    fi
    # iRMC S4 quirk: If-Match must be the bare ETag value WITHOUT quotes
    # (standard says quoted, but iRMC returns 412 if quotes are present).
    curl $IRMC_CURL_OPTS -u "${bmc_user}:${bmc_pass}" \
        -X PATCH "https://${bmc_ip}${path}" \
        -H 'Content-Type: application/json' \
        -H "If-Match: ${etag}" \
        -w '\nHTTP %{http_code}\n' \
        -d "$payload"
}

# Extract a JSON value with sed (single-line, after `tr -d '\\\n\r'` normalization).
# Usage: json_get "$body" "Server"  → value or empty.
json_get() {
    body="$1"; key="$2"
    echo "$body" | tr -d '\\' | tr -d '\n\r' \
        | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

cmd_status() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    body=$(irmc_get "$bmc_ip" "$bmc_user" "$bmc_pass" \
        "/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia")
    cd_block=$(echo "$body" | tr -d '\n\r' | sed -n "s/.*\"${VM_TYPE}\"[[:space:]]*:[[:space:]]*{\\([^}]*\\)}.*/\\1/p")
    if [ -z "$cd_block" ]; then
        echo "ERROR: failed to parse ${VM_TYPE} block" >&2
        echo "$body" >&2
        return 1
    fi
    server=$(echo "{$cd_block}" | tr -d '\\' \
        | sed -n 's/.*"Server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    share=$(echo "{$cd_block}" | tr -d '\\' \
        | sed -n 's/.*"ShareName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    image=$(echo "{$cd_block}" | tr -d '\\' \
        | sed -n 's/.*"ImageName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    remote_enabled=$(json_get "$body" "RemoteMountEnabled")
    if [ -z "$remote_enabled" ]; then
        remote_enabled=$(echo "$body" | tr -d '\n\r' \
            | sed -n 's/.*"RemoteMountEnabled"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
    fi
    echo "${VM_TYPE}.Server=${server}"
    echo "${VM_TYPE}.ShareName=${share}"
    echo "${VM_TYPE}.ImageName=${image}"
    echo "RemoteMountEnabled=${remote_enabled}"
}

cmd_config() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    share_host="$4"; share_path="$5"; image_name="$6"
    share_user="${7:-}"; share_pass="${8:-}"

    if [ "$SHARE_TYPE" = "NFS" ]; then
        # NFS uses IP-based authorization; UserName/Password are ignored by iRMC
        # (it normalizes them to null in the response). Force empty here so a
        # stray argument from an SMB-style caller doesn't end up in the body.
        payload=$(printf '{"%s":{"Server":"%s","UserName":"","Password":"","UserDomain":"","ShareType":"NFS","ShareName":"%s","ImageName":"%s"},"RemoteMountEnabled":true}' \
            "$VM_TYPE" "$share_host" "$share_path" "$image_name")
    else
        payload=$(printf '{"%s":{"Server":"%s","UserName":"%s","Password":"%s","UserDomain":"","ShareType":"SMB","ShareName":"%s","ImageName":"%s"},"RemoteMountEnabled":true}' \
            "$VM_TYPE" "$share_host" "$share_user" "$share_pass" "$share_path" "$image_name")
    fi

    echo "PATCH payload: $payload"
    irmc_patch "$bmc_ip" "$bmc_user" "$bmc_pass" \
        "$IRMC_OEM_VM_PATH" "$payload"
}

# POST OEM Action (FTSComputerSystem.VirtualMedia) with the given action token.
irmc_oem_action() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; action="$4"
    payload=$(printf '{"VirtualMediaAction":"%s"}' "$action")
    echo "POST OEM action payload: $payload"
    curl $IRMC_CURL_OPTS -u "${bmc_user}:${bmc_pass}" \
        -X POST "https://${bmc_ip}${IRMC_OEM_ACTION_PATH}" \
        -H 'Content-Type: application/json' \
        -w '\nHTTP %{http_code}\n' \
        -d "$payload"
}

cmd_connect_cd() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    irmc_oem_action "$bmc_ip" "$bmc_user" "$bmc_pass" "ConnectCD"
}

cmd_disconnect_cd() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    irmc_oem_action "$bmc_ip" "$bmc_user" "$bmc_pass" "DisconnectCD"
}

# Poll OEM VirtualMedia until VirtualMediaAction@Redfish.AllowableValues lists
# "DisconnectCD" — that is the canonical signal that ConnectCD has taken effect.
# Used for NFS (no AutoAttach) where Server non-empty alone is not sufficient.
cmd_wait_attached() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    i=0
    while [ $i -lt 12 ]; do
        body=$(irmc_get "$bmc_ip" "$bmc_user" "$bmc_pass" "$IRMC_SYSTEM_PATH")
        if echo "$body" | tr -d '\n\r' | grep -q '"DisconnectCD"'; then
            echo "OK: AllowableValues contains DisconnectCD — ${VM_TYPE} attached"
            return 0
        fi
        i=$((i+1))
        sleep 5
    done
    echo "ERROR: AllowableValues did not switch to DisconnectCD within 60 seconds" >&2
    cmd_status "$bmc_ip" "$bmc_user" "$bmc_pass" >&2
    return 1
}

cmd_mount() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    # NFS is not AutoAttached: PATCH alone does not produce an attach event.
    # ConnectCD must have been POSTed already; here we just confirm via the
    # OEM Action AllowableValues transition.
    if [ "$SHARE_TYPE" = "NFS" ]; then
        cmd_wait_attached "$bmc_ip" "$bmc_user" "$bmc_pass"
        return $?
    fi
    # SMB: PATCH triggers attach via AutoAttach. Wait briefly for Server to
    # appear non-empty (= iRMC has accepted the configuration).
    i=0
    while [ $i -lt 6 ]; do
        if cmd_verify "$bmc_ip" "$bmc_user" "$bmc_pass" >/dev/null; then
            echo "OK: ${VM_TYPE} attached"
            return 0
        fi
        i=$((i+1))
        sleep 2
    done
    echo "ERROR: ${VM_TYPE} not attached after 12 seconds" >&2
    cmd_status "$bmc_ip" "$bmc_user" "$bmc_pass" >&2
    return 1
}

cmd_umount() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    payload=$(printf '{"%s":{"Server":"","UserName":"","Password":"","UserDomain":"","ShareType":"%s","ShareName":"","ImageName":""}}' \
        "$VM_TYPE" "$SHARE_TYPE")
    echo "PATCH payload: $payload"
    irmc_patch "$bmc_ip" "$bmc_user" "$bmc_pass" \
        "$IRMC_OEM_VM_PATH" "$payload"
}

cmd_verify() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    body=$(irmc_get "$bmc_ip" "$bmc_user" "$bmc_pass" \
        "/redfish/v1/Systems/0/Oem/ts_fujitsu/VirtualMedia")
    server=$(echo "$body" | tr -d '\n\r' | sed -n "s/.*\"${VM_TYPE}\"[[:space:]]*:[[:space:]]*{\\([^}]*\\)}.*/\\1/p" \
        | tr -d '\\' \
        | sed -n 's/.*"Server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$server" ]; then
        echo "OK: ${VM_TYPE}.Server=${server}"
        return 0
    fi
    echo "ERROR: ${VM_TYPE}.Server is empty" >&2
    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --type=CD|--type=CDImage) VM_TYPE="CDImage"; shift ;;
        --type=HD|--type=HDImage) VM_TYPE="HDImage"; shift ;;
        --type=FD|--type=FDImage) VM_TYPE="FDImage"; shift ;;
        --type=*) echo "ERROR: unknown --type value: ${1#--type=}" >&2; usage ;;
        --share-type=SMB|--share-type=smb) SHARE_TYPE="SMB"; shift ;;
        --share-type=NFS|--share-type=nfs) SHARE_TYPE="NFS"; shift ;;
        --share-type=*) echo "ERROR: unknown --share-type value: ${1#--share-type=}" >&2; usage ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

if [ $# -lt 4 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    status)
        if [ $# -lt 3 ]; then usage; fi
        cmd_status "$1" "$2" "$3"
        ;;
    config)
        if [ $# -lt 6 ]; then usage; fi
        cmd_config "$@"
        ;;
    connect-cd)
        if [ $# -lt 3 ]; then usage; fi
        cmd_connect_cd "$1" "$2" "$3"
        ;;
    disconnect-cd)
        if [ $# -lt 3 ]; then usage; fi
        cmd_disconnect_cd "$1" "$2" "$3"
        ;;
    mount)
        if [ $# -lt 3 ]; then usage; fi
        cmd_mount "$1" "$2" "$3"
        ;;
    umount)
        if [ $# -lt 3 ]; then usage; fi
        cmd_umount "$1" "$2" "$3"
        ;;
    verify)
        if [ $# -lt 3 ]; then usage; fi
        cmd_verify "$1" "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
