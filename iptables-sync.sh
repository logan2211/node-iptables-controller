#!/bin/bash

set -e

# Check the configmap for changes every minute and perform a full resync
# every 5 minutes
IPTABLES_SYNC_INTERVAL="${IPTABLES_SYNC_INTERVAL:-1m}"
IPTABLES_FULL_RESYNC_ITERS="${IPTABLES_FULL_RESYNC_ITERS:-5}"
IPTABLES_RULES_CONFIGMAP="${IPTABLES_RULES_CONFIGMAP:-iptables-rules}"

# Apply hooks into user chains
# This will apply a rule to the INPUT chain like
# -A INPUT -j KUBETABLES_CONTROLLER_INPUT
# IPTABLES_INPUT_HOOK=KUBETABLES_CONTROLLER_INPUT
# IPTABLES_FORWARD_HOOK=KUBETABLES_CONTROLLER_FORWARD
# IPTABLES_OUTPUT_HOOK=KUBETABLES_CONTROLLER_OUTPUT

# Set to either "insert" or "append"
IPTABLES_HOOK_MODE="${IPTABLES_HOOK_MODE:-append}"

declare -A IPTABLES_CMD=(
    ["ipv4"]="iptables"
    ["ipv6"]="ip6tables"
)

function reset_sync {
    unset OLD_CONFIGMAP_REVISION
}

function check_apply_hooks {
    # Add hooks to the base chains into the entrypoint chains
    local iptables_base_cmd="${1:-iptables}"

    for chain in INPUT FORWARD OUTPUT; do
        local var="IPTABLES_${chain}_HOOK"
        if [ -n "${!var}" ]; then
            if [ "$($iptables_base_cmd -S ${chain} | grep -E "^-A ${chain}\s.*-j ${!var}\s?.*$")" ]; then
                echo "${iptables_base_cmd} hook is already present in ${chain}"
            else
                if [ "${IPTABLES_HOOK_MODE}" = "insert" ]; then
                    echo "Inserting ${iptables_base_cmd} hook for ${chain} to ${!var}"
                    local iptables="${iptables_base_cmd} -I"
                elif [ "${IPTABLES_HOOK_MODE}" = "append" ]; then
                    echo "Appending ${iptables_base_cmd} hook for ${chain} to ${!var}"
                    local iptables="${iptables_base_cmd} -A"
                else
                    echo "Invalid hook mode: ${IPTABLES_HOOK_MODE}"
                    exit 1
                fi

                $iptables "${chain}" -j "${!var}" -m comment --comment "iptables controller managed"
            fi
        fi
    done
}

function check_sync_configmap {
    echo "Beginning iptables sync run"
    CM_CURRENT_REV=$(kubectl get "configmap/${IPTABLES_RULES_CONFIGMAP}" \
        -o jsonpath='{.metadata.resourceVersion}')

    if [[ -z "$CM_CURRENT_REV" ]]; then
        echo "Failed to get configmap revision"
        return
    fi

    if [[ "$OLD_CONFIGMAP_REVISION" -ne "$CM_CURRENT_REV" ]]; then
        echo "Configmap revision changed from $OLD_CONFIGMAP_REVISION to $CM_CURRENT_REV"
        # Revision changed, sync rules
        for ruleset in "${!IPTABLES_CMD[@]}"; do
            sync_configmap_rules "$ruleset"
        done
        OLD_CONFIGMAP_REVISION="$CM_CURRENT_REV"
    fi
}

function sync_configmap_rules {
    echo "Applying rules for $1 from ${IPTABLES_RULES_CONFIGMAP}"
    local rules=$(kubectl get "configmap/${IPTABLES_RULES_CONFIGMAP}" \
        -o jsonpath="{.data.${1}}")

    if [ -z "$rules" ]; then
        echo "No rules found for $1"
        return
    fi

    echo "${rules}" | "${IPTABLES_CMD[$1]}-restore" --noflush
    check_apply_hooks "${IPTABLES_CMD[$1]}"
}

ITERS=0
echo "Starting iptables-sync"
while true; do
    if [ "$ITERS" -eq 0 ] || [ "$ITERS" -ge "$IPTABLES_FULL_RESYNC_ITERS" ]; then
        echo "Forcing full resync"
        reset_sync
        ITERS=0
    fi

    check_sync_configmap
    for ruleset in "${!IPTABLES_CMD[@]}"; do
        check_apply_hooks "${IPTABLES_CMD[$ruleset]}"
    done

    ITERS=$(($ITERS+1))
    echo "Sync complete. Next sync in $IPTABLES_SYNC_INTERVAL"
    sleep "$IPTABLES_SYNC_INTERVAL"
done
