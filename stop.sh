#!/bin/bash
# Graceful shutdown of the Teranode stack.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

echo_info "Asking Teranode to enter IDLE state (best effort)..."
docker exec blockchain teranode-cli setfsmstate --fsmstate IDLE 2>/dev/null || true

echo_info "docker compose down..."
docker compose down

echo_success "Stack stopped. Data volumes preserved. Run ./clean.sh to wipe them."
