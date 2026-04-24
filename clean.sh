#!/bin/bash
# Cleanup. Destructive — warns unless --force.
# Default: remove data volumes only. .env is preserved unless you ask.
# Flags:
#   (no flag)        Remove named volumes only (same as --data-only)
#   --data-only      Remove named volumes only (keep .env)
#   --config-only    Remove .env (keep volumes)
#   --all            Remove everything (volumes + .env)
#   --force          Skip confirmation prompts
#   --quiet          Suppress progress output

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

MODE="data"
FORCE=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --data-only)   MODE="data" ;;
        --config-only) MODE="config" ;;
        --all)         MODE="all" ;;
        --force)       FORCE=1 ;;
        --quiet)       QUIET=1 ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log() { [ "$QUIET" -eq 0 ] && echo_info "$1"; }

set -a
[ -f .env ] && source .env
set +a

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

VOLUMES=(
    teranode-quickstart_teranode-data
    teranode-quickstart_postgres-data
    teranode-quickstart_aerospike-data
    teranode-quickstart_aerospike-smd
    teranode-quickstart_aerospike-asmt
    teranode-quickstart_nginx-cache
    teranode-quickstart_prometheus-data
    teranode-quickstart_grafana-data
)

if [ "$FORCE" -eq 0 ]; then
    echo_yellow "This will clean mode=$MODE. Volumes/configs will be destroyed."
    read -r -p "Type YES to continue: " confirm
    [ "$confirm" = "YES" ] || { echo_warning "Aborted."; exit 0; }
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "data" ]; then
    log "Taking stack down with -v (removes compose-managed volumes)..."
    if [ -f "$NETWORK_ENV_FILE" ]; then
        docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" down -v 2>/dev/null || true
    else
        docker compose down -v 2>/dev/null || true
    fi
    log "Removing named volumes (best-effort)..."
    for v in "${VOLUMES[@]}"; do
        docker volume rm "$v" 2>/dev/null || true
    done
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "config" ]; then
    log "Removing .env..."
    rm -f .env
fi

echo_success "Clean complete (mode=$MODE)."
