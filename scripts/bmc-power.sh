#!/bin/sh
set -eu

usage() {
    echo "Usage: bmc-power.sh <command> <bmc_ip> <user> <pass> [args...]"
    echo ""
    echo "Commands:"
    echo "  status         <bmc_ip> <user> <pass>                Get power state"
    echo "  on             <bmc_ip> <user> <pass>                Power on"
    echo "  forceoff       <bmc_ip> <user> <pass>                Force power off"
    echo "  cycle          <bmc_ip> <user> <pass> [wait=15]      ForceOff + wait + On"
    echo "  boot-override  <bmc_ip> <user> <pass> <target> <mode>"
    echo "                   target: Cd, Pxe, Hdd, None"
    echo "                   mode: UEFI, Legacy"
    echo "  boot-next      <bmc_ip> <user> <pass> <boot_id>  Boot specific entry once (e.g. Boot0011)"
    echo "  find-boot-entry <bmc_ip> <user> <pass> <pattern>  Find Boot ID by DisplayName pattern"
    echo "  boot-override-reset <bmc_ip> <user> <pass>           Disable boot override"
    echo "  postcode      <bmc_ip> <user> <pass>                Get POST code (Supermicro)"
    exit 1
}

redfish_get() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    path="$4"

    curl -sk -u "${user}:${pass}" "https://${bmc_ip}${path}"
}

redfish_post() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    path="$4"
    data="$5"

    curl -sk -u "${user}:${pass}" \
        -X POST "https://${bmc_ip}${path}" \
        -H "Content-Type: application/json" \
        -d "$data"
}

redfish_patch() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    path="$4"
    data="$5"

    curl -sk -u "${user}:${pass}" \
        -X PATCH "https://${bmc_ip}${path}" \
        -H "Content-Type: application/json" \
        -d "$data"
}

get_system_path() {
    bmc_ip="$1"
    user="$2"
    pass="$3"

    members=$(redfish_get "$bmc_ip" "$user" "$pass" "/redfish/v1/Systems/")
    path=$(echo "$members" | sed -n 's/.*"@odata.id"[[:space:]]*:[[:space:]]*"\(\/redfish\/v1\/Systems\/[^"]*\)".*/\1/p' | head -1)

    if [ -z "$path" ]; then
        echo "/redfish/v1/Systems/1"
    else
        echo "$path"
    fi
}

cmd_status() {
    bmc_ip="$1"
    user="$2"
    pass="$3"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    result=$(redfish_get "$bmc_ip" "$user" "$pass" "$sys_path")
    power_state=$(echo "$result" | sed -n 's/.*"PowerState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$power_state" ]; then
        echo "ERROR: Could not get PowerState" >&2
        echo "$result" >&2
        exit 1
    fi

    echo "$power_state"
}

cmd_on() {
    bmc_ip="$1"
    user="$2"
    pass="$3"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    redfish_post "$bmc_ip" "$user" "$pass" \
        "${sys_path}/Actions/ComputerSystem.Reset" \
        '{"ResetType":"On"}'
    echo ""
    echo "Power On requested"
}

cmd_forceoff() {
    bmc_ip="$1"
    user="$2"
    pass="$3"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    redfish_post "$bmc_ip" "$user" "$pass" \
        "${sys_path}/Actions/ComputerSystem.Reset" \
        '{"ResetType":"ForceOff"}'
    echo ""
    echo "ForceOff requested"
}

cmd_cycle() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    wait_secs="${4:-15}"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")

    echo "ForceOff..."
    redfish_post "$bmc_ip" "$user" "$pass" \
        "${sys_path}/Actions/ComputerSystem.Reset" \
        '{"ResetType":"ForceOff"}'
    echo ""

    echo "Waiting ${wait_secs}s..."
    sleep "$wait_secs"

    echo "Power On..."
    redfish_post "$bmc_ip" "$user" "$pass" \
        "${sys_path}/Actions/ComputerSystem.Reset" \
        '{"ResetType":"On"}'
    echo ""
    echo "Power cycle complete"
}

cmd_boot_override() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    target="$4"
    mode="$5"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    data="{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"${target}\",\"BootSourceOverrideMode\":\"${mode}\"}}"

    redfish_patch "$bmc_ip" "$user" "$pass" "$sys_path" "$data"
    echo ""
    echo "Boot override set: target=$target mode=$mode (once)"
}

cmd_boot_next() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    boot_id="$4"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    data="{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"UefiBootNext\",\"BootSourceOverrideMode\":\"UEFI\",\"BootNext\":\"${boot_id}\"}}"

    redfish_patch "$bmc_ip" "$user" "$pass" "$sys_path" "$data"
    echo ""
    echo "BootNext set: $boot_id (once)"
}

cmd_boot_override_reset() {
    bmc_ip="$1"
    user="$2"
    pass="$3"

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")
    redfish_patch "$bmc_ip" "$user" "$pass" "$sys_path" \
        '{"Boot":{"BootSourceOverrideEnabled":"Disabled"}}'
    echo ""
    echo "Boot override disabled"
}

