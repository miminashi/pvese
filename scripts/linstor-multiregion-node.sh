#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YQ="${SCRIPT_DIR}/../bin/yq"

usage() {
    echo "Usage: linstor-multiregion-node.sh <add|remove> <node> <region|config> [<config>]"
    echo ""
    echo "  add <node> <region> <config>"
    echo "    Set Aux/site property and configure Protocol A for inter-region connections."
    echo "    Node must already be registered in LINSTOR."
    echo ""
    echo "  remove <node> <config>"
    echo "    Remove resources, clear resource-connection overrides, remove Aux/site,"
    echo "    delete storage pool, and delete node from LINSTOR."
    echo ""
    echo "  <config>  Path to linstor.yml (e.g. config/linstor.yml)"
    exit 2
}

if [ $# -lt 3 ]; then
    usage
fi

COMMAND="$1"
NODE="$2"

CONFIG=""
REGION=""

case "$COMMAND" in
    add)
        if [ $# -lt 4 ]; then
            usage
        fi
        REGION="$3"
        CONFIG="$4"
        ;;
    remove)
        CONFIG="$3"
        ;;
    *)
        echo "Error: unknown command: $COMMAND"
        usage
        ;;
esac

if [ ! -f "$CONFIG" ]; then
    echo "Error: config file not found: $CONFIG"
    exit 1
fi

CONTROLLER_IP=$("$YQ" '.controller_ip' "$CONFIG")
STORAGE_POOL=$("$YQ" '.storage_pool_name' "$CONFIG")

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

get_other_region_nodes() {
    target_region="$1"
    for region in $(get_region_names); do
        if [ "$region" != "$target_region" ]; then
            get_region_nodes "$region"
        fi
    done
}

do_add() {
    echo "=== Adding node $NODE to region $REGION ==="
    echo ""

    echo "  Setting Aux/site=$REGION on $NODE"
    run_linstor "node set-property $NODE Aux/site $REGION"

    other_nodes=$(get_other_region_nodes "$REGION")
    if [ -z "$other_nodes" ]; then
        echo "  No nodes in other regions. Skipping Protocol A setup."
        echo ""
        echo "Add complete."
        return
    fi

    echo ""
    echo "  Fetching resource list..."
    RESOURCE_JSON=$(run_linstor "-m resource list")
    node_resources=$(echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.node_name == \"$NODE\") | .name" | sort -u)

    if [ -z "$node_resources" ]; then
        echo "  No resources on $NODE. Skipping Protocol A setup."
        echo ""
        echo "Add complete."
        return
    fi

    echo "  Setting Protocol A for inter-region resource connections..."

    for resource in $node_resources; do
        for other_node in $other_nodes; do
            has_resource=$(echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.name == \"$resource\" and .node_name == \"$other_node\") | .name" 2>/dev/null | head -1)
            if [ -n "$has_resource" ]; then
                if [ "$NODE" \< "$other_node" ]; then
                    na="$NODE"
                    nb="$other_node"
                else
                    na="$other_node"
                    nb="$NODE"
                fi
                echo "    $resource: $na <-> $nb -> Protocol A, allow-two-primaries no"
                run_linstor "resource-connection drbd-peer-options $na $nb $resource --protocol A --allow-two-primaries no"
            fi
        done
    done

    echo ""
    echo "Add complete."
}

do_remove() {
    echo "=== Removing node $NODE ==="
    echo ""

    node_region=$(get_node_region "$NODE")

    echo "  Fetching resource list..."
    RESOURCE_JSON=$(run_linstor "-m resource list")
    node_resources=$(echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.node_name == \"$NODE\") | .name" | sort -u)

    if [ -n "$node_region" ]; then
        other_nodes=$(get_other_region_nodes "$node_region")

        if [ -n "$other_nodes" ] && [ -n "$node_resources" ]; then
            echo "  Clearing resource-connection overrides..."
            for resource in $node_resources; do
                for other_node in $other_nodes; do
                    has_resource=$(echo "$RESOURCE_JSON" | "$YQ" -r ".[0][] | select(.name == \"$resource\" and .node_name == \"$other_node\") | .name" 2>/dev/null | head -1)
                    if [ -n "$has_resource" ]; then
                        if [ "$NODE" \< "$other_node" ]; then
                            na="$NODE"
                            nb="$other_node"
                        else
                            na="$other_node"
                            nb="$NODE"
                        fi
                        echo "    $resource: $na <-> $nb -> restoring Protocol C"
                        run_linstor "resource-connection drbd-peer-options $na $nb $resource --protocol C --allow-two-primaries yes"
                        run_linstor "resource-connection set-property $na $nb $resource DrbdOptions/Net/protocol"
                        run_linstor "resource-connection set-property $na $nb $resource DrbdOptions/Net/allow-two-primaries"
                    fi
                done
            done
            echo ""
        fi
    fi

    if [ -n "$node_resources" ]; then
        echo "  Deleting resources from $NODE..."
        for resource in $node_resources; do
            echo "    linstor resource delete $NODE $resource"
            run_linstor "resource delete $NODE $resource"
        done
        echo ""
    fi

    echo "  Deleting storage pool $STORAGE_POOL from $NODE"
    run_linstor "storage-pool delete $NODE $STORAGE_POOL" 2>/dev/null || echo "    (pool not found or already deleted)"

    echo "  Removing Aux/site property from $NODE"
    run_linstor "node set-property $NODE Aux/site" 2>/dev/null || true

    echo "  Deleting node $NODE from LINSTOR"
    run_linstor "node delete $NODE"

    echo ""
    echo "Remove complete."
}

case "$COMMAND" in
    add)
        do_add
        ;;
    remove)
        do_remove
        ;;
esac
