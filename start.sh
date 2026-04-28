#!/bin/bash
# Bring the Teranode stack up for the network configured in .env.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

if [ ! -f .env ]; then
    echo_error ".env not found. Run ./setup.sh first."
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

NETWORK="${network:?network not set in .env}"

echo_info "Network: $NETWORK"
[ -n "${COMPOSE_PROFILES:-}" ] && echo_info "Profiles: $COMPOSE_PROFILES"

docker compose up -d

echo ""
"${REPO_ROOT}/lib/fsm.sh" up || echo_warning "FSM transition failed — see above. Try ./status.sh and ./cli.sh setfsmstate --fsmstate RUNNING manually."

echo ""
echo_success "Stack up. Useful URLs:"
echo "  Grafana:        http://localhost:3005 (admin/admin)"
echo "  Prometheus:     http://localhost:9090"
echo "  Kafka console:  http://localhost:8080"
echo "  Asset viewer:   http://localhost:8090"
echo "  RPC endpoint:   http://localhost:9292"
if [ "${HOST_IP:-127.0.0.1}" = "0.0.0.0" ]; then
    echo ""
    echo_info "HOST_IP=0.0.0.0 — the asset endpoint is also reachable from another"
    echo_info "machine on the LAN at this host's IP (replace 'localhost' above)."
fi
echo ""
echo_info "Tail logs:  ./logs.sh blockchain"
echo_info "Status:     ./status.sh"

if [ -n "$asset_httpPublicAddress" ] || [ -n "$p2p_advertise_addresses" ]; then
    echo ""
    "${REPO_ROOT}/lib/reachability.sh" || true
fi
