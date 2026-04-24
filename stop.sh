#!/bin/bash
# Graceful shutdown of the Teranode stack.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

echo_info "Asking Teranode to enter IDLE state (best effort)..."
docker exec blockchain teranode-cli setfsmstate --fsmstate IDLE 2>/dev/null || true

echo_info "docker compose down..."
if [ -f "$NETWORK_ENV_FILE" ]; then
    docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" down
else
    docker compose down
fi

echo_success "Stack stopped. Data volumes preserved. Run ./clean.sh to wipe them."
