#!/bin/sh
set -eu

# Fujitsu iRMC S4 firmware update via the Web UI endpoint /irmcupdate.
#
# The endpoint takes a multipart/form-data upload of the raw firmware BIN.
# Progress is exposed at /irmcprogress as a small XML document (<Status>
# with <Value> percent and <Message>). When the flash finishes the iRMC
# automatically reboots; the BMC stops responding for 60-120s.
#
# References:
#   - Phase 17 research notes (report/.../f1-research-notes.md)
#   - Fujitsu ASP do_flirmcs4.sh (uses local OS path, not HTTP — different)
#   - mmurayama.blogspot.com 2016/07
#
# Endpoint details (HTTP):
#   POST /irmcupdate?flashSelect=255
#     Content-Type: multipart/form-data; boundary=...
#     part name="data" with the BIN body
#   flashSelect=255 → write both firmware images (redundant store safety).
#
# Endpoint details (Redfish OEM, alternate):
#   POST /redfish/v1/Managers/iRMC/Actions/Oem/FTSManager.FWUpdate
#   Task-based; not used by default in this script.

usage() {
    cat <<EOF
Usage: irmc-fw-update.sh <command> <bmc_ip> <bmc_user> <bmc_pass> [args...]

Commands:
  version <ip> <user> <pass>
      Print the running iRMC FirmwareVersion (e.g. "9.08F").

  upload <ip> <user> <pass> <bin_path> [--flash-select=N]
      POST the BIN to /irmcupdate?flashSelect=N (default 255 = both images).
      Returns when the HTTP upload completes; flashing continues server-side.

  progress <ip> <user> <pass>
      GET /irmcprogress and print "<value> <message>".

  wait <ip> <user> <pass> [--timeout=SEC] [--interval=SEC]
      Poll /irmcprogress every <interval> (default 30s) until Value=0
      ("No update in progress.") OR until timeout. Returns 0 on idle,
      2 on timeout, 1 on HTTP error.

  wait-reboot <ip> <user> <pass> [--timeout=SEC]
      Wait for iRMC to drop and come back. Probes /redfish/v1/Managers/iRMC
      via curl every 10s. Connection refused / timeout is allowed during
      the reboot window. Success = HTTP 200 with a JSON body and a
      readable FirmwareVersion field.

  flash <ip> <user> <pass> <bin_path> [--flash-select=N] [--timeout=SEC]
      upload → wait (progress) → wait-reboot → version.
      Wrapper that drives a full flash sequence.

Environment:
  IRMC_LOG_DIR  Optional dir for per-call curl logs. Default: tmp/<cwd>.

Notes:
  - Uses --ciphers DEFAULT@SECLEVEL=0 (iRMC S4 legacy DH keys).
  - flashSelect=255 flashes both images (low + high); safest for end state.
  - HTTP 503 / Connection refused during reboot phase is expected; handled.
  - The BMC factory reset (ipmitool raw 0x3c 0x40) is BANNED by CLAUDE.md;
    this script never invokes such recovery commands.
EOF
    exit 1
}

[ $# -lt 1 ] && usage

IRMC_CURL_OPTS="-sk --ciphers DEFAULT@SECLEVEL=0"
IRMC_CURL_MAX_TIME=600
IRMC_LOG_DIR="${IRMC_LOG_DIR:-tmp}"

mkdir -p "$IRMC_LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

irmc_fw_version() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    curl $IRMC_CURL_OPTS --max-time 15 -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_ip}/redfish/v1/Managers/iRMC" \
        | tr -d '\n\r' \
        | sed -n 's/.*"FirmwareVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

irmc_progress_raw() {
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    curl $IRMC_CURL_OPTS --max-time 15 -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_ip}/irmcprogress"
}

irmc_progress_parse() {
    xml="$1"
    val=$(echo "$xml" | tr -d '\n\r' | sed -n 's/.*<Value>\([^<]*\)<\/Value>.*/\1/p')
    sev=$(echo "$xml" | tr -d '\n\r' | sed -n 's/.*<Severity>\([^<]*\)<\/Severity>.*/\1/p')
    msg=$(echo "$xml" | tr -d '\n\r' | sed -n 's/.*<Message>\([^<]*\)<\/Message>.*/\1/p')
    printf 'value=%s severity=%s message=%s\n' "${val:-?}" "${sev:-?}" "${msg:-?}"
}

