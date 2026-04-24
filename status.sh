#!/bin/bash
# Show service health + FSM state + block height.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

echo_green "=== Containers ==="
if [ -f "$NETWORK_ENV_FILE" ]; then
    docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" ps
else
    docker compose ps
fi
echo ""

if docker ps --format '{{.Names}}' | grep -q '^blockchain$'; then
    echo_green "=== FSM state ==="
    docker exec blockchain teranode-cli getfsmstate 2>/dev/null || echo_warning "blockchain running but CLI call failed"
    echo ""
    echo_green "=== Chain info (via RPC) ==="
    "${REPO_ROOT}/rpc.sh" getblockchaininfo 2>/dev/null || echo_warning "RPC call failed — check RPC_USER / RPC_PASS in .env"
else
    echo_warning "blockchain container not running — start with ./start.sh"
fi
