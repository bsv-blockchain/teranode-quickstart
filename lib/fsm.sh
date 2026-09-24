#!/bin/bash
# Teranode FSM helpers: drive the blockchain service out of IDLE on start.
#
# Start target is CATCHINGBLOCKS: from there v0.16+ promotes itself to RUNNING
# once catchup completes, and it refuses any manual RUN below the highest
# checkpoint. v0.15.x has no IDLE -> CATCHINGBLOCKS transition, so fall back to
# RUNNING only when the node is in IDLE and the FSM rejects the event.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

wait_for_blockchain_healthy() {
    local timeout="${1:-120}"
    local elapsed=0
    echo_info "Waiting for blockchain service to become healthy (timeout ${timeout}s)..."
    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status=$(docker inspect -f '{{.State.Health.Status}}' blockchain 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then
            echo_success "blockchain is healthy."
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo_error "blockchain did not become healthy within ${timeout}s."
    return 1
}

current_fsm_state() {
    docker exec blockchain teranode-cli getfsmstate 2>/dev/null \
        | grep -Eo 'state:[[:space:]]*[A-Z]+' \
        | awk '{print $2}'
}

set_fsm_running() {
    local current
    current=$(current_fsm_state 2>/dev/null || echo "")
    if [ "$current" = "RUNNING" ]; then
        echo_info "FSM already in RUNNING state."
        return 0
    fi
    echo_info "Transitioning FSM to RUNNING..."
    if docker exec blockchain teranode-cli setfsmstate --fsmstate RUNNING; then
        echo_success "FSM state set to RUNNING."
        return 0
    fi
    echo_warning "setfsmstate command failed. Run './cli.sh setfsmstate --fsmstate RUNNING' manually."
    return 1
}

set_fsm_start() {
    local current
    current=$(current_fsm_state 2>/dev/null || echo "")
    case "$current" in
        RUNNING|CATCHINGBLOCKS)
            echo_info "FSM already in ${current} state."
            return 0
            ;;
    esac
    echo_info "Transitioning FSM to CATCHINGBLOCKS..."
    local out
    if out=$(docker exec blockchain teranode-cli setfsmstate --fsmstate CATCHINGBLOCKS 2>&1); then
        echo "$out"
        echo_success "FSM state set to CATCHINGBLOCKS."
        return 0
    fi
    # Error text from v0.15.x SendFSMEvent / looplab/fsm InvalidEventError.
    if [ "$current" = "IDLE" ] \
        && echo "$out" | grep -qE 'rejected in state|inappropriate in current state'; then
        echo_info "IDLE -> CATCHINGBLOCKS not supported by this Teranode version (pre-v0.16) — falling back to RUNNING."
        set_fsm_running
        return
    fi
    echo "$out" >&2
    echo_warning "setfsmstate CATCHINGBLOCKS failed from state '${current:-unknown}'. Check ./status.sh, then run './cli.sh setfsmstate --fsmstate CATCHINGBLOCKS' manually."
    return 1
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "$1" in
        wait)  wait_for_blockchain_healthy "${2:-120}" ;;
        state) current_fsm_state ;;
        run)   set_fsm_running ;;
        start) set_fsm_start ;;
        up)    wait_for_blockchain_healthy && set_fsm_start ;;
        *) echo "usage: fsm.sh {wait|state|run|start|up}" >&2; exit 2 ;;
    esac
fi
