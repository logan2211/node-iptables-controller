#!/bin/bash

set -e

# Check the configmap for changes every minute and perform a full resync
# every 5 minutes
IPTABLES_SYNC_INTERVAL="${IPTABLES_SYNC_INTERVAL:-1m}"
IPTABLES_FULL_RESYNC_ITERS="${IPTABLES_FULL_RESYNC_ITERS:-5}"
IPTABLES_RULES_CONFIGMAP="${IPTABLES_RULES_CONFIGMAP:-iptables-rules}"

# Policies on base chains will be asserted if set
# Note the policy is applied on both v4 and v6
# IPTABLES_INPUT_POLICY=ACCEPT
# IPTABLES_FORWARD_POLICY=ACCEPT
# IPTABLES_OUTPUT_POLICY=ACCEPT

# Apply hooks into user chains
# This will apply a rule to the INPUT chain like
# -A INPUT -j KUBETABLES_CONTROLLER_INPUT
# IPTABLES_INPUT_HOOK=KUBETABLES_CONTROLLER_INPUT
# IPTABLES_FORWARD_HOOK=KUBETABLES_CONTROLLER_FORWARD
# IPTABLES_OUTPUT_HOOK=KUBETABLES_CONTROLLER_OUTPUT

# Set to either "insert" or "append"
IPTABLES_HOOK_MODE="${IPTABLES_HOOK_MODE:-append}"

declare -A UPDATE_CMD=(
    ["ipv4"]="iptables-restore -n"
    ["ipv6"]="ip6tables-restore -n"
)

function reset_sync {
    unset OLD_CONFIGMAP_REVISION
    declare -A CHECKSUMS=()
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
        for ruleset in "${!UPDATE_CMD[@]}"; do
            sync_configmap_rules "$ruleset"
        done
        OLD_CONFIGMAP_REVISION="$CM_CURRENT_REV"
    fi
}

function sync_configmap_rules {
    echo "Running sync for $1 from ${IPTABLES_RULES_CONFIGMAP}"
    local rules=$(kubectl get "configmap/${IPTABLES_RULES_CONFIGMAP}" \
        -o jsonpath="{.data.${1}}")

    if [ -z "$rules" ]; then
        return
    fi

    local rules_checksum="$(echo -n \"${rules}\" | md5sum - | awk '{ print $1 }')"

    if [ "$rules_checksum" = "${CHECKSUMS[$1]}" ]; then
        echo "No changes found"
        return
    fi

    # The rules have been updated
    echo "Rules have been updated. Old checksum: ${CHECKSUMS[$1]}, new checksum: $rules_checksum"
    echo "${rules}" | ${UPDATE_CMD[$1]}
    CHECKSUMS[$1]="$rules_checksum"
}

function assert_chain_policy {
    for chain in INPUT FORWARD OUTPUT; do
        local var="IPTABLES_${chain}_POLICY"
        if [ -n "${!var}" ]; then
            echo "Asserting ${!var} policy on ${chain} chain"
            iptables -P "${chain}" "${!var}"
            ip6tables -P "${chain}" "${!var}"
        fi
    done
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

reset_sync
ITERS=0
echo "Starting iptables-sync"
while true; do
    check_sync_configmap
    check_apply_hooks iptables
    check_apply_hooks ip6tables
    assert_chain_policy

    ITERS=$(($ITERS+1))
    if [ "$ITERS" -ge "$IPTABLES_FULL_RESYNC_ITERS" ]; then
        echo "Queueing full resync next run"
        reset_sync
    fi

    echo "Sync complete. Next sync in $IPTABLES_SYNC_INTERVAL"
    sleep "$IPTABLES_SYNC_INTERVAL"
done
