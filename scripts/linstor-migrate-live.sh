#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"

usage() {
    echo "Usage: linstor-migrate-live.sh <vmid> <target_node> [<config>]"
    echo ""
    echo "  Live-migrate a VM within the same LINSTOR region."
    echo ""
    echo "  Prerequisites:"
    echo "    - Source and target nodes must be in the same region (Protocol C)"
    echo "    - Both nodes must have the resource UpToDate"
    echo "    - VM must be running"
    echo ""
    echo "  Note: Wrap with pve-lock.sh and oplog.sh at call site."
    echo "  Example: ./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-live.sh 200 ayase-web-service-7"
    echo ""
    echo "  <vmid>         VM ID"
    echo "  <target_node>  Target PVE/LINSTOR node name"
    echo "  <config>       Path to linstor.yml (default: config/linstor.yml)"
    exit 2
}

if [ $# -lt 2 ]; then
    usage
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

VMID="$1"
TARGET_NODE="$2"
CONFIG="${3:-config/linstor.yml}"

if [ ! -f "$CONFIG" ]; then
    echo "Error: config file not found: $CONFIG"
    exit 1
fi

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")

run_linstor() {
    ssh "root@${CONTROLLER_IP}" "linstor $*"
}

get_node_ip() {
    "$YQ" ".nodes[] | select(.name == \"$1\") | .ip" "$CONFIG"
}

get_node_site() {
    node="$1"
    for region in $("$YQ" '.regions | keys | .[]' "$CONFIG"); do
        for n in $("$YQ" ".regions.\"$region\"[]" "$CONFIG"); do
            if [ "$n" = "$node" ]; then
                echo "$region"
                return
            fi
        done
    done
}

echo "=== Live Migration: VM $VMID -> $TARGET_NODE ==="
echo ""

echo "--- Pre-flight checks ---"

resource_json=$(run_linstor "-m resource list")

source_node=$(echo "$resource_json" | "$YQ" -r ".[0][] | select(.state.in_use == true) | .node_name" | head -1)
if [ -z "$source_node" ]; then
    echo "Error: cannot determine source node (no InUse resource found)"
    exit 1
fi
SOURCE_IP=$(get_node_ip "$source_node")

scsi0_line=$(ssh "root@${SOURCE_IP}" "qm config $VMID" | grep '^scsi0:')
if [ -z "$scsi0_line" ]; then
    echo "Error: VM $VMID has no scsi0 disk on $source_node"
    exit 1
fi

pve_vol=$(echo "$scsi0_line" | sed 's/^scsi0: *//' | sed 's/,.*//')
base_resource=$(echo "$pve_vol" | sed "s/^linstor-storage://" | sed "s/_${VMID}$//")
resource_name="${pve_vol#linstor-storage:}"
echo "  Resource: $resource_name (base: $base_resource)"
echo "  Source: $source_node ($SOURCE_IP)"

source_site=$(get_node_site "$source_node")
target_site=$(get_node_site "$TARGET_NODE")
echo "  Source site: $source_site"
echo "  Target site: $target_site"

if [ "$source_site" != "$target_site" ]; then
    echo "Error: source ($source_site) and target ($target_site) are in different regions."
    echo "  Use cold migration for cross-region migration."
    exit 1
fi

target_state=$(echo "$resource_json" | "$YQ" -r ".[0][] | select(.name == \"$base_resource\" and .node_name == \"$TARGET_NODE\") | .volumes[0].state.disk_state")
if [ -z "$target_state" ]; then
    echo "Error: resource $base_resource not found on target node $TARGET_NODE"
    exit 1
fi
if [ "$target_state" != "UpToDate" ]; then
    echo "Error: resource on $TARGET_NODE is $target_state (expected UpToDate)"
    exit 1
fi
echo "  Target resource state: $target_state (OK)"

vm_status=$(ssh "root@${SOURCE_IP}" "qm status $VMID")
echo "  VM status: $vm_status"

case "$vm_status" in
    *running*)
        ;;
    *)
        echo "Error: VM $VMID is not running (status: $vm_status)"
        exit 1
        ;;
esac

echo ""
echo "--- Executing live migration ---"
echo "  qm migrate $VMID $TARGET_NODE --online"

ssh "root@${SOURCE_IP}" "qm migrate $VMID $TARGET_NODE --online"

echo ""
echo "--- Post-migration verification ---"

TARGET_IP=$(get_node_ip "$TARGET_NODE")
vm_status_after=$(ssh "root@${TARGET_IP}" "qm status $VMID")
echo "  VM status on $TARGET_NODE: $vm_status_after"

resource_json_after=$(run_linstor "-m resource list -r $base_resource")
for node in $(echo "$resource_json_after" | "$YQ" -r '.[0][].node_name'); do
    state=$(echo "$resource_json_after" | "$YQ" -r ".[0][] | select(.node_name == \"$node\") | .volumes[0].state.disk_state")
    in_use=$(echo "$resource_json_after" | "$YQ" -r ".[0][] | select(.node_name == \"$node\") | .state.in_use")
    echo "  $node: $state (in_use=$in_use)"
done

echo ""
echo "Live migration complete."
