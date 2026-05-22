#!/bin/sh
# Fujitsu iRMC S4 BIOS/RAID auto-setup wrapper.
#
# Subcommands:
#   discover    <config.yml>              Report current state.
#   setup-bios  <config.yml> [--cycle]    Apply config['bios_settings'] via BSPBR XML
#                                          and (optionally) cycle to trigger boot phase.
#   verify-bios <config.yml>              Confirm current BIOS settings match config.
#   setup-raid10 <config.yml>             (TBD) Create RAID10 via BIOS UEFI HII.
#   full-setup  <config.yml>              setup-bios → cycle → verify-bios → setup-raid10.
#
# Requires: bin/yq, .venv/bin/python with playwright, scripts/{bmc-power,irmc-bios,irmc-oem-screenshot,irmc-kvm-interact}.
set -eu

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$PROJ_DIR/scripts"
PY="$PROJ_DIR/.venv/bin/python"
YQ="$PROJ_DIR/bin/yq"
WORK="$PROJ_DIR/tmp/biosraid"
mkdir -p "$WORK"

usage() {
    echo "Usage: $0 <discover|setup-bios|verify-bios|setup-raid10|full-setup> <config.yml> [options]" >&2
    exit 1
}

cfg_get() {
    "$YQ" "$1" "$CONFIG" 2>/dev/null
}

load_config() {
    CONFIG="$1"
    [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }
    BMC_IP=$(cfg_get '.bmc_ip')
    BMC_USER=$(cfg_get '.bmc_user')
    BMC_PASS=$(cfg_get '.bmc_pass')
    BMC_SCHEME=$(cfg_get '.bmc_scheme')
    BMC_CURL_OPTS=$(cfg_get '.bmc_curl_opts')
    POWER_ON_RESET_TYPE=$(cfg_get '.power_on_reset_type')
    BMC_PATCH_REQUIRES_ETAG=$(cfg_get '.bmc_patch_requires_etag')
    BMC_BOOT_OVERRIDE_NO_DISABLED=$(cfg_get '.bmc_boot_override_no_disabled')
    export BMC_SCHEME BMC_CURL_OPTS POWER_ON_RESET_TYPE BMC_PATCH_REQUIRES_ETAG BMC_BOOT_OVERRIDE_NO_DISABLED
}

bmc_curl() {
    curl -sS -k --ciphers DEFAULT@SECLEVEL=0 --max-time 30 -u "$BMC_USER:$BMC_PASS" "$@"
}

cmd_discover() {
    echo "=== Power state ==="
    "$SCRIPTS_DIR/bmc-power.sh" status "$BMC_IP" "$BMC_USER" "$BMC_PASS" || true

    echo
    echo "=== System info ==="
    bmc_curl "https://$BMC_IP/redfish/v1/Systems/0" \
        | grep -E '"Manufacturer"|"Model"|"BiosVersion"|"SerialNumber"|"PowerState"|"TotalSystemMemoryGiB"' \
        | head -8 || true

    echo
    echo "=== Boot config ==="
    bmc_curl "https://$BMC_IP/redfish/v1/Systems/0/Oem/ts_fujitsu/BootConfig" \
        | grep -E '"BootDevice"|"BootType"|"NextBootOnlyEnabled"' || true

    echo
    echo "=== Boot Override ==="
    bmc_curl "https://$BMC_IP/redfish/v1/Systems/0" \
        | grep -A 2 '"BootSourceOverrideTarget":' | head -3 || true

    echo
    echo "=== RAID controller (from config) ==="
    cfg_get '.raid_controller' | sed 's/^/  /'

    echo
    echo "=== Current BIOS settings (backup XML) ==="
    BACKUP="$WORK/bios-discover.xml"
    if "$PY" "$SCRIPTS_DIR/irmc-bios.py" \
        --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
        --task-timeout 5 --skip-wait backup "$BACKUP" >/dev/null 2>&1; then :
    else
        echo "  (could not refresh backup; using $BACKUP if present)"
    fi
    # Try direct download even if backup task is still pending (existing snapshot)
    bmc_curl -X POST -H 'Content-Type: application/json' -d '{}' \
        -o "$BACKUP" \
        "https://$BMC_IP/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRSaveBackupToFile" \
        >/dev/null 2>&1 || true
    if [ -s "$BACKUP" ] && head -c 100 "$BACKUP" | grep -q '<?xml'; then
        "$PY" "$SCRIPTS_DIR/irmc-bios.py" show "$BACKUP" \
            'BootOptionFilter|LaunchStorageOpRomPolicy|LaunchPxeOpRomPolicy|LaunchVideoOpRomPolicy|Csm|SerialPort1'
    else
        echo "  (BIOS backup XML not yet available)"
    fi
}

