#!/bin/bash
# Graceful shutdown of the Teranode stack.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

if docker ps --format '{{.Names}}' | grep -q '^blockchain$'; then
    echo_info "Asking Teranode to enter IDLE state (best effort)..."
    if ! docker exec blockchain teranode-cli setfsmstate --fsmstate IDLE; then
        echo_warning "FSM IDLE transition failed — continuing with shutdown."
    fi
else
    echo_info "blockchain container not running — skipping FSM transition."
fi

echo_info "docker compose down..."
docker compose down

echo_success "Stack stopped. Data volumes preserved. Run ./clean.sh to wipe them."
