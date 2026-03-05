#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"

usage() {
    echo "Usage: linstor-multiregion-status.sh [<config>]"
    echo ""
    echo "  Show multi-region LINSTOR/DRBD status."
    echo "  Default config: config/linstor.yml"
    exit 2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

CONFIG="${1:-config/linstor.yml}"

if [ ! -f "$CONFIG" ]; then
    echo "Error: config file not found: $CONFIG"
    exit 1
fi

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")

run_linstor() {
    ssh "root@${CONTROLLER_IP}" "linstor $*"
}

get_region_names() {
    "$YQ" '.regions | keys | .[]' "$CONFIG"
}

get_region_nodes() {
    "$YQ" ".regions.\"$1\"[]" "$CONFIG"
}

get_node_region() {
    node="$1"
    for region in $(get_region_names); do
        for n in $(get_region_nodes "$region"); do
            if [ "$n" = "$node" ]; then
                echo "$region"
                return
            fi
        done
    done
    echo "(unknown)"
}

echo "=== Node Aux/site Properties ==="
echo ""

all_nodes=""
for region in $(get_region_names); do
    for node in $(get_region_nodes "$region"); do
        all_nodes="$all_nodes $node"
    done
done

for node in $all_nodes; do
    site=$(run_linstor "node list-properties $node" | grep 'Aux/site' | awk '{print $4}' || true)
    config_region=$(get_node_region "$node")
    if [ -z "$site" ]; then
        echo "  $node: Aux/site=(not set)  [config: $config_region]"
    elif [ "$site" = "$config_region" ]; then
        echo "  $node: Aux/site=$site  [OK]"
    else
        echo "  $node: Aux/site=$site  [MISMATCH: config=$config_region]"
    fi
done

echo ""
echo "=== Per-Connection Protocol Settings ==="
echo ""

RESOURCE_JSON=$(run_linstor "-m resource list")
resources=$(echo "$RESOURCE_JSON" | "$YQ" -r '.[0][].name' | sort -u)

for resource in $resources; do
    resource_nodes=""
    for node in $all_nodes; do
        has_resource=$(echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.name == \"$resource\" and .node_name == \"$node\") | .name" 2>/dev/null | head -1)
        if [ -n "$has_resource" ]; then
            resource_nodes="$resource_nodes $node"
        fi
    done

    for node_a in $resource_nodes; do
        for node_b in $resource_nodes; do
            if [ "$node_a" \< "$node_b" ]; then
                region_a=$(get_node_region "$node_a")
                region_b=$(get_node_region "$node_b")
                if [ "$region_a" = "$region_b" ]; then
                    conn_type="intra-region"
                else
                    conn_type="INTER-REGION"
                fi

                props=$(run_linstor "resource-connection list-properties $node_a $node_b $resource" 2>/dev/null || true)
                protocol=$(echo "$props" | grep 'DrbdOptions/Net/protocol' | awk '{print $4}' || true)
                two_pri=$(echo "$props" | grep 'DrbdOptions/Net/allow-two-primaries' | awk '{print $4}' || true)

                protocol_str="${protocol:-default(C)}"
                two_pri_str="${two_pri:-default(yes)}"

                echo "  $resource: $node_a <-> $node_b [$conn_type]"
                echo "    protocol=$protocol_str  allow-two-primaries=$two_pri_str"
            fi
        done
    done
done

echo ""
echo "=== DRBD Sync State ==="
echo ""

run_linstor "resource list"

echo ""
echo "=== DRBD Connection Details ==="
echo ""

for node in $all_nodes; do
    node_ip=$("$YQ" ".nodes[] | select(.name == \"$node\") | .ip" "$CONFIG")
    echo "--- $node ---"
    ssh "root@${node_ip}" "drbdsetup status --verbose --statistics" 2>/dev/null | grep -E '(^\S|connection|peer-disk|out-of-sync|protocol)' || echo "  (no DRBD resources)"
    echo ""
done