cmd_version() {
    [ $# -lt 3 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    v=$(irmc_fw_version "$bmc_ip" "$bmc_user" "$bmc_pass")
    if [ -z "$v" ]; then
        log "ERROR: failed to read FirmwareVersion from ${bmc_ip}"
        exit 1
    fi
    echo "$v"
}

cmd_progress() {
    [ $# -lt 3 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    raw=$(irmc_progress_raw "$bmc_ip" "$bmc_user" "$bmc_pass")
    irmc_progress_parse "$raw"
}

cmd_upload() {
    [ $# -lt 4 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; bin_path="$4"
    flash_select="255"
    shift 4
    while [ $# -gt 0 ]; do
        case "$1" in
            --flash-select=*) flash_select="${1#--flash-select=}" ;;
            *) log "ERROR: unknown arg $1"; exit 1 ;;
        esac
        shift
    done

    if [ ! -f "$bin_path" ]; then
        log "ERROR: BIN file not found: $bin_path"
        exit 1
    fi
    bin_size=$(stat -c%s "$bin_path")
    log "uploading $bin_path ($bin_size bytes) → ${bmc_ip}/irmcupdate?flashSelect=${flash_select}"

    log_file="${IRMC_LOG_DIR}/upload-$(date +%Y%m%d-%H%M%S).log"
    # iRMC /irmcupdate endpoint expects a multipart/form-data POST with the
    # BIN attached as a field named "file" (empirically determined — the
    # field names "data", "firmware", "flashfile", "image", "fwfile", "bin",
    # "payload", "upload" all return <Value>6</Value> "File not provided",
    # while "file" returns <Value>41</Value> "Invalid image" for a dummy
    # payload, i.e. field name accepted, content validation reached).
    set +e
    curl $IRMC_CURL_OPTS --max-time $IRMC_CURL_MAX_TIME \
        -u "${bmc_user}:${bmc_pass}" \
        -F "file=@${bin_path}" \
        -w 'HTTP_STATUS=%{http_code}\nTIME_TOTAL=%{time_total}\n' \
        -o "$log_file" \
        "https://${bmc_ip}/irmcupdate?flashSelect=${flash_select}" > "${log_file}.meta" 2>&1
    rc=$?
    set -e

    log "upload rc=${rc}, meta:"
    cat "${log_file}.meta" >&2 || true
    log "response body head:"
    head -c 1024 "$log_file" >&2 || true
    echo "" >&2

    if [ $rc -ne 0 ]; then
        log "ERROR: curl failed with rc=${rc}"
        return 1
    fi

    http_status=$(sed -n 's/^HTTP_STATUS=\(.*\)$/\1/p' "${log_file}.meta")
    case "$http_status" in
        200|202|204)
            log "upload accepted (HTTP $http_status)"
            return 0
            ;;
        *)
            log "ERROR: unexpected HTTP status: $http_status"
            return 1
            ;;
    esac
}

cmd_wait() {
    [ $# -lt 3 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    shift 3
    timeout=600
    interval=30
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout=*) timeout="${1#--timeout=}" ;;
            --interval=*) interval="${1#--interval=}" ;;
            *) log "ERROR: unknown arg $1"; exit 1 ;;
        esac
        shift
    done

    # Exit codes:
    #   0  idle confirmed (2 consecutive idle samples after BMC was responsive)
    #   2  timeout
    # Side effect: prints WAIT_SAW_DROP=1 on stdout if BMC became unreachable at
    # least once during polling, so the caller can short-circuit wait-reboot.

    log "polling /irmcprogress every ${interval}s, timeout ${timeout}s"
    elapsed=0
    consecutive_idle=0
    saw_drop=0
    while [ $elapsed -lt $timeout ]; do
        set +e
        raw=$(irmc_progress_raw "$bmc_ip" "$bmc_user" "$bmc_pass" 2>/dev/null)
        rc=$?
        set -e
        if [ $rc -ne 0 ] || [ -z "$raw" ]; then
            log "t=${elapsed}s: progress fetch failed (rc=${rc}); may be rebooting"
            consecutive_idle=0
            saw_drop=1
        else
            line=$(irmc_progress_parse "$raw")
            val=$(echo "$line" | sed -n 's/.*value=\([^ ]*\).*/\1/p')
            log "t=${elapsed}s: $line"
            if [ "$val" = "0" ]; then
                consecutive_idle=$((consecutive_idle + 1))
                if [ $consecutive_idle -ge 2 ]; then
                    log "idle confirmed (2 consecutive samples) at t=${elapsed}s (saw_drop=${saw_drop})"
                    echo "WAIT_SAW_DROP=${saw_drop}"
                    return 0
                fi
            else
                consecutive_idle=0
            fi
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    log "ERROR: timeout after ${timeout}s waiting for idle (saw_drop=${saw_drop})"
    echo "WAIT_SAW_DROP=${saw_drop}"
    return 2
}

