#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
YQ="${PROJECT_DIR}/bin/yq"

usage() {
    echo "Usage: generate-preseed.sh [--with-raid10-storcli] [--pxe[=BASE_URL]] <config.yml> [output_file]"
    echo ""
    echo "Generate preseed.cfg from template using config values."
    echo "If output_file is omitted, writes to stdout."
    echo ""
    echo "Options:"
    echo "  --with-raid10-storcli  Insert partman/early_command to run"
    echo "                         /cdrom/setup-raid10-storcli.sh before partitioning."
    echo "                         Requires the ISO to bundle setup-raid10-storcli.sh"
    echo "                         and storcli64.deb (see scripts/remaster-debian-iso.sh)."
    echo "  --pxe[=BASE_URL]       Generate preseed for PXE/netboot delivery."
    echo "                         RAID10 storcli is fetched over HTTP from BASE_URL/firmware/"
    echo "                         instead of /cdrom/. BASE_URL defaults to http://10.1.6.6."
    echo "                         Implies --with-raid10-storcli (HTTP variant)."
    exit 1
}

WITH_RAID10_STORCLI=0
PXE_MODE=0
PXE_BASE_URL="http://10.1.6.6"
POSITIONAL=""
for arg in "$@"; do
    case "$arg" in
        --with-raid10-storcli) WITH_RAID10_STORCLI=1 ;;
        --pxe) PXE_MODE=1; WITH_RAID10_STORCLI=1 ;;
        --pxe=*) PXE_MODE=1; WITH_RAID10_STORCLI=1; PXE_BASE_URL="${arg#--pxe=}" ;;
        -h|--help) usage ;;
        *) POSITIONAL="${POSITIONAL:+$POSITIONAL }$arg" ;;
    esac
done
# shellcheck disable=SC2086
set -- $POSITIONAL

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
# network_mode: "static" (default) writes a fixed address onto static_iface;
# "dhcp" leaves static_iface on DHCP so the installed host obtains a routable
# lease on whichever segment its LAN port is wired to. Used by hosts on
# NAT'd/multi-segment LANs (e.g. training-tx1320) where a hard-coded address
# would land on the wrong physical segment and be unreachable.
network_mode=$("$YQ" '.network_mode' "$CONFIG")
[ "$network_mode" = "null" ] || [ -z "$network_mode" ] && network_mode="static"
# Optional second NIC to bring up via DHCP (allow-hotplug) in dhcp mode.
dhcp_secondary_iface=$("$YQ" '.dhcp_secondary_iface' "$CONFIG")
[ "$dhcp_secondary_iface" = "null" ] && dhcp_secondary_iface=""

# Optional Linux-bridge layout for the installed system (PVE). When bridge_setup
# is true (dhcp mode only), the late_command writes vmbr0/vmbr1 bridges instead
# of flat NICs: vmbr0 = static_iface (DHCP), vmbr1 = dhcp_secondary_iface. vmbr1
# uses secondary_bridge_address (CIDR) when set, else DHCP. bridge-utils is added
# to pkgsel so the bridges come up at first boot before ifupdown2 (from PVE).
bridge_setup=$("$YQ" '.bridge_setup // false' "$CONFIG")
[ "$bridge_setup" = "null" ] && bridge_setup="false"
secondary_bridge_address=$("$YQ" '.secondary_bridge_address // ""' "$CONFIG")
[ "$secondary_bridge_address" = "null" ] && secondary_bridge_address=""

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

# Serial console unit: defaults to 1 (ttyS1) for backwards compatibility with
# Supermicro X11DPU / X10DRT-P. Override via config `serial_unit:` for iDRAC
# (typically 0 / ttyS0) and Fujitsu iRMC (0 / ttyS0 on TX1320 M3).
serial_unit=$("$YQ" '.serial_unit' "$CONFIG")
[ "$serial_unit" = "null" ] || [ -z "$serial_unit" ] && serial_unit=1
console_order="console=ttyS${serial_unit},115200n8"

