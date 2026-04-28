#!/bin/bash
# Tail logs for one service or all. Usage: ./logs.sh [service]

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

exec docker compose logs -f --tail=200 "$@"
