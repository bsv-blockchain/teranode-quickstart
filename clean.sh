#!/bin/bash
# Cleanup. Destructive — warns unless --force.

set -eo pipefail

USAGE=$(cat <<'EOF'
Usage: ./clean.sh [flags]

Cleanup. Destructive — warns unless --force.
Default: remove data volumes only. .env is preserved unless you ask.

Flags:
  (no flag)        Remove named volumes only (same as --data-only)
  --data-only      Remove named volumes only (keep .env)
  --config-only    Remove .env (keep volumes)
  --all            Remove everything (volumes + .env)
  --force          Skip confirmation prompts
  --quiet          Suppress progress output
  -h, --help       Show this help and exit
EOF
)

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
        -h|--help)     echo "$USAGE"; exit 0 ;;
        *)             echo "Unknown flag: $arg" >&2; echo "$USAGE" >&2; exit 2 ;;
    esac
done

log() { [ "$QUIET" -eq 0 ] && echo_info "$1"; }

compose() {
    docker compose "$@"
}

if [ "$FORCE" -eq 0 ]; then
    echo_yellow "WARNING: this will permanently delete data (mode=$MODE)."
    if [ "$MODE" = "all" ] || [ "$MODE" = "data" ]; then
        echo "Compose-managed volumes that will be removed:"
        compose config --volumes 2>/dev/null | sed 's/^/  /' || echo "  (compose config not readable)"
    fi
    if [ "$MODE" = "all" ] || [ "$MODE" = "config" ]; then
        echo "Config that will be removed: .env"
    fi
    echo ""
    read -p "Proceed? (y/N): " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || { echo_warning "Cancelled."; exit 0; }
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "data" ]; then
    # Run `compose down` with all known profiles so services like `seeder`,
    # `peer`, `legacy`, `monitoring`, `blockpersister`, `asset-cache` are
    # included. Otherwise their containers leak and leave phantom endpoints
    # in the project network, breaking the next `compose up` with
    # "endpoint with name X already exists in network".
    log "docker compose down -v (all profiles) ..."
    COMPOSE_PROFILES="seeding,p2p,legacy,monitoring,blockpersister" \
        compose down -v --remove-orphans 2>/dev/null || true

    # Belt-and-suspenders: force-remove any container still labelled for
    # this compose project (covers any profile we forgot to list).
    log "Removing any leftover project containers ..."
    leftover=$(docker ps -aq --filter "label=com.docker.compose.project=teranode-quickstart" 2>/dev/null || true)
    if [ -n "$leftover" ]; then
        echo "$leftover" | xargs docker rm -f 2>/dev/null || true
    fi

    # Force-remove the project network. Disconnect anything still attached
    # so a phantom endpoint can't block removal.
    NET="teranode-quickstart-network"
    if docker network inspect "$NET" >/dev/null 2>&1; then
        log "Cleaning stale network endpoints on $NET ..."
        docker network inspect "$NET" -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' \
            | while IFS= read -r ep; do
                [ -z "$ep" ] && continue
                docker network disconnect -f "$NET" "$ep" 2>/dev/null || true
            done
        docker network rm "$NET" 2>/dev/null || true
    fi
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "config" ]; then
    log "Removing .env..."
    rm -f .env
fi

echo_success "Clean complete (mode=$MODE)."