cmd_wait_reboot() {
    [ $# -lt 3 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"
    shift 3
    timeout=300
    expected_drop=0  # set via --already-rebooted=1 to short-circuit when the
                     # preceding wait phase already observed the drop+return
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout=*) timeout="${1#--timeout=}" ;;
            --already-rebooted=*) expected_drop="${1#--already-rebooted=}" ;;
            *) log "ERROR: unknown arg $1"; exit 1 ;;
        esac
        shift
    done

    if [ "$expected_drop" = "1" ]; then
        log "BMC reboot already observed by caller — confirming BMC responds with FW version"
        v=$(irmc_fw_version "$bmc_ip" "$bmc_user" "$bmc_pass" 2>/dev/null || true)
        if [ -n "$v" ]; then
            log "BMC reachable with FirmwareVersion=${v}"
            return 0
        fi
        log "WARNING: BMC not reachable yet despite --already-rebooted=1; falling through"
    fi

    log "waiting for BMC reboot cycle (drop then return), timeout ${timeout}s"
    elapsed=0
    saw_drop=0
    while [ $elapsed -lt $timeout ]; do
        set +e
        v=$(irmc_fw_version "$bmc_ip" "$bmc_user" "$bmc_pass" 2>/dev/null)
        rc=$?
        set -e
        if [ $rc -ne 0 ] || [ -z "$v" ]; then
            if [ $saw_drop -eq 0 ]; then
                log "t=${elapsed}s: BMC unreachable (expected — reboot phase)"
                saw_drop=1
            else
                log "t=${elapsed}s: still unreachable"
            fi
        else
            if [ $saw_drop -eq 1 ]; then
                log "t=${elapsed}s: BMC returned with FirmwareVersion=${v}"
                return 0
            else
                log "t=${elapsed}s: BMC still responding with v=${v} (waiting for drop)"
            fi
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    if [ $saw_drop -eq 1 ]; then
        log "ERROR: BMC dropped but did not return within ${timeout}s"
        return 2
    else
        log "WARNING: BMC never dropped within ${timeout}s — flash may have been rejected"
        return 3
    fi
}

cmd_flash() {
    [ $# -lt 4 ] && usage
    bmc_ip="$1"; bmc_user="$2"; bmc_pass="$3"; bin_path="$4"
    shift 4
    flash_select="255"
    timeout_wait=900
    timeout_reboot=600
    while [ $# -gt 0 ]; do
        case "$1" in
            --flash-select=*) flash_select="${1#--flash-select=}" ;;
            --timeout=*) timeout_wait="${1#--timeout=}" ;;
            --reboot-timeout=*) timeout_reboot="${1#--reboot-timeout=}" ;;
            *) log "ERROR: unknown arg $1"; exit 1 ;;
        esac
        shift
    done

    log "=== flash sequence start ==="
    log "BMC: $bmc_ip, BIN: $bin_path, flashSelect=$flash_select"

    v_before=$(irmc_fw_version "$bmc_ip" "$bmc_user" "$bmc_pass" || echo unknown)
    log "FirmwareVersion before: ${v_before}"

    log "--- step 1: upload BIN ---"
    cmd_upload "$bmc_ip" "$bmc_user" "$bmc_pass" "$bin_path" "--flash-select=$flash_select"

    log "--- step 2: wait for flash progress to idle (timeout ${timeout_wait}s) ---"
    set +e
    wait_out=$(cmd_wait "$bmc_ip" "$bmc_user" "$bmc_pass" "--timeout=$timeout_wait" "--interval=30")
    wait_rc=$?
    set -e
    log "wait phase rc=${wait_rc}, summary line: ${wait_out}"
    saw_drop=$(echo "$wait_out" | sed -n 's/^WAIT_SAW_DROP=\(.*\)$/\1/p' | tail -1)
    saw_drop="${saw_drop:-0}"
    if [ $wait_rc -ne 0 ]; then
        log "wait phase exited rc=${wait_rc}; continuing to reboot wait"
    fi

    log "--- step 3: wait for BMC reboot cycle (timeout ${timeout_reboot}s, already-rebooted=${saw_drop}) ---"
    cmd_wait_reboot "$bmc_ip" "$bmc_user" "$bmc_pass" "--timeout=$timeout_reboot" "--already-rebooted=$saw_drop"

    log "--- step 4: post-update version check ---"
    sleep 5
    v_after=$(irmc_fw_version "$bmc_ip" "$bmc_user" "$bmc_pass" || echo unknown)
    log "FirmwareVersion after: ${v_after}"
    log "=== flash sequence end ==="

    if [ "$v_after" = "$v_before" ] || [ "$v_after" = unknown ]; then
        log "WARNING: FirmwareVersion did not change (before=${v_before} after=${v_after})"
        return 1
    fi
    return 0
}

cmd="$1"; shift
case "$cmd" in
    version)      cmd_version "$@" ;;
    upload)       cmd_upload "$@" ;;
    progress)     cmd_progress "$@" ;;
    wait)         cmd_wait "$@" ;;
    wait-reboot)  cmd_wait_reboot "$@" ;;
    flash)        cmd_flash "$@" ;;
    *) usage ;;
esac
