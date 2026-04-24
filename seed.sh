#!/bin/bash
# Seed Teranode from a UTXO snapshot.
#
# Usage:
#   ./seed.sh <block-hash>                     # uses the teratestnet snapshot base
#   ./seed.sh <block-hash> <snapshot-url>      # explicit URL (any provider)
#   ./seed.sh                                  # reads SEED_HASH [+ SEED_URL] from .env
#
# CURRENT LIMITATION:
#   Snapshots are only published for teratestnet at the moment, at
#     https://svnode-snapshots.bsvb.tech/teratestnet/<hash>.zip
#   Supply just the block hash and this script derives that URL. For mainnet
#   and standard BSV testnet, no canonical snapshot source exists yet — you
#   would need to host one yourself and pass the URL as the second argument.
#
# Requires:
#   - Stack NOT running (or data volumes empty). Seeding populates Aerospike
#     and Postgres directly; running services will conflict. Run ./clean.sh
#     first if you're reseeding.
#
# Note: snapshots are typically pruned — spent UTXOs are NOT in the seed, so
# historical queries return less than a fully-synced node. For complete
# transaction history, skip seeding and let the node sync from scratch.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

TERATESTNET_SNAPSHOT_BASE="https://svnode-snapshots.bsvb.tech/teratestnet"

HASH="${1:-$SEED_HASH}"
URL="${2:-$SEED_URL}"

if [ -z "$HASH" ]; then
    echo_error "Missing block hash."
    echo_info "Usage: ./seed.sh <block-hash> [snapshot-url]"
    echo_info "Or set SEED_HASH (and optionally SEED_URL) in .env"
    exit 2
fi

if [ -z "$URL" ]; then
    URL="${TERATESTNET_SNAPSHOT_BASE}/${HASH}.zip"
    echo_warning "No URL supplied — defaulting to the teratestnet snapshot base."
    echo_warning "This is the only snapshot source currently published. If you are"
    echo_warning "seeding mainnet or standard BSV testnet, you must supply your own URL."
    echo_info "Derived URL: $URL"
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