cmd_setup_bios() {
    DO_CYCLE=0
    for a in "$@"; do
        case "$a" in --cycle) DO_CYCLE=1 ;; esac
    done

    BACKUP="$WORK/bios-pre.xml"
    EDITED="$WORK/bios-edited.xml"

    echo "=== Step 1: Backup current BIOS settings ==="
    "$PY" "$SCRIPTS_DIR/irmc-bios.py" \
        --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
        --task-timeout 5 --skip-wait backup "$BACKUP" >/dev/null 2>&1 || true
    bmc_curl -X POST -H 'Content-Type: application/json' -d '{}' \
        -o "$BACKUP" \
        "https://$BMC_IP/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRSaveBackupToFile"
    if ! head -c 100 "$BACKUP" | grep -q '<?xml'; then
        echo "ERROR: failed to download backup XML"
        echo "Hint: Trigger a fresh backup task (cycle the host) and re-run."
        exit 3
    fi
    echo "  Saved: $BACKUP"

    echo
    echo "=== Step 2: Apply config['bios_settings.supported'] ==="
    cp "$BACKUP" "$EDITED"
    cfg_get '.bios_settings.supported | to_entries | .[] | .key + "\t" + .value' \
        | while IFS=$(printf '\t') read -r key val; do
            [ -n "$key" ] || continue
            "$PY" "$SCRIPTS_DIR/irmc-bios.py" set "$EDITED" "$key" "$val" 2>&1
        done

    echo
    echo "=== Step 3: Diff ==="
    "$PY" "$SCRIPTS_DIR/irmc-bios.py" diff "$BACKUP" "$EDITED" || true

    echo
    echo "=== Step 4: POST BSPBRRestore ==="
    "$PY" "$SCRIPTS_DIR/irmc-bios.py" \
        --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
        --skip-wait restore "$EDITED"

    if [ "$DO_CYCLE" = "1" ]; then
        echo
        echo "=== Step 5: Cycle to trigger BSPBR boot phase ==="
        "$PROJ_DIR/oplog.sh" "$SCRIPTS_DIR/bmc-power.sh" cycle \
            "$BMC_IP" "$BMC_USER" "$BMC_PASS" 25
        echo
        echo "  Wait for boot phase to complete (~2-3 min), then run verify-bios."
    else
        echo
        echo "  (skipped cycle; restore will apply on next power cycle)"
    fi
}

cmd_verify_bios() {
    BACKUP="$WORK/bios-verify.xml"
    bmc_curl -X POST -H 'Content-Type: application/json' -d '{}' \
        -o "$BACKUP" \
        "https://$BMC_IP/redfish/v1/Systems/0/Bios/Actions/Oem/FTSBios.BSPBRSaveBackupToFile"
    if ! head -c 100 "$BACKUP" | grep -q '<?xml'; then
        echo "ERROR: failed to download backup XML"
        exit 3
    fi

    expected=$(cfg_get '.bios_settings.supported | to_entries | .[] | .key + "=" + .value')
    ok=1
    echo "$expected" | while IFS='=' read -r key val; do
        [ -n "$key" ] || continue
        cur=$("$PY" "$SCRIPTS_DIR/irmc-bios.py" show "$BACKUP" "^${key}$" \
            | awk -F'|' -v k="$key" '$1 ~ k {gsub(/^ +| +$/,"",$3); print $3}' | head -1)
        if [ "$cur" = "$val" ]; then
            printf "  OK    %-30s = %s\n" "$key" "$val"
        else
            printf "  FAIL  %-30s expected=%s actual=%s\n" "$key" "$val" "$cur"
            ok=0
        fi
    done
    if [ "$ok" = "1" ]; then
        echo "All BIOS settings match config."
    fi
}

