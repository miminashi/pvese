#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"

usage() {
    echo "Usage: generate-preseed.sh <config.yml> [output_file]"
    echo ""
    echo "Generate preseed.cfg from template using config values."
    echo "If output_file is omitted, writes to stdout."
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

CONFIG="$1"
OUTPUT="${2:-}"
TEMPLATE="${PROJECT_DIR}/preseed/preseed.cfg.template"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file not found: $CONFIG" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE" >&2
    exit 1
fi

if [ ! -x "$YQ" ]; then
    echo "ERROR: yq not found at: $YQ" >&2
    exit 1
fi

hostname=$("$YQ" '.hostname' "$CONFIG")
domain=$("$YQ" '.domain' "$CONFIG")
disk=$("$YQ" '.disk' "$CONFIG")
root_password=$("$YQ" '.root_password' "$CONFIG")
user_name=$("$YQ" '.user_name' "$CONFIG")
user_password=$("$YQ" '.user_password' "$CONFIG")
static_ip=$("$YQ" '.static_ip' "$CONFIG")
static_netmask=$("$YQ" '.static_netmask' "$CONFIG")
static_iface=$("$YQ" '.static_iface' "$CONFIG")

# Optional explicit gateway (defaults to the standard 10.0.0.0/8 GW). Used
# only by the netcfg static-IP fallback prompt; the actual gateway routing
# comes from DHCP on the internet VLAN at runtime.
static_gateway=$("$YQ" '.static_gateway' "$CONFIG")
[ "$static_gateway" = "null" ] && static_gateway="10.10.10.1"

# CIDR prefix → dotted-quad netmask for d-i netcfg/get_netmask.
case "$static_netmask" in
    8)  static_netmask_octet="255.0.0.0" ;;
    16) static_netmask_octet="255.255.0.0" ;;
    24) static_netmask_octet="255.255.255.0" ;;
    *)  static_netmask_octet="255.0.0.0" ;;  # safe default for /8 mgmt nets
esac

# Optional VLAN trunk fields. yq prints "null" for missing keys; treat as unset.
vlan_iface=$("$YQ" '.vlan_iface' "$CONFIG")
internet_vlan_id=$("$YQ" '.internet_vlan_id' "$CONFIG")
internal_vlan_id=$("$YQ" '.internal_vlan_id' "$CONFIG")
[ "$vlan_iface" = "null" ] && vlan_iface=""
[ "$internet_vlan_id" = "null" ] && internet_vlan_id=""
[ "$internal_vlan_id" = "null" ] && internal_vlan_id=""

console_order="console=tty0 console=ttyS1,115200n8"

SSH_PUBKEY_FILE="${PROJECT_DIR}/ssh/id_ed25519.pub"
if [ -f "$SSH_PUBKEY_FILE" ]; then
    ssh_public_key=$(cat "$SSH_PUBKEY_FILE" | tr -d '\n')
else
    echo "WARNING: SSH public key not found at: $SSH_PUBKEY_FILE" >&2
    ssh_public_key=""
fi

# VLAN-aware vs legacy expansions for the template placeholders.
# - VLAN host: overwrite /target/etc/network/interfaces from late_command with
#   a fresh definition (lo + physical NIC manual + internet/internal VLAN
#   subinterfaces). The overwrite is mandatory: d-i netcfg writes
#   `iface <phy> inet static` from netcfg/get_ipaddress, and if late_command
#   only appended the VLAN block the static IP would end up on both the
#   untagged NIC and the VLAN sub — duplicate addresses break SSH on first
#   boot (see report/2026-05-02_060639_server10_disk_first_boot_recovery.md
#   Phase 6).
# - Non-VLAN host: keep the original append behaviour (auto choose, single
#   static line) so 4-9号機 generators stay byte-identical apart from the
#   early_command + syslog-forward block (harmless on those hosts).
# VLAN trunk hosts (10号機) cannot use d-i network configuration because the
# stock initrd lacks the 8021q kernel module, so we install CD-only and bring
# the VLAN bridge up at first boot via late_command + /etc/modules.
#
# choose_interface / vlan_setup_cmd are unused once early VLAN setup was
# abandoned, but preseed.cfg.template still references them — keep the
# placeholder values in sync.
choose_interface="auto"
vlan_setup_cmd=":"
NWFILE='/target/etc/network/interfaces'

if [ -n "$vlan_iface" ] && [ -n "$internet_vlan_id" ] && [ -n "$internal_vlan_id" ]; then
    netcfg_disable_autoconfig="true"
    apt_use_mirror="false"
    apt_no_mirror="true"
    tasksel_first=""                       # no task installs from CD
    pkgsel_include="openssh-server"        # only what's needed for SSH access
    pkgsel_upgrade="none"                  # no upgrades during install (no apt mirror)
    late_network="echo 8021q >> /target/etc/modules; \
echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}' >> ${NWFILE}; \
echo 'iface ${vlan_iface} inet manual' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}.${internet_vlan_id}' >> ${NWFILE}; \
echo 'iface ${vlan_iface}.${internet_vlan_id} inet dhcp' >> ${NWFILE}; \
echo '    vlan-raw-device ${vlan_iface}' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${vlan_iface}.${internal_vlan_id}' >> ${NWFILE}; \
echo 'iface ${vlan_iface}.${internal_vlan_id} inet static' >> ${NWFILE}; \
echo '    address ${static_ip}/${static_netmask}' >> ${NWFILE}; \
echo '    vlan-raw-device ${vlan_iface}' >> ${NWFILE};"
else
    netcfg_disable_autoconfig="false"
    apt_use_mirror="true"
    apt_no_mirror="false"
    tasksel_first="standard"
    pkgsel_include="openssh-server sudo curl wget gnupg"
    pkgsel_upgrade="full-upgrade"
    late_network="echo '' >> ${NWFILE}; \
echo 'auto ${static_iface}' >> ${NWFILE}; \
echo 'iface ${static_iface} inet static' >> ${NWFILE}; \
echo '    address ${static_ip}/${static_netmask}' >> ${NWFILE};"
fi

