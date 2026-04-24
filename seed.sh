#!/bin/bash
# Seed Teranode from a UTXO snapshot.
#
# Usage:
#   ./seed.sh <snapshot-url> <block-hash>
#   ./seed.sh                                  # reads SEED_URL and SEED_HASH from .env
#
# Requires:
#   - Stack NOT running (or data volumes empty). Seeding populates Aerospike
#     and Postgres directly; running services will conflict. Run ./clean.sh
#     first if you're reseeding.
#   - Snapshot URL points at a ZIP file the Teranode seeder knows how to read.
#     For teratestnet the canonical URL is
#     https://svnode-snapshots.bsvb.tech/teratestnet/<hash>.zip
#     For mainnet/testnet, consult upstream guidance for a trusted snapshot.
#
# Note: snapshots are typically pruned — spent UTXOs are NOT in the seed, so
# historical queries return less than a fully-synced node. For complete
# transaction history, start without seeding and wait for the full sync.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

URL="${1:-$SEED_URL}"
HASH="${2:-$SEED_HASH}"

if [ -z "$URL" ] || [ -z "$HASH" ]; then
    echo_error "Missing snapshot URL or block hash."
    echo_info "Usage: ./seed.sh <snapshot-url> <block-hash>"
    echo_info "Or set SEED_URL and SEED_HASH in .env"
    exit 2
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo_error "unzip is required. Install it (apt: unzip, brew: unzip) and retry."
    exit 1
fi

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

SEED_CACHE="${REPO_ROOT}/seed-cache"
SEED_DIR="${REPO_ROOT}/seed-data"
ZIP_FILE="${SEED_CACHE}/${HASH}.zip"

mkdir -p "$SEED_CACHE"

if [ -f "$ZIP_FILE" ]; then
    echo_info "Cached snapshot found at $ZIP_FILE"
else
    echo_info "Downloading snapshot from $URL ..."
    if ! curl -L -o "$ZIP_FILE" "$URL"; then
        echo_error "Download failed."
        rm -f "$ZIP_FILE"
        exit 1
    fi
fi

echo_info "Extracting to $SEED_DIR ..."
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
if ! unzip -q "$ZIP_FILE" -d "$SEED_DIR"; then
    echo_error "Unzip failed."
    rm -rf "$SEED_DIR"
    exit 1
fi

echo_info "Starting seeder service + dependencies (aerospike, postgres, kafka) ..."
SEED_DATA_PATH="$SEED_DIR" docker compose \
    --env-file .env \
    --env-file "$NETWORK_ENV_FILE" \
    --profile seeding up -d seeder

echo_info "Waiting 10s for dependencies to settle ..."
sleep 10

echo_info "Running teranode-cli seeder -inputDir /seed -hash $HASH ..."
if docker exec seeder teranode-cli seeder -inputDir /seed -hash "$HASH"; then
    echo_success "Seeding completed."
else
    echo_error "Seeding failed."
    docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" --profile seeding down
    exit 1
fi

echo_info "Stopping seeder ..."
docker compose --env-file .env --env-file "$NETWORK_ENV_FILE" --profile seeding down

echo_success "Done. Run ./start.sh to bring the full stack up with the seeded data."