cmd_setup_raid10() {
    CONTINUE_FROM=S1
    STOP_AT=S10
    SKIP_RESET=0
    SESSION_SLUG=""
    for a in "$@"; do
        case "$a" in
            --continue-from=*) CONTINUE_FROM=${a#--continue-from=} ;;
            --stop-at=*) STOP_AT=${a#--stop-at=} ;;
            --skip-reset) SKIP_RESET=1 ;;
            --session=*) SESSION_SLUG=${a#--session=} ;;
        esac
    done
    if [ -z "$SESSION_SLUG" ]; then
        SESSION_SLUG="$(date +%Y%m%d_%H%M%S)"
    fi
    SESSION_DIR="$PROJ_DIR/tmp/biosraid/$SESSION_SLUG"
    mkdir -p "$SESSION_DIR"
    STATE_FILE="$SESSION_DIR/state.txt"
    TIMELINE="$SESSION_DIR/timeline.log"
    : > "$TIMELINE"

    timeline() {
        printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$TIMELINE"
    }

    step_num() {
        case "$1" in
            S1) echo 1 ;; S2) echo 2 ;; S3) echo 3 ;; S4) echo 4 ;;
            S5) echo 5 ;; S6) echo 6 ;; S7) echo 7 ;; S8) echo 8 ;;
            S9) echo 9 ;; S10) echo 10 ;;
            *) echo 0 ;;
        esac
    }

    step_ge() {
        cur=$(step_num "$1")
        from=$(step_num "$CONTINUE_FROM")
        stop=$(step_num "$STOP_AT")
        if [ "$cur" -ge "$from" ] && [ "$cur" -le "$stop" ]; then
            return 0
        fi
        return 1
    }

    mark_done() {
        echo "$1" > "$STATE_FILE"
    }

    timeline "session=$SESSION_SLUG dir=$SESSION_DIR continue_from=$CONTINUE_FROM"

    step_S1() {
        step_ge S1 || { timeline "S1 skipped (continue-from=$CONTINUE_FROM)"; return 0; }
        if [ "$SKIP_RESET" = 1 ]; then
            timeline "S1 skipped (--skip-reset)"
            mark_done S1; return 0
        fi
        timeline "S1: BMC Manager.Reset GracefulRestart"
        code=$(bmc_curl -X POST -H 'Content-Type: application/json' \
            -d '{"ResetType":"GracefulRestart"}' \
            -o "$SESSION_DIR/S1_reset.body" \
            -w '%{http_code}' \
            "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Manager.Reset" || echo 000)
        timeline "S1: HTTP $code"
        case "$code" in 200|202|204) : ;; *) timeline "S1: trying ForceRestart fallback"
            code=$(bmc_curl -X POST -H 'Content-Type: application/json' \
                -d '{"ResetType":"ForceRestart"}' \
                -o "$SESSION_DIR/S1_reset2.body" \
                -w '%{http_code}' \
                "https://$BMC_IP/redfish/v1/Managers/iRMC/Actions/Manager.Reset" || echo 000)
            timeline "S1: ForceRestart HTTP $code"
            case "$code" in 200|202|204) : ;; *)
                timeline "S1: WARN no Reset succeeded; continuing anyway"; ;;
            esac
        esac
        timeline "S1: waiting 30s for BMC to actually start the reset..."
        sleep 30
        timeline "S1: now polling for BMC to come back up (max 240s)..."
        start=$(date +%s)
        while :; do
            sleep 5
            code=$(curl -sS -k --ciphers DEFAULT@SECLEVEL=0 \
                --connect-timeout 3 --max-time 8 \
                -o /dev/null -w '%{http_code}' \
                "https://$BMC_IP/redfish/v1/" 2>/dev/null || echo 000)
            elapsed=$(( $(date +%s) - start ))
            if [ "$code" = "200" ]; then
                timeline "S1: BMC up after ${elapsed}s (post-reset)"
                break
            fi
            if [ "$elapsed" -ge 240 ]; then
                timeline "S1: TIMEOUT BMC did not come back"
                return 1
            fi
        done
        mark_done S1
    }

    step_S2() {
        step_ge S2 || { timeline "S2 skipped"; return 0; }
        timeline "S2: ForceOff → boot-override BiosSetup UEFI → on"
        "$SCRIPTS_DIR/bmc-power.sh" status "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
            > "$SESSION_DIR/S2_pre_state.txt" 2>&1 || true
        timeline "S2: pre PowerState=$(cat $SESSION_DIR/S2_pre_state.txt)"
        if grep -qi '^On$' "$SESSION_DIR/S2_pre_state.txt"; then
            "$SCRIPTS_DIR/bmc-power.sh" forceoff "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
                >> "$TIMELINE" 2>&1 || true
            sleep 20
        fi
        BMC_PATCH_REQUIRES_ETAG=1 \
            "$SCRIPTS_DIR/bmc-power.sh" boot-override \
            "$BMC_IP" "$BMC_USER" "$BMC_PASS" BiosSetup UEFI \
            >> "$TIMELINE" 2>&1
        "$SCRIPTS_DIR/bmc-power.sh" on "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
            >> "$TIMELINE" 2>&1
        timeline "S2: powered on, waiting 90s for POST → BIOS Setup..."
        sleep 90
        mark_done S2
    }

    step_S3() {
        step_ge S3 || { timeline "S3 skipped"; return 0; }
        timeline "S3: KVM session + assert-canvas (640x480 → 800x600)"
        out="$SESSION_DIR/S3_kvm.log"
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 300 \
            shell "wait:3; force-refresh:$SESSION_DIR/S3_init.png; assert-canvas:640x480,30; force-refresh:$SESSION_DIR/S3_640.png; assert-canvas:800x600,30; force-refresh:$SESSION_DIR/S3_settled.png" \
            > "$out" 2>&1 || true
        timeline "S3: $(grep -c assert-canvas $out) assert-canvas attempts in log"
        mark_done S3
    }

    step_S4() {
        step_ge S4 || { timeline "S4 skipped"; return 0; }
        timeline "S4: BIOS Main → Advanced タブ移動 (ArrowRight x3)"
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 500 \
            shell "force-refresh:$SESSION_DIR/S4_before.png; sendkeys:ArrowRight; wait:1; force-refresh:$SESSION_DIR/S4_right1.png; sendkeys:ArrowRight; wait:1; force-refresh:$SESSION_DIR/S4_right2.png; sendkeys:ArrowRight; wait:1; force-refresh:$SESSION_DIR/S4_advanced.png" \
            > "$SESSION_DIR/S4_kvm.log" 2>&1 || true
        timeline "S4: screenshots saved (S4_advanced.png expected to show Advanced tab)"
        mark_done S4
    }

    step_S5() {
        step_ge S5 || { timeline "S5 skipped"; return 0; }
        timeline "S5: Advanced 内 AVAGO MegaRAID Utility 発見的探索 (ArrowDown x12 + screenshot each)"
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 400 \
            shell --screenshot-each "$SESSION_DIR/S5" \
            "force-refresh:$SESSION_DIR/S5_start.png; sendkeys:ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown,ArrowDown; wait:1; force-refresh:$SESSION_DIR/S5_end.png" \
            > "$SESSION_DIR/S5_kvm.log" 2>&1 || true
        timeline "S5: shots in $SESSION_DIR/S5_NNN_*.png — inspect manually to locate AVAGO row"
        mark_done S5
    }

    step_S6() {
        step_ge S6 || { timeline "S6 skipped"; return 0; }
        timeline "S6: Enter AVAGO MegaRAID → Main Menu → Configuration Management → Create Virtual Drive"
        AVAGO_DOWN=$(cfg_get '.raid_setup.avago_arrowdown // ""')
        CFGMGMT_DOWN=$(cfg_get '.raid_setup.cfgmgmt_arrowdown // ""')
        CREATEVD_DOWN=$(cfg_get '.raid_setup.createvd_arrowdown // ""')
        if [ -z "$AVAGO_DOWN" ] || [ -z "$CFGMGMT_DOWN" ] || [ -z "$CREATEVD_DOWN" ]; then
            timeline "S6: SKIPPED — raid_setup.{avago,cfgmgmt,createvd}_arrowdown not set in config"
            timeline "S6: inspect S5_*.png, identify down counts, set in config/training_tx1320.yml"
            return 0
        fi
        timeline "S6: avago_down=$AVAGO_DOWN cfgmgmt_down=$CFGMGMT_DOWN createvd_down=$CREATEVD_DOWN"
        avago_seq=$(yes ArrowDown | head -n "$AVAGO_DOWN" | tr '\n' ',' | sed 's/,$//')
        cfgmgmt_seq=$(yes ArrowDown | head -n "$CFGMGMT_DOWN" | tr '\n' ',' | sed 's/,$//')
        createvd_seq=$(yes ArrowDown | head -n "$CREATEVD_DOWN" | tr '\n' ',' | sed 's/,$//')
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 400 \
            shell --screenshot-each "$SESSION_DIR/S6" \
            "force-refresh:$SESSION_DIR/S6_start.png; sendkeys:$avago_seq; wait:1; sendkeys:Enter; wait:3; force-refresh:$SESSION_DIR/S6_after_avago_enter.png; sendkeys:$cfgmgmt_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S6_after_cfgmgmt.png; sendkeys:$createvd_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S6_after_createvd.png" \
            > "$SESSION_DIR/S6_kvm.log" 2>&1 || true
        timeline "S6: shots saved — inspect S6_after_createvd.png for Create VD form"
        mark_done S6
    }

    step_S7() {
        step_ge S7 || { timeline "S7 skipped"; return 0; }
        timeline "S7: RAID Level=RAID10, select 4 drives, Apply Changes"
        RAID10_DOWN=$(cfg_get '.raid_setup.raid10_arrowdown // ""')
        DRIVES_TAB=$(cfg_get '.raid_setup.drives_tab // ""')
        APPLY_TAB=$(cfg_get '.raid_setup.apply_tab // ""')
        if [ -z "$RAID10_DOWN" ] || [ -z "$DRIVES_TAB" ] || [ -z "$APPLY_TAB" ]; then
            timeline "S7: SKIPPED — raid_setup.{raid10_arrowdown,drives_tab,apply_tab} not set in config"
            return 0
        fi
        raid10_seq=$(yes ArrowDown | head -n "$RAID10_DOWN" | tr '\n' ',' | sed 's/,$//')
        drives_tab_seq=$(yes Tab | head -n "$DRIVES_TAB" | tr '\n' ',' | sed 's/,$//')
        apply_tab_seq=$(yes Tab | head -n "$APPLY_TAB" | tr '\n' ',' | sed 's/,$//')
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 400 \
            shell --screenshot-each "$SESSION_DIR/S7" \
            "force-refresh:$SESSION_DIR/S7_start.png; sendkeys:Enter; wait:2; sendkeys:$raid10_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S7_raid10_selected.png; sendkeys:$drives_tab_seq; wait:1; sendkeys:Space,ArrowDown,Space,ArrowDown,Space,ArrowDown,Space; wait:1; force-refresh:$SESSION_DIR/S7_drives_selected.png; sendkeys:$apply_tab_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S7_applied.png" \
            > "$SESSION_DIR/S7_kvm.log" 2>&1 || true
        timeline "S7: shots saved"
        mark_done S7
    }

    step_S8() {
        step_ge S8 || { timeline "S8 skipped"; return 0; }
        timeline "S8: Save Configuration → Confirm Yes"
        SAVE_TAB=$(cfg_get '.raid_setup.save_tab // ""')
        CONFIRM_TAB=$(cfg_get '.raid_setup.confirm_tab // "0"')
        if [ -z "$SAVE_TAB" ]; then
            timeline "S8: SKIPPED — raid_setup.save_tab not set"
            return 0
        fi
        save_tab_seq=$(yes Tab | head -n "$SAVE_TAB" | tr '\n' ',' | sed 's/,$//')
        if [ "$CONFIRM_TAB" -gt 0 ]; then
            confirm_seq=$(yes Tab | head -n "$CONFIRM_TAB" | tr '\n' ',' | sed 's/,$//')
            confirm_step="sendkeys:$confirm_seq; wait:1; sendkeys:Enter"
        else
            confirm_step="sendkeys:Enter"
        fi
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 400 \
            shell --screenshot-each "$SESSION_DIR/S8" \
            "force-refresh:$SESSION_DIR/S8_start.png; sendkeys:$save_tab_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S8_confirm.png; $confirm_step; wait:3; force-refresh:$SESSION_DIR/S8_saved.png" \
            > "$SESSION_DIR/S8_kvm.log" 2>&1 || true
        timeline "S8: saved"
        mark_done S8
    }

    step_S9() {
        step_ge S9 || { timeline "S9 skipped"; return 0; }
        timeline "S9: Save & Exit BIOS (Escape x5 + F4 + Enter) then cycle"
        "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
            --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
            --timeout 30 --wait-ms 400 \
            shell \
            "force-refresh:$SESSION_DIR/S9_pre.png; sendkeys:Escape,Escape,Escape,Escape,Escape; wait:2; force-refresh:$SESSION_DIR/S9_main.png; sendkeys:F4; wait:2; force-refresh:$SESSION_DIR/S9_savedialog.png; sendkeys:Enter; wait:5; force-refresh:$SESSION_DIR/S9_after_exit.png" \
            > "$SESSION_DIR/S9_kvm.log" 2>&1 || true
        timeline "S9: BIOS exit sent, waiting 30s for host to settle"
        sleep 30
        mark_done S9
    }

    step_S10() {
        step_ge S10 || { timeline "S10 skipped"; return 0; }
        timeline "S10: verify VD0 creation — re-enter BIOS Setup HII and screenshot Virtual Drives list"
        BMC_PATCH_REQUIRES_ETAG=1 \
            "$SCRIPTS_DIR/bmc-power.sh" boot-override \
            "$BMC_IP" "$BMC_USER" "$BMC_PASS" BiosSetup UEFI \
            >> "$TIMELINE" 2>&1 || true
        "$SCRIPTS_DIR/bmc-power.sh" cycle "$BMC_IP" "$BMC_USER" "$BMC_PASS" 25 \
            >> "$TIMELINE" 2>&1 || true
        sleep 90
        AVAGO_DOWN=$(cfg_get '.raid_setup.avago_arrowdown // "0"')
        VDLIST_DOWN=$(cfg_get '.raid_setup.vdlist_arrowdown // "0"')
        if [ "$AVAGO_DOWN" -gt 0 ] && [ "$VDLIST_DOWN" -gt 0 ]; then
            avago_seq=$(yes ArrowDown | head -n "$AVAGO_DOWN" | tr '\n' ',' | sed 's/,$//')
            vdlist_seq=$(yes ArrowDown | head -n "$VDLIST_DOWN" | tr '\n' ',' | sed 's/,$//')
            "$PY" "$SCRIPTS_DIR/irmc-kvm-interact.py" \
                --bmc-ip "$BMC_IP" --bmc-user "$BMC_USER" --bmc-pass "$BMC_PASS" \
                --timeout 30 --wait-ms 400 \
                shell \
                "force-refresh:$SESSION_DIR/S10_main.png; sendkeys:ArrowRight,ArrowRight,ArrowRight; wait:2; sendkeys:$avago_seq; wait:1; sendkeys:Enter; wait:3; force-refresh:$SESSION_DIR/S10_avago.png; sendkeys:$vdlist_seq; wait:1; sendkeys:Enter; wait:2; force-refresh:$SESSION_DIR/S10_verify.png" \
                > "$SESSION_DIR/S10_kvm.log" 2>&1 || true
            timeline "S10: verification screenshot at $SESSION_DIR/S10_verify.png"
        else
            timeline "S10: skipped verify nav (raid_setup vdlist_arrowdown not set); take manual screenshot"
        fi
        bmc_curl "https://$BMC_IP/redfish/v1/Systems/0/Storage" \
            > "$SESSION_DIR/S10_storage.json" 2>&1 || true
        mark_done S10
    }

    step_S1 || true
    step_S2 || true
    step_S3 || true
    step_S4 || true
    step_S5 || true
    step_S6 || true
    step_S7 || true
    step_S8 || true
    step_S9 || true
    step_S10 || true

    timeline "setup-raid10 done; review $SESSION_DIR"
    echo "Session dir: $SESSION_DIR"
    echo "Timeline:    $TIMELINE"
}

