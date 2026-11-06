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

# The alert container reports healthy while it is still looking for alert
# peers; only its log shows whether it has synced and joined the topic.
# --since: a restarted container keeps the previous run's log lines.
if docker ps --format '{{.Names}}' | grep -q '^alert$'; then
    echo ""
    echo_green "=== Alert System ==="
    alert_started=$(docker inspect -f '{{.State.StartedAt}}' alert)
    alert_log=$(docker logs --since "$alert_started" alert 2>&1 | grep -E "successfully synced up to|subscribed to bitcoin_alert_system|Running peer discovery" || true)
    synced=$(echo "$alert_log" | grep "successfully synced up to" | tail -1 | sed -E 's/.*synced up to (sequence )?([0-9]+).*/alert sequence \2/' || true)
    if grep -q "subscribed to bitcoin_alert_system" <<<"$alert_log"; then
        echo "Subscribed to the alert topic${synced:+ ($synced)}."
    else
        since=$(echo "$alert_log" | grep "Running peer discovery" | head -1 | cut -d' ' -f1 || true)
        echo_warning "Not subscribed yet: still discovering alert peers${since:+ since $since}${synced:+ ($synced)}. See README \"Alert System\"."
    fi
fi