# Pass values via ENVIRON[] so awk does NOT interpret backslash escapes
# (literal `\n` in vlan_setup_cmd / late_network must reach the preseed
# unchanged, since printf inside in-target sh expands them at install time).
# Note: awk's gsub treats `&` and `\\` specially in the replacement; collapse
# the few we emit by using a function that escapes them.
result=$(
    PV_HOSTNAME="$hostname" PV_DOMAIN="$domain" PV_DISK="$disk" \
    PV_ROOT_PASSWORD="$root_password" PV_USER_NAME="$user_name" \
    PV_USER_PASSWORD="$user_password" PV_CONSOLE_ORDER="$console_order" \
    PV_SSH_PUBLIC_KEY="$ssh_public_key" PV_STATIC_IP="$static_ip" \
    PV_STATIC_NETMASK="$static_netmask" PV_STATIC_IFACE="$static_iface" \
    PV_CHOOSE_INTERFACE="$choose_interface" \
    PV_VLAN_SETUP_CMD="$vlan_setup_cmd" PV_LATE_NETWORK="$late_network" \
    PV_NETCFG_DISABLE_AUTOCONFIG="$netcfg_disable_autoconfig" \
    PV_APT_USE_MIRROR="$apt_use_mirror" PV_APT_NO_MIRROR="$apt_no_mirror" \
    PV_STATIC_NETMASK_OCTET="$static_netmask_octet" \
    PV_STATIC_GATEWAY="$static_gateway" \
    PV_TASKSEL_FIRST="$tasksel_first" \
    PV_PKGSEL_INCLUDE="$pkgsel_include" \
    PV_PKGSEL_UPGRADE="$pkgsel_upgrade" \
    awk '
# All replacement values are pure ASCII text (no backslashes), so escape is
# only needed for awk gsub replacement metacharacters & and \.
function esc(s) {
    gsub(/&/, "\\&", s);
    return s;
}
{
    gsub(/%%HOSTNAME%%/,         esc(ENVIRON["PV_HOSTNAME"]));
    gsub(/%%DOMAIN%%/,           esc(ENVIRON["PV_DOMAIN"]));
    gsub(/%%DISK%%/,             esc(ENVIRON["PV_DISK"]));
    gsub(/%%ROOT_PASSWORD%%/,    esc(ENVIRON["PV_ROOT_PASSWORD"]));
    gsub(/%%USER_NAME%%/,        esc(ENVIRON["PV_USER_NAME"]));
    gsub(/%%USER_PASSWORD%%/,    esc(ENVIRON["PV_USER_PASSWORD"]));
    gsub(/%%CONSOLE_ORDER%%/,    esc(ENVIRON["PV_CONSOLE_ORDER"]));
    gsub(/%%SSH_PUBLIC_KEY%%/,   esc(ENVIRON["PV_SSH_PUBLIC_KEY"]));
    gsub(/%%STATIC_IP%%/,        esc(ENVIRON["PV_STATIC_IP"]));
    gsub(/%%STATIC_NETMASK%%/,   esc(ENVIRON["PV_STATIC_NETMASK"]));
    gsub(/%%STATIC_IFACE%%/,     esc(ENVIRON["PV_STATIC_IFACE"]));
    gsub(/%%CHOOSE_INTERFACE%%/,         esc(ENVIRON["PV_CHOOSE_INTERFACE"]));
    gsub(/%%VLAN_SETUP_CMD%%/,           esc(ENVIRON["PV_VLAN_SETUP_CMD"]));
    gsub(/%%LATE_NETWORK%%/,             esc(ENVIRON["PV_LATE_NETWORK"]));
    gsub(/%%NETCFG_DISABLE_AUTOCONFIG%%/, esc(ENVIRON["PV_NETCFG_DISABLE_AUTOCONFIG"]));
    gsub(/%%APT_USE_MIRROR%%/,           esc(ENVIRON["PV_APT_USE_MIRROR"]));
    gsub(/%%APT_NO_MIRROR%%/,            esc(ENVIRON["PV_APT_NO_MIRROR"]));
    gsub(/%%STATIC_NETMASK_OCTET%%/,     esc(ENVIRON["PV_STATIC_NETMASK_OCTET"]));
    gsub(/%%STATIC_GATEWAY%%/,           esc(ENVIRON["PV_STATIC_GATEWAY"]));
    gsub(/%%TASKSEL_FIRST%%/,            esc(ENVIRON["PV_TASKSEL_FIRST"]));
    gsub(/%%PKGSEL_INCLUDE%%/,           esc(ENVIRON["PV_PKGSEL_INCLUDE"]));
    gsub(/%%PKGSEL_UPGRADE%%/,           esc(ENVIRON["PV_PKGSEL_UPGRADE"]));
    print;
}' "$TEMPLATE")

if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$result" > "$OUTPUT"
    echo "Generated: $OUTPUT"
else
    printf '%s\n' "$result"
fi