cmd_full_setup() {
    cmd_setup_bios --cycle
    echo
    echo "=== Polling for BIOS restore boot phase completion ==="
    # Find the latest BSPBRRestore task and wait for it.
    for i in $(seq 1 60); do
        sleep 5
        latest=$(bmc_curl "https://$BMC_IP/redfish/v1/TaskService/Tasks" \
            | grep -oE 'Tasks\\?/[0-9]+' | tail -1 | grep -oE '[0-9]+')
        [ -n "$latest" ] || continue
        state=$(bmc_curl "https://$BMC_IP/redfish/v1/TaskService/Tasks/$latest" \
            | grep '"TaskState"' | head -1)
        oem=$(bmc_curl "https://$BMC_IP/redfish/v1/TaskService/Tasks/$latest" \
            | grep 'StatusOEM' | head -1)
        echo "[$i x 5s] task /$latest $state | $oem"
        if echo "$state" | grep -qE 'Completed|Exception'; then break; fi
    done
    echo
    cmd_verify_bios
    echo
    cmd_setup_raid10
}

[ $# -lt 2 ] && usage
subcmd="$1"; shift
load_config "$1"; shift

case "$subcmd" in
    discover) cmd_discover "$@" ;;
    setup-bios) cmd_setup_bios "$@" ;;
    verify-bios) cmd_verify_bios "$@" ;;
    setup-raid10) cmd_setup_raid10 "$@" ;;
    full-setup) cmd_full_setup "$@" ;;
    *) usage ;;
esac