cmd_find_boot_entry() {
    bmc_ip="$1"
    user="$2"
    pass="$3"
    pattern="$4"
    max_retries=3
    retry_wait=15
    attempt=1

    sys_path=$(get_system_path "$bmc_ip" "$user" "$pass")

    while [ "$attempt" -le "$max_retries" ]; do
        members=$(redfish_get "$bmc_ip" "$user" "$pass" "${sys_path}/BootOptions")

        if command -v jq >/dev/null 2>&1; then
            urls=$(echo "$members" | jq -r '.Members[]."@odata.id"' 2>/dev/null)
        else
            urls=$(echo "$members" | sed -n 's/.*"@odata.id"[[:space:]]*:[[:space:]]*"\([^"]*BootOptions\/[^"]*\)".*/\1/p')
        fi

        if [ -n "$urls" ]; then
            for url in $urls; do
                entry=$(redfish_get "$bmc_ip" "$user" "$pass" "$url")
                if command -v jq >/dev/null 2>&1; then
                    display_name=$(echo "$entry" | jq -r '.DisplayName // empty' 2>/dev/null)
                    boot_id=$(echo "$entry" | jq -r '.Id // empty' 2>/dev/null)
                else
                    display_name=$(echo "$entry" | sed -n 's/.*"DisplayName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                    boot_id=$(echo "$entry" | sed -n 's/.*"Id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
                fi

                case "$display_name" in
                    *"$pattern"*)
                        echo "$boot_id"
                        return 0
                        ;;
                esac
            done
        fi

        if [ "$attempt" -lt "$max_retries" ]; then
            echo "Boot entry '$pattern' not found, retry $attempt/$max_retries in ${retry_wait}s..." >&2
            sleep "$retry_wait"
        fi
        attempt=$((attempt + 1))
    done

    echo "ERROR: No boot entry matching '$pattern' after $max_retries attempts" >&2
    exit 1
}

postcode_desc() {
    code="$1"
    case "$code" in
        "00") echo "POST complete or power off" ;;
        "01") echo "SEC: Power on, reset detected" ;;
        "02") echo "SEC: AP initialization" ;;
        "19") echo "PEI: SB pre-memory init" ;;
        "2B") echo "PEI: Memory initialization" ;;
        "34") echo "PEI: CPU post-memory init" ;;
        "4F") echo "DXE: DXE IPL started" ;;
        "60") echo "DXE: DXE core started" ;;
        "61") echo "DXE: NVRAM initialization" ;;
        "68") echo "DXE: PCI host bridge init" ;;
        "69") echo "DXE: CPU DXE init" ;;
        "6A") echo "DXE: IOH DXE init" ;;
        "70") echo "DXE: PCH DXE init" ;;
        "90") echo "BDS: Boot device selection start" ;;
        "91") echo "BDS: Driver connect" ;;
        "92") echo "BDS: PCI bus initialization" ;;
        "93") echo "BDS: PCI bus hot-plug" ;;
        "94") echo "BDS: PCI bus resource assign" ;;
        "95") echo "BDS: Console output connect" ;;
        "96") echo "BDS: Console input connect" ;;
        "97") echo "BDS: Super I/O initialization" ;;
        "98") echo "BDS: USB initialization start" ;;
        "9A") echo "BDS: USB initialization" ;;
        "9B") echo "BDS: USB detection" ;;
        "9C") echo "BDS: USB enable" ;;
        "9D") echo "BDS: SCSI initialization" ;;
        "A0") echo "BDS: IDE initialization" ;;
        "A1") echo "BDS: IDE reset" ;;
        "A2") echo "BDS: IDE detect" ;;
        "A3") echo "BDS: IDE enable" ;;
        "B2") echo "BDS: Legacy Option ROM init" ;;
        "B4") echo "BDS: USB Option ROM init" ;;
        "E0") echo "Boot: OS boot started" ;;
        "E1") echo "Boot: OS loader found" ;;
        "E4") echo "Boot: Boot to OS" ;;
        *) echo "Unknown POST code" ;;
    esac
}

cmd_postcode() {
    # NOTE: BMC may return stale POST code (e.g. 0x00 = "POST complete")
    # even while the server is stuck at POST 0x92 (PCI Bus Enumeration).
    # This is a BMC firmware limitation where the POST code register is
    # not updated during certain stall conditions.
    # Always combine with PowerState and SSH/ping reachability for
    # accurate stall detection. For definitive visual confirmation,
    # use KVM screenshot (bmc-kvm.sh screenshot).
    bmc_ip="$1"
    user="$2"
    pass="$3"

    raw=$(ipmitool -I lanplus -H "$bmc_ip" -U "$user" -P "$pass" raw 0x30 0x70 0x02 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: Failed to get POST code (rc=$rc)" >&2
        echo "$raw" >&2
        exit 1
    fi

    code=$(echo "$raw" | tr -d ' \n' | tr 'a-f' 'A-F')
    if [ -z "$code" ]; then
        echo "ERROR: Empty POST code response" >&2
        exit 1
    fi

    desc=$(postcode_desc "$code")
    echo "0x${code} ${desc}"
}

if [ $# -lt 1 ]; then
    usage
fi

command="$1"; shift

case "$command" in
    status)
        if [ $# -lt 3 ]; then usage; fi
        cmd_status "$1" "$2" "$3"
        ;;
    on)
        if [ $# -lt 3 ]; then usage; fi
        cmd_on "$1" "$2" "$3"
        ;;
    forceoff)
        if [ $# -lt 3 ]; then usage; fi
        cmd_forceoff "$1" "$2" "$3"
        ;;
    cycle)
        if [ $# -lt 3 ]; then usage; fi
        cmd_cycle "$1" "$2" "$3" "${4:-15}"
        ;;
    boot-override)
        if [ $# -lt 5 ]; then usage; fi
        cmd_boot_override "$1" "$2" "$3" "$4" "$5"
        ;;
    boot-next)
        if [ $# -lt 4 ]; then usage; fi
        cmd_boot_next "$1" "$2" "$3" "$4"
        ;;
    find-boot-entry)
        if [ $# -lt 4 ]; then usage; fi
        cmd_find_boot_entry "$1" "$2" "$3" "$4"
        ;;
    boot-override-reset)
        if [ $# -lt 3 ]; then usage; fi
        cmd_boot_override_reset "$1" "$2" "$3"
        ;;
    postcode)
        if [ $# -lt 3 ]; then usage; fi
        cmd_postcode "$1" "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
