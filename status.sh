#!/bin/bash
# Show service health + FSM state + block height.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

echo_green "=== Containers ==="
docker compose ps
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
