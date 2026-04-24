#!/bin/bash
# Bring the Teranode stack up for the network configured in .env.

set -e

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

NETWORK="${TERANODE_NETWORK:?TERANODE_NETWORK not set in .env}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"
if [ ! -f "$NETWORK_ENV_FILE" ]; then
    echo_error "No preset for network '$NETWORK' (expected $NETWORK_ENV_FILE)"
    exit 1
fi

PROFILES=()
if [ -n "$ASSET_PUBLIC_URL" ]; then
    PROFILES+=(--profile full)
fi
if [ "${ARCHIVAL:-false}" = "true" ]; then
    PROFILES+=(--profile archival)
fi

echo_info "Network: $NETWORK"
echo_info "Compose env files: .env + compose/networks/${NETWORK}.env"
[ ${#PROFILES[@]} -gt 0 ] && echo_info "Profiles: ${PROFILES[*]}"

docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" "${PROFILES[@]}" up -d

echo ""
"${REPO_ROOT}/lib/fsm.sh" up || echo_warning "FSM transition deferred — see above."

echo ""
echo_success "Stack up. Useful URLs:"
echo "  Grafana:        http://localhost:3005 (admin/admin)"
echo "  Prometheus:     http://localhost:9090"
echo "  Kafka console:  http://localhost:8080"
echo "  Asset viewer:   http://${HOST_IP:-127.0.0.1}:8090"
echo "  RPC endpoint:   http://127.0.0.1:9292"
echo ""
echo_info "Tail logs:  ./logs.sh blockchain"
echo_info "Status:     ./status.sh"

if [ -n "$ASSET_PUBLIC_URL" ] || [ -n "$P2P_ADVERTISE_ADDR" ]; then
    echo ""
    "${REPO_ROOT}/lib/reachability.sh" || true
fi
