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
    log "docker compose down -v ..."
    compose down -v 2>/dev/null || true
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "config" ]; then
    log "Removing .env..."
    rm -f .env
fi

echo_success "Clean complete (mode=$MODE)."
