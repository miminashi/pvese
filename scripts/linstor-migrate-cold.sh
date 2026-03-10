#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"

usage() {
    echo "Usage: linstor-migrate-cold.sh <vmid> <source_region> <target_region> [<config>]"
    echo ""
    echo "  Cold-migrate a VM between LINSTOR regions."
    echo ""
    echo "  This script performs:"
    echo "    Phase 1: Ensure 2 replicas in target region + sync"
    echo "    Phase 2: Stop VM, move config, start on target"
    echo "    Phase 3: Set up DR replica in source region"
    echo ""
    echo "  Note: Wrap with pve-lock.sh and oplog.sh at call site."
    echo "  Example: ./pve-lock.sh run ./oplog.sh ./scripts/linstor-migrate-cold.sh 200 region-b region-a"
    echo ""
    echo "  <vmid>            VM ID"
    echo "  <source_region>   Source region name (e.g. region-b)"
    echo "  <target_region>   Target region name (e.g. region-a)"
    echo "  <config>          Path to linstor.yml (default: config/linstor.yml)"
    exit 2
}

if [ $# -lt 3 ]; then
    usage
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

VMID="$1"
SOURCE_REGION="$2"
TARGET_REGION="$3"
CONFIG="${4:-config/linstor.yml}"

if [ ! -f "$CONFIG" ]; then
    echo "Error: config file not found: $CONFIG"
    exit 1
fi

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")
CROSS_REGION_IF=$("$YQ" '.migration.cross_region_interface // "default"' "$CONFIG")

run_linstor() {
    ssh "root@${CONTROLLER_IP}" "linstor $*"
}

get_node_ip() {
    "$YQ" ".nodes[] | select(.name == \"$1\") | .ip" "$CONFIG"
}

get_region_nodes() {
    "$YQ" ".regions.\"$1\"[]" "$CONFIG"
}

node_exists_in_linstor() {
    run_linstor "node list -n $1" 2>/dev/null | grep -q "$1"
}

filter_linstor_nodes() {
    for node in $1; do
        if node_exists_in_linstor "$node"; then
            echo "$node"
        else
            echo "  WARNING: $node not in LINSTOR, skipping" >&2
        fi
    done
}

echo "=== Cold Migration: VM $VMID from $SOURCE_REGION to $TARGET_REGION ==="
echo ""

source_nodes=$(filter_linstor_nodes "$(get_region_nodes "$SOURCE_REGION")")
target_nodes=$(filter_linstor_nodes "$(get_region_nodes "$TARGET_REGION")")

if [ -z "$source_nodes" ]; then
    echo "Error: no nodes found in source region $SOURCE_REGION"
    exit 1
fi
if [ -z "$target_nodes" ]; then
    echo "Error: no nodes found in target region $TARGET_REGION"
    exit 1
fi

echo "  Source region nodes: $source_nodes"
echo "  Target region nodes: $target_nodes"

resource_json=$(run_linstor "-m resource list")

source_node_primary=""
for node in $source_nodes; do
    in_use=$(echo "$resource_json" | "$YQ" -r ".[0][] | select(.node_name == \"$node\" and .state.in_use == true) | .name" | head -1)
    if [ -n "$in_use" ]; then
        source_node_primary="$node"
        break
    fi
done
if [ -z "$source_node_primary" ]; then
    for node in $source_nodes; do
        has=$(echo "$resource_json" | "$YQ" -r ".[0][] | select(.node_name == \"$node\") | .name" | head -1)
        if [ -n "$has" ]; then
            source_node_primary="$node"
            break
        fi
    done
fi
if [ -z "$source_node_primary" ]; then
    echo "Error: no resources found on any source region node"
    exit 1
fi
SOURCE_IP=$(get_node_ip "$source_node_primary")
echo "  Source primary node: $source_node_primary ($SOURCE_IP)"

scsi0_line=$(ssh "root@${SOURCE_IP}" "qm config $VMID" | grep '^scsi0:')
if [ -z "$scsi0_line" ]; then
    echo "Error: VM $VMID has no scsi0 disk on $source_node_primary"
    exit 1
fi
pve_vol=$(echo "$scsi0_line" | sed 's/^scsi0: *//' | sed 's/,.*//')
base_resource=$(echo "$pve_vol" | sed "s/^linstor-storage://" | sed "s/_${VMID}$//")
resource_name="${pve_vol#linstor-storage:}"
echo "  Resource: $resource_name (base: $base_resource)"

echo ""
echo "--- Capturing VM config ---"
vm_config=$(ssh "root@${SOURCE_IP}" "qm config $VMID")
echo "$vm_config"

vm_name=$(echo "$vm_config" | grep '^name:' | sed 's/^name: *//')
vm_memory=$(echo "$vm_config" | grep '^memory:' | sed 's/^memory: *//')
vm_cores=$(echo "$vm_config" | grep '^cores:' | sed 's/^cores: *//')
vm_cpu=$(echo "$vm_config" | grep '^cpu:' | sed 's/^cpu: *//')
vm_ostype=$(echo "$vm_config" | grep '^ostype:' | sed 's/^ostype: *//')
vm_scsihw=$(echo "$vm_config" | grep '^scsihw:' | sed 's/^scsihw: *//')

vm_net0=""
net0_line=$(echo "$vm_config" | grep '^net0:' || true)
if [ -n "$net0_line" ]; then
    vm_net0=$(echo "$net0_line" | sed 's/^net0: *//')
fi

vm_net1=""
net1_line=$(echo "$vm_config" | grep '^net1:' || true)
if [ -n "$net1_line" ]; then
    vm_net1=$(echo "$net1_line" | sed 's/^net1: *//')
fi

vm_ipconfig1=""
ipconfig1_line=$(echo "$vm_config" | grep '^ipconfig1:' || true)
if [ -n "$ipconfig1_line" ]; then
    vm_ipconfig1=$(echo "$ipconfig1_line" | sed 's/^ipconfig1: *//')
fi

scsi0_line=$(echo "$vm_config" | grep '^scsi0:' || true)
if [ -z "$scsi0_line" ]; then
    echo "Error: VM $VMID has no scsi0 disk"
    exit 1
fi
scsi0_value=$(echo "$scsi0_line" | sed 's/^scsi0: *//')
disk_size=$(echo "$scsi0_value" | sed -n 's/.*size=\([^,]*\).*/\1/p')
disk_opts=$(echo "$scsi0_value" | sed "s/^[^,]*//" | sed 's/^,//')

echo ""
echo "  VM name: $vm_name"
echo "  Memory: $vm_memory, Cores: $vm_cores, CPU: $vm_cpu"
echo "  Disk: $base_resource, Size: $disk_size"

echo ""
echo "=========================================="
echo "  Phase 1: Prepare target region replicas"
echo "=========================================="
echo ""

target_nodes_with_resource=""
target_nodes_without_resource=""
for node in $target_nodes; do
    has=$(echo "$resource_json" | "$YQ" -r ".[0][] | select(.name == \"$base_resource\" and .node_name == \"$node\") | .name" | head -1)
    if [ -n "$has" ]; then
        target_nodes_with_resource="$target_nodes_with_resource $node"
    else
        target_nodes_without_resource="$target_nodes_without_resource $node"
    fi
done

target_replica_count=0
for node in $target_nodes_with_resource; do
    target_replica_count=$((target_replica_count + 1))
done

echo "  Target replicas existing: $target_replica_count"

if [ "$target_replica_count" -lt 2 ]; then
    needed=$((2 - target_replica_count))
    echo "  Need to create $needed more replica(s)"

    for node in $target_nodes_without_resource; do
        if [ "$needed" -le 0 ]; then
            break
        fi
        echo "  Creating resource $base_resource on $node"
        run_linstor "resource create $node $base_resource"
        needed=$((needed - 1))

        echo "  Ensuring cross-region paths for $node"
        for snode in $source_nodes; do
            if [ "$node" \< "$snode" ]; then
                na="$node"
                nb="$snode"
            else
                na="$snode"
                nb="$node"
            fi
            echo "    Path: $na <-> $nb"
            run_linstor "node-connection path create $na $nb cross-region $CROSS_REGION_IF $CROSS_REGION_IF" || true
        done
    done
fi

echo "  Running multiregion setup (Protocol A for inter-region)..."
"${SCRIPT_DIR}/linstor-multiregion-setup.sh" setup "$CONFIG"

echo ""
echo "  Waiting for DRBD sync..."
"${SCRIPT_DIR}/linstor-drbd-sync-wait.sh" "$base_resource" "$CONFIG" --timeout 600

echo ""
echo "=========================================="
echo "  Phase 2: Migrate VM"
echo "=========================================="
echo ""

echo "  Stopping VM $VMID on $source_node_primary..."
ssh "root@${SOURCE_IP}" "qm stop $VMID"
echo "  VM stopped."

echo ""
echo "  Deleting source region replicas..."
for node in $source_nodes; do
    has=$(run_linstor "-m resource list -r $base_resource" | "$YQ" -r ".[0][] | select(.node_name == \"$node\") | .name" | head -1)
    if [ -n "$has" ]; then
        echo "    Deleting $base_resource from $node"
        run_linstor "resource delete $node $base_resource"
    fi
done

echo ""
echo "  Removing VM config from source..."
ssh "root@${SOURCE_IP}" "rm -f /etc/pve/qemu-server/${VMID}.conf"

target_primary=""
for node in $target_nodes; do
    target_primary="$node"
    break
done
TARGET_IP=$(get_node_ip "$target_primary")

echo ""
echo "  Re-creating VM $VMID on $target_primary ($TARGET_IP)..."

create_args="$VMID --name $vm_name --memory $vm_memory --cores $vm_cores"
if [ -n "$vm_cpu" ]; then
    create_args="$create_args --cpu $vm_cpu"
fi
if [ -n "$vm_ostype" ]; then
    create_args="$create_args --ostype $vm_ostype"
fi
if [ -n "$vm_scsihw" ]; then
    create_args="$create_args --scsihw $vm_scsihw"
fi
if [ -n "$vm_net0" ]; then
    create_args="$create_args --net0 $vm_net0"
fi
if [ -n "$vm_net1" ]; then
    create_args="$create_args --net1 $vm_net1"
fi

ssh "root@${TARGET_IP}" "qm create $create_args"

echo "  Attaching LINSTOR disk..."
scsi0_attach="linstor-storage:${resource_name}"
if [ -n "$disk_opts" ]; then
    scsi0_attach="${scsi0_attach},${disk_opts}"
elif [ -n "$disk_size" ]; then
    scsi0_attach="${scsi0_attach},size=${disk_size}"
fi
ssh "root@${TARGET_IP}" "qm set $VMID --scsi0 $scsi0_attach"
ssh "root@${TARGET_IP}" "qm set $VMID --boot order=scsi0"

if [ -n "$vm_ipconfig1" ]; then
    ssh "root@${TARGET_IP}" "qm set $VMID --ipconfig1 $vm_ipconfig1"
fi

echo ""
echo "  Starting VM $VMID on $target_primary..."
ssh "root@${TARGET_IP}" "qm start $VMID"
echo "  VM started."

echo ""
echo "=========================================="
echo "  Phase 3: Re-establish DR replica"
echo "=========================================="
echo ""

dr_node=""
for node in $source_nodes; do
    dr_node="$node"
    break
done

if [ -n "$dr_node" ]; then
    echo "  Creating DR replica on $dr_node"

    has_dr=$(run_linstor "-m resource list -r $base_resource" | "$YQ" -r ".[0][] | select(.node_name == \"$dr_node\") | .name" | head -1)
    if [ -z "$has_dr" ]; then
        run_linstor "resource create $dr_node $base_resource"
    else
        echo "    Resource already exists on $dr_node"
    fi

    echo "  Ensuring cross-region paths..."
    for tnode in $target_nodes; do
        if [ "$dr_node" \< "$tnode" ]; then
            na="$dr_node"
            nb="$tnode"
        else
            na="$tnode"
            nb="$dr_node"
        fi
        run_linstor "node-connection path create $na $nb cross-region $CROSS_REGION_IF $CROSS_REGION_IF" || true
    done

    echo "  Running multiregion setup (Protocol A)..."
    "${SCRIPT_DIR}/linstor-multiregion-setup.sh" setup "$CONFIG"

    echo ""
    echo "  Waiting for DR replica sync..."
    "${SCRIPT_DIR}/linstor-drbd-sync-wait.sh" "$base_resource" "$CONFIG" --timeout 600
else
    echo "  No source region nodes available for DR replica."
fi

echo ""
echo "=========================================="
echo "  Cold migration complete"
echo "=========================================="
echo ""

echo "--- Final state ---"
run_linstor "resource list -r $base_resource"