if [ "$PXE_MODE" = "1" ]; then
    # PXE/HTTP variant: fetch storcli binary + setup script from HTTP and
    # invoke. d-i busybox initramfs has wget (HTTP only, no HTTPS — no
    # ca-certificates).
    partman_early_command="d-i partman/early_command string \\
  echo \"pvese: partman/early_command start (PXE HTTP fetch)\" > /dev/kmsg 2>/dev/null || true; \\
  wget -q -O /tmp/storcli64.bin ${PXE_BASE_URL}/firmware/storcli64.bin; \\
  WR=\$?; \\
  echo \"pvese: wget storcli64.bin rc=\$WR\" > /dev/kmsg 2>/dev/null || true; \\
  wget -q -O /tmp/setup-raid10-storcli.sh ${PXE_BASE_URL}/firmware/setup-raid10-storcli.sh; \\
  WR=\$?; \\
  echo \"pvese: wget setup-raid10-storcli.sh rc=\$WR\" > /dev/kmsg 2>/dev/null || true; \\
  chmod +x /tmp/setup-raid10-storcli.sh; \\
  sh /tmp/setup-raid10-storcli.sh /tmp/storcli64.bin > /tmp/raid10-stdout.log 2> /tmp/raid10-stderr.log; \\
  RC=\$?; \\
  echo \"pvese: partman/early_command end (rc=\$RC)\" > /dev/kmsg 2>/dev/null || true; \\
  head -5 /tmp/raid10-stderr.log 2>/dev/null | tr '\\n' '|' > /dev/kmsg; \\
  head -5 /tmp/raid10-stdout.log 2>/dev/null | tr '\\n' '|' > /dev/kmsg"
