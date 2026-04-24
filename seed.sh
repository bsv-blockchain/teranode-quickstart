#!/bin/bash
# Seed Teranode from a UTXO snapshot.
#
# Usage:
#   ./seed.sh <block-hash>                        # teratestnet: auto-derive URL + download
#   ./seed.sh <block-hash> <http(s)-url>          # download from any URL
#   ./seed.sh <block-hash> <local-seed-dir>       # use an existing local directory (BYO)
#   ./seed.sh                                     # reads SEED_HASH + SEED_URL or SEED_DIR from .env
#
# Snapshot sources by network:
#   - teratestnet:                  https://svnode-snapshots.bsvb.tech/teratestnet/<hash>.zip
#                                   (./seed.sh <hash> derives this URL)
#   - mainnet / standard testnet:   bring your own. Download or generate the seed
#                                   data into a local directory, then pass that
#                                   directory path as the second argument.
#
# Requires:
#   - Stack NOT running with existing state. Seeding populates Aerospike and
#     Postgres directly; running services will conflict. Run ./clean.sh first
#     if you're reseeding into an existing volume.
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
SOURCE="${2:-${SEED_URL:-${SEED_DIR:-}}}"

if [ -z "$HASH" ]; then
    echo_error "Missing block hash."
    echo_info "Usage: ./seed.sh <block-hash> [url-or-local-dir]"
    echo_info "Or set SEED_HASH (+ SEED_URL or SEED_DIR) in .env"
    exit 2
fi

NETWORK="${TERANODE_NETWORK:-testnet}"
NETWORK_ENV_FILE="${REPO_ROOT}/compose/networks/${NETWORK}.env"

# Resolve source into an on-disk directory that will be bind-mounted into the seeder.
if [ -z "$SOURCE" ]; then
    SOURCE="${TERATESTNET_SNAPSHOT_BASE}/${HASH}.zip"
    echo_warning "No source supplied — defaulting to the teratestnet snapshot URL."
    echo_warning "This is the only canonical snapshot source published today. For"
    echo_warning "mainnet / standard testnet, download or generate your own seed"
    echo_warning "into a local directory and pass the directory path as arg 2."
    echo_info "Derived URL: $SOURCE"
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
    # URL mode: download + extract into ./seed-data
    if ! command -v unzip >/dev/null 2>&1; then
        echo_error "unzip is required for URL mode. Install it and retry (or pass a local dir)."
        exit 1
    fi
    SEED_CACHE="${REPO_ROOT}/seed-cache"
    SEED_DATA="${REPO_ROOT}/seed-data"
    ZIP_FILE="${SEED_CACHE}/${HASH}.zip"
    mkdir -p "$SEED_CACHE"
    if [ -f "$ZIP_FILE" ]; then
        echo_info "Cached snapshot found at $ZIP_FILE"
    else
        echo_info "Downloading snapshot from $SOURCE ..."
        if ! curl -L -o "$ZIP_FILE" "$SOURCE"; then
            echo_error "Download failed."
            rm -f "$ZIP_FILE"
            exit 1
        fi
    fi
    echo_info "Extracting to $SEED_DATA ..."
    rm -rf "$SEED_DATA"
    mkdir -p "$SEED_DATA"
    if ! unzip -q "$ZIP_FILE" -d "$SEED_DATA"; then
        echo_error "Unzip failed."
        rm -rf "$SEED_DATA"
        exit 1
    fi
    MOUNT_DIR="$SEED_DATA"
else
    # Local directory mode (BYO seed for mainnet / testnet etc.)
    if [ ! -d "$SOURCE" ]; then
        echo_error "Local seed directory does not exist: $SOURCE"
        exit 1
    fi
    if [ -z "$(ls -A "$SOURCE" 2>/dev/null)" ]; then
        echo_error "Local seed directory is empty: $SOURCE"
        exit 1
    fi
    MOUNT_DIR="$(cd "$SOURCE" && pwd)"
    echo_info "Using existing seed directory: $MOUNT_DIR"
fi

echo_info "Starting seeder service + dependencies (aerospike, postgres, kafka) ..."
SEED_DATA_PATH="$MOUNT_DIR" docker compose \
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
