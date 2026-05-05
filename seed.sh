#!/bin/bash
# Seed Teranode from a UTXO snapshot.
#
# Usage:
#   ./seed.sh                                     # prompt to fetch BSVA-hosted snapshot
#   ./seed.sh <block-hash> <local-seed-dir>      # use existing local seed data (BYO)
#
# Snapshots: BSVA hosts at https://svnode-snapshots.bsvb.tech/<network>-teranode/<height>/
# for mainnet, testnet, and teratestnet. ./seed-fetch.sh discovers the latest
# completed height and downloads it. Prefer to build your own? Pass a local
# directory containing the .utxo-headers + .utxo-set files instead.
#
# Requires:
#   - Stack NOT running with existing state. Seeding populates Aerospike and
#     Postgres directly; running services will conflict. Run ./clean.sh first
#     if you're reseeding into an existing volume.
#
# Note: snapshots are typically pruned — spent UTXOs are NOT in the seed, so
# historical queries return less than a fully-synced node. For complete
# transaction history, skip seeding and let the node sync from scratch.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

HASH="${1:-}"
SOURCE="${2:-}"

NETWORK="${network:-testnet}"

case "$NETWORK" in
    mainnet|testnet|teratestnet) ;;
    *)
        echo_error "Seeding not supported for network: $NETWORK"
        echo_info "Supported: mainnet | testnet | teratestnet"
        exit 2
        ;;
esac

# No args → prompt to fetch BSVA-hosted snapshot for the configured network.
if [ -z "$HASH" ] && [ -z "$SOURCE" ]; then
    echo_info "BSVA hosts ${NETWORK} snapshots at https://svnode-snapshots.bsvb.tech/${NETWORK}-teranode/"
    echo_info "You can also build your own seed data and pass the directory to seed.sh."
    read -p "$(echo_yellow "Fetch the latest BSVA-hosted snapshot now? [Y/n]: ")" reply
    reply=${reply:-Y}
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        "${REPO_ROOT}/seed-fetch.sh" || exit $?
        if [ ! -f "${REPO_ROOT}/seed-cache/.last-fetch.env" ]; then
            echo_error "seed-fetch.sh did not produce expected state file."
            exit 1
        fi
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/seed-cache/.last-fetch.env"
        HASH="$FETCHED_HASH"
        SOURCE="$FETCHED_DIR"
    else
        echo_info "Skipping fetch. Build your own seed data, then run:"
        echo_info "  ./seed.sh <block-hash> <local-seed-dir>"
        # Non-zero so chained invocations like `./seed.sh && ./start.sh` don't continue.
        exit 2
    fi
fi

if [ -z "$HASH" ] || [ -z "$SOURCE" ]; then
    echo_error "Both <block-hash> and <local-seed-dir> are required."
    echo_info "Usage: ./seed.sh <block-hash> <local-seed-dir>"
    echo_info "Or run ./seed.sh with no args to fetch a BSVA-hosted snapshot."
    exit 2
fi

if [ ! -d "$SOURCE" ]; then
    echo_error "Local seed directory does not exist: $SOURCE"
    exit 1
fi
if [ -z "$(ls -A "$SOURCE" 2>/dev/null)" ]; then
    echo_error "Local seed directory is empty: $SOURCE"
    exit 1
fi
MOUNT_DIR="$(cd "$SOURCE" && pwd)"
echo_info "Using seed directory: $MOUNT_DIR"

echo_info "Starting seeder service + dependencies (aerospike, postgres, kafka) ..."
SEED_DATA_PATH="$MOUNT_DIR" docker compose --profile seeding up -d seeder

echo_info "Waiting 10s for dependencies to settle ..."
sleep 10

echo_info "Running teranode-cli seeder -inputDir /seed -hash $HASH ..."
if docker exec seeder teranode-cli seeder -inputDir /seed -hash "$HASH"; then
    echo_success "Seeding completed."
else
    echo_error "Seeding failed."
    docker compose --profile seeding rm -fsv seeder
    exit 1
fi

echo_info "Stopping seeder ..."
docker compose --profile seeding rm -fsv seeder

echo_success "Done. Run ./start.sh to bring the full stack up with the seeded data."