elif [ "$WITH_RAID10_STORCLI" = "1" ]; then
    partman_early_command="d-i partman/early_command string \\
  echo \"pvese: partman/early_command start\" > /dev/kmsg 2>/dev/null || true; \\
  for p in /cdrom /media/cdrom /media/cdrom0 /hd-media; do \\
    if [ -f \"\$p/setup-raid10-storcli.sh\" ]; then \\
      echo \"pvese: found setup-raid10-storcli.sh at \$p\" > /dev/kmsg 2>/dev/null || true; \\
      echo \"pvese: test sh \$( which sh ) -- date= \$( which date ) -- tee= \$( which tee )\" > /dev/kmsg 2>/dev/null || true; \\
      sh \"\$p/setup-raid10-storcli.sh\" \"\$p/storcli64.bin\" > /tmp/raid10-stdout.log 2> /tmp/raid10-stderr.log; \\
      RC=\$?; \\
      echo \"pvese: partman/early_command end (rc=\$RC)\" > /dev/kmsg 2>/dev/null || true; \\
      head -5 /tmp/raid10-stderr.log 2>/dev/null | tr '\\n' '|' > /dev/kmsg; \\
      head -5 /tmp/raid10-stdout.log 2>/dev/null | tr '\\n' '|' > /dev/kmsg; \\
      break; \\
    fi; \\
  done"
else
    partman_early_command=""
fi

SSH_PUBKEY_FILE="${PROJECT_DIR}/ssh/id_ed25519.pub"
if [ -f "$SSH_PUBKEY_FILE" ]; then
    ssh_public_key=$(cat "$SSH_PUBKEY_FILE" | tr -d '\n')
else
    echo "WARNING: SSH public key not found at: $SSH_PUBKEY_FILE" >&2
    ssh_public_key=""
fi

# VLAN-aware vs legacy expansions for the template placeholders.
# - VLAN host (server10-13): overwrite /target/etc/network/interfaces from
#   late_command with a fresh definition (lo + physical NIC manual +
#   internet/internal VLAN subinterfaces). VLAN trunk hosts cannot use d-i
#   network configuration because the stock initrd lacks the 8021q kernel
#   module, so we install CD-only and bring the VLAN bridge up at first boot
#   via late_command + /etc/modules.
# - Non-VLAN host (server4-6): the box has TWO usable NICs — eno1np0 on
#   vmbr1 (192.168.39.0/24 DHCP, internet-capable) and eno2np1 on vmbr0
#   (10.10.10.0/8 mgmt static, no internet). Let d-i auto-detect the
#   internet-facing NIC (`choose_interface=auto` picks the carrier with
#   DHCP), enable the apt mirror so the standard task installs cleanly, and
#   write the mgmt static IP onto eno2np1 from late_command so SSH on
#   10.10.10.x is available at first boot.
#
# Background on the 2026-05-14 regression
# (report/2026-05-14_091100_os_setup_18trial_x10dpu_r320.md):
# Previously the non-VLAN branch forced choose_interface=$static_iface (mgmt
# NIC, no internet) and apt_use_mirror=false (CD-only). On x10dpu hosts this
# left the installer trying to reach deb.debian.org over the mgmt VLAN and
# hanging in choose-mirror for 20+ minutes. The recovery path was a manual
# edit of every preseed-generated-s{4,5,6}.cfg to auto / true / false / true,
# which got blown away whenever generate-preseed.sh was re-run.
#
# choose_interface / vlan_setup_cmd are unused once early VLAN setup was
# abandoned, but preseed.cfg.template still references them — keep the
# placeholder values in sync.
vlan_setup_cmd=":"
NWFILE='/target/etc/network/interfaces'

if [ -n "$vlan_iface" ] && [ -n "$internet_vlan_id" ] && [ -n "$internal_vlan_id" ]; then
    choose_interface="$vlan_iface"
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
    # Non-VLAN, dual-NIC mgmt host (server4-6): auto-detect the internet-
    # facing NIC and use the apt mirror for a full standard install.
    # When a dhcp_secondary_iface is set (training-tx1320: eno1=site LAN,
    # eno2=dark-net), pin netcfg to the primary NIC instead of "auto" so the
    # installer ignores the second NIC's link-up and avoids the dual-NIC IPv6
    # autoconfig timeout / DNS-dialog stall (#15). For the PXE path the kernel
    # cmdline interface= is the actual lever (preseed is fetched after netcfg);
    # this keeps the preseed value consistent and also fixes the virtual-media
    # path where the preseed is local and read before netcfg.
    if [ -n "$dhcp_secondary_iface" ]; then
        choose_interface="$static_iface"
    else
        choose_interface="auto"
    fi
    netcfg_disable_autoconfig="false"
    apt_use_mirror="true"
    apt_no_mirror="false"
    tasksel_first="standard"
    pkgsel_include="openssh-server sudo curl wget gnupg"
    pkgsel_upgrade="none"
    # The mgmt static IP must end up on $static_iface (eno2np1 on X11DPU) so
    # that SSH on 10.10.10.x is reachable at first boot. d-i netcfg only wrote
    # config for the DHCP-up interface it auto-picked, so we OVERWRITE the
    # whole interfaces file with our own definition (lo + the NIC blocks below).
    if [ "$network_mode" = "dhcp" ] && [ "$bridge_setup" = "true" ]; then
        # PVE bridge layout (training-tx1320): vmbr0 bridges the primary NIC
        # (site LAN, DHCP) and vmbr1 bridges the secondary NIC (dark-net). vmbr1
        # uses a STATIC address when secondary_bridge_address is set, so the box
        # is reachable at a stable IP from first disk boot (no DHCP-lease drift,
        # memory #12). The bridges must come up before PVE installs ifupdown2,
        # so bridge-utils is pulled in via pkgsel for the first-boot ifupdown.
        pkgsel_include="$pkgsel_include bridge-utils"
        late_network="echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'iface ${static_iface} inet manual' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto vmbr0' >> ${NWFILE}; \
echo 'iface vmbr0 inet dhcp' >> ${NWFILE}; \
echo '    bridge-ports ${static_iface}' >> ${NWFILE}; \
echo '    bridge-stp off' >> ${NWFILE}; \
echo '    bridge-fd 0' >> ${NWFILE};"
        if [ -n "$dhcp_secondary_iface" ]; then
            late_network="${late_network} \
echo '' >> ${NWFILE}; \
echo 'iface ${dhcp_secondary_iface} inet manual' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto vmbr1' >> ${NWFILE};"
            if [ -n "$secondary_bridge_address" ]; then
                late_network="${late_network} \
echo 'iface vmbr1 inet static' >> ${NWFILE}; \
echo '    address ${secondary_bridge_address}' >> ${NWFILE}; \
echo '    bridge-ports ${dhcp_secondary_iface}' >> ${NWFILE}; \
echo '    bridge-stp off' >> ${NWFILE}; \
echo '    bridge-fd 0' >> ${NWFILE};"
            else
                late_network="${late_network} \
echo 'iface vmbr1 inet dhcp' >> ${NWFILE}; \
echo '    bridge-ports ${dhcp_secondary_iface}' >> ${NWFILE}; \
echo '    bridge-stp off' >> ${NWFILE}; \
echo '    bridge-fd 0' >> ${NWFILE};"
            fi
        fi
        if [ "$PXE_MODE" = "1" ]; then
            # First-boot phone-home (same as the flat-dhcp branch): report the
            # obtained IPs to the playground. Non-critical here (vmbr1 is a known
            # static address) but kept for parity with the PXE deploy flow.
            # Avoid '&' in this value (awk esc() limitation, see flat branch).
            late_network="${late_network} \
in-target sh -c 'wget -q -O /tmp/phonehome-setup.sh ${PXE_BASE_URL}/firmware/phonehome-setup.sh; sh /tmp/phonehome-setup.sh' || true;"
        fi
    elif [ "$network_mode" = "dhcp" ]; then
        late_network="echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${static_iface}' >> ${NWFILE}; \
echo 'iface ${static_iface} inet dhcp' >> ${NWFILE};"
        if [ -n "$dhcp_secondary_iface" ]; then
            # auto (brought up unconditionally at boot): allow-hotplug waits for
            # a carrier link-up EVENT, which never fires if the cable is already
            # connected at boot — that left the dark-net port without a lease for
            # 15+ min (#14). This port (e.g. training-tx1320 eno2) is always
            # cabled to the dark-net, so 'auto' obtains its DHCP lease at boot
            # with no event dependency. (Use only for ports known to be wired;
            # a dead 'auto' port would block ifupdown for the DHCP timeout.)
            late_network="${late_network} \
echo '' >> ${NWFILE}; \
echo 'auto ${dhcp_secondary_iface}' >> ${NWFILE}; \
echo 'iface ${dhcp_secondary_iface} inet dhcp' >> ${NWFILE};"
        fi
        if [ "$PXE_MODE" = "1" ]; then
            # First-boot phone-home: report obtained IPs to the playground HTTP
            # server so the remote operator can discover the reachable lease.
            # NOTE: use ';' not '&&' to chain the two commands. The awk esc()
            # below does not correctly escape '&', so a literal '&&' here is
            # interpreted by the outer gsub as the matched text and corrupts the
            # phonehome line (it became "%%LATE_NETWORK%%%%LATE_NETWORK%%"), so
            # the setup script was fetched but never executed. With ';' the
            # script always runs in-target; a missing/empty file (wget failed)
            # makes 'sh' a harmless no-op, and the trailing '|| true' keeps the
            # late_command non-blocking. Avoid '&' in any late_network value.
            late_network="${late_network} \
in-target sh -c 'wget -q -O /tmp/phonehome-setup.sh ${PXE_BASE_URL}/firmware/phonehome-setup.sh; sh /tmp/phonehome-setup.sh' || true;"
        fi
    else
        late_network="echo 'source /etc/network/interfaces.d/*' > ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto lo' >> ${NWFILE}; \
echo 'iface lo inet loopback' >> ${NWFILE}; \
echo '' >> ${NWFILE}; \
echo 'auto ${static_iface}' >> ${NWFILE}; \
echo 'iface ${static_iface} inet static' >> ${NWFILE}; \
echo '    address ${static_ip}/${static_netmask}' >> ${NWFILE};"
    fi
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
    PV_PARTMAN_EARLY_COMMAND="$partman_early_command" \
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
    gsub(/%%PARTMAN_EARLY_COMMAND%%/,    esc(ENVIRON["PV_PARTMAN_EARLY_COMMAND"]));
    print;
}' "$TEMPLATE")

if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$result" > "$OUTPUT"
    echo "Generated: $OUTPUT"
else
    printf '%s\n' "$result"
fi
