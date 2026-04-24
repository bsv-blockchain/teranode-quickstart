#!/bin/bash
# Tail logs for one service or all. Usage: ./logs.sh [service]

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

set -a
[ -f .env ] && source .env
set +a

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

if [ -f "$NETWORK_ENV_FILE" ]; then
    exec docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" logs -f --tail=200 "$@"
fi
exec docker compose logs -f --tail=200 "$@"
