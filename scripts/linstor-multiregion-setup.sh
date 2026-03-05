#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"

usage() {
    echo "Usage: linstor-multiregion-setup.sh <setup|teardown> <config>"
    echo ""
    echo "  setup    Set Aux/site properties and Protocol A for inter-region connections"
    echo "  teardown Remove Aux/site properties and resource-connection overrides"
    echo ""
    echo "  <config>  Path to linstor.yml (e.g. config/linstor.yml)"
    exit 2
}

if [ $# -lt 2 ]; then
    usage
fi

COMMAND="$1"
CONFIG="$2"

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
}

get_all_nodes() {
    for region in $(get_region_names); do
        get_region_nodes "$region"
    done
}

is_cross_region() {
    region_a=$(get_node_region "$1")
    region_b=$(get_node_region "$2")
    [ "$region_a" != "$region_b" ]
}

resource_has_node() {
    echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.name == \"$1\" and .node_name == \"$2\") | .name" 2>/dev/null | head -1
}

fetch_resource_data() {
    echo "Fetching resource list from LINSTOR..."
    RESOURCE_JSON=$(run_linstor "-m resource list")
    RESOURCE_NAMES=$(echo "$RESOURCE_JSON" | "$YQ" -r '.[0][].name' | sort -u)
}

do_setup() {
    echo "=== Setting Aux/site properties ==="
    for region in $(get_region_names); do
        for node in $(get_region_nodes "$region"); do
            echo "  $node -> Aux/site=$region"
            run_linstor "node set-property $node Aux/site $region"
        done
    done

    echo ""
    echo "=== Setting inter-region Protocol A connections ==="

    all_nodes=$(get_all_nodes)
    fetch_resource_data

    for resource in $RESOURCE_NAMES; do
        resource_nodes=""
        for node in $all_nodes; do
            if [ -n "$(resource_has_node "$resource" "$node")" ]; then
                resource_nodes="$resource_nodes $node"
            fi
        done

        for node_a in $resource_nodes; do
            for node_b in $resource_nodes; do
                if [ "$node_a" \< "$node_b" ] && is_cross_region "$node_a" "$node_b"; then
                    echo "  $resource: $node_a <-> $node_b -> Protocol A, allow-two-primaries no"
                    run_linstor "resource-connection drbd-peer-options $node_a $node_b $resource --protocol A --allow-two-primaries no"
                fi
            done
        done
    done

    echo ""
    echo "Setup complete."
}

do_teardown() {
    echo "=== Removing resource-connection overrides ==="

    all_nodes=$(get_all_nodes)
    fetch_resource_data

    for resource in $RESOURCE_NAMES; do
        resource_nodes=""
        for node in $all_nodes; do
            if [ -n "$(resource_has_node "$resource" "$node")" ]; then
                resource_nodes="$resource_nodes $node"
            fi
        done

        for node_a in $resource_nodes; do
            for node_b in $resource_nodes; do
                if [ "$node_a" \< "$node_b" ] && is_cross_region "$node_a" "$node_b"; then
                    echo "  $resource: $node_a <-> $node_b -> restoring Protocol C, allow-two-primaries yes"
                    run_linstor "resource-connection drbd-peer-options $node_a $node_b $resource --protocol C --allow-two-primaries yes"
                    echo "  $resource: $node_a <-> $node_b -> clearing overrides"
                    run_linstor "resource-connection set-property $node_a $node_b $resource DrbdOptions/Net/protocol"
                    run_linstor "resource-connection set-property $node_a $node_b $resource DrbdOptions/Net/allow-two-primaries"
                fi
            done
        done
    done

    echo ""
    echo "=== Removing Aux/site properties ==="
    for region in $(get_region_names); do
        for node in $(get_region_nodes "$region"); do
            echo "  $node -> removing Aux/site"
            run_linstor "node set-property $node Aux/site"
        done
    done

    echo ""
    echo "Teardown complete."
}

case "$COMMAND" in
    setup)
        do_setup
        ;;
    teardown)
        do_teardown
        ;;
    *)
        echo "Error: unknown command: $COMMAND"
        usage
        ;;
esac
