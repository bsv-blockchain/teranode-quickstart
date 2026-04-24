#!/bin/bash
# Teranode FSM helpers: drive the blockchain service from INIT -> RUNNING.

set -e

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

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    case "$1" in
        wait)  wait_for_blockchain_healthy "${2:-120}" ;;
        state) current_fsm_state ;;
        run)   set_fsm_running ;;
        up)    wait_for_blockchain_healthy && set_fsm_running ;;
        *) echo "usage: fsm.sh {wait|state|run|up}" >&2; exit 2 ;;
    esac
fi
