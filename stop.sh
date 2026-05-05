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

echo_info "docker compose down (all profiles)..."
# Include all known profiles so services like `seeder`, `peer`, `legacy`,
# `monitoring`, `blockpersister`, `asset-cache` are taken down regardless
# of which profile the last `up` used. Otherwise their containers leak
# and leave phantom endpoints in the project network, breaking the next
# `up` with "endpoint with name X already exists in network".
COMPOSE_PROFILES="seeding,p2p,legacy,monitoring,blockpersister" \
    docker compose down --remove-orphans

echo_success "Stack stopped. Data volumes preserved. Run ./clean.sh to wipe them."
