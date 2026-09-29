#!/bin/bash
# Fetch the latest BSVA-hosted Teranode UTXO snapshot.
#
# Lists the public bsva-teranode-seeds object storage bucket under
# <network>-teranode/, picks the newest height directory whose snapshot_date.txt
# completion marker exists, downloads the .utxo-headers + .utxo-set files (and
# their .sha256 companions) into seed-cache/<network>-teranode/<height>/, and
# verifies checksums. The bucket is read anonymously; no credentials needed.
#
# Writes seed-cache/.last-fetch.env so seed.sh can pick up FETCHED_HASH +
# FETCHED_DIR. Also prints the next-step ./seed.sh command on success.
#
# Usage:
#   ./seed-fetch.sh                 # uses `network` from .env
#   ./seed-fetch.sh <network>       # mainnet | testnet | teratestnet
#
# Env overrides:
#   SEED_HEIGHT=<n>                 # pin to a specific snapshot height
#   SEED_STREAMS=<n>                # parallel range streams for the download (default 8)
#
# This script does NOT touch Aerospike/Postgres. It only downloads the data.
# Run ./seed.sh after this script finishes to actually load the snapshot.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

set -a
[ -f .env ] && source .env
set +a

# Public HTTPS base, used for the completion-marker check.
SNAPSHOT_BASE="https://bsva-teranode-seeds.s3.gra.io.cloud.ovh.net"
# The same bucket as an anonymous rclone S3 remote, for listing and downloading.
# force_path_style=false: the endpoint only accepts anonymous listing with
# virtual-host addressing (<bucket>.s3...), not path-style.
SNAPSHOT_REMOTE=":s3,provider=Other,endpoint='https://s3.gra.io.cloud.ovh.net',region=gra,env_auth=false,force_path_style=false:bsva-teranode-seeds"

# The utxo-set is a single ~570 GB object on mainnet, so parallelism has to come
# from byte ranges within it. One stream tops out around 1 Gbps; 8 streams
# measured 4-6x that on faster links, with little gained beyond.
SEED_STREAMS="${SEED_STREAMS:-8}"

NETWORK="${1:-${network:-}}"
if [ -z "$NETWORK" ]; then
    echo_error "Network not specified."
    echo_info "Usage: ./seed-fetch.sh <mainnet|testnet>"
    echo_info "Or set 'network=' in .env"
    exit 2
fi

case "$NETWORK" in
    mainnet|testnet|teratestnet) ;;
    *)
        echo_error "BSVA hosts snapshots only for mainnet, testnet, and teratestnet (got: $NETWORK)."
        exit 2
        ;;
esac

ensure_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        return 0
    fi
    echo_warning "rclone is required for snapshot fetching."
    read -p "$(echo_yellow "Install rclone via official installer? [y/N]: ")" reply
    reply=${reply:-N}
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo_error "Cannot continue without rclone."
        echo_info "Install manually: curl https://rclone.org/install.sh | sudo bash"
        return 1
    fi
    if command -v sudo >/dev/null 2>&1; then
        curl -s https://rclone.org/install.sh | sudo bash
    else
        curl -s https://rclone.org/install.sh | bash
    fi
}

snapshot_complete() {
    # snapshot_date.txt is written only after the snapshot upload finishes.
    local url="$1"
    curl --head --silent --fail "${url}snapshot_date.txt" >/dev/null 2>&1
}

get_latest_height() {
    local base_url="$1"
    local base_remote="$2"
    local listing
    if ! listing=$(rclone lsf --dirs-only "${base_remote}" 2>/dev/null); then
        echo_error "Failed to list ${base_url}" >&2
        return 1
    fi
    local heights=()
    while IFS= read -r line; do
        [[ "$line" =~ ^([0-9]+)/$ ]] && heights+=("${BASH_REMATCH[1]}")
    done <<<"$listing"
    if [ ${#heights[@]} -eq 0 ]; then
        echo_error "No height directories found at ${base_url}" >&2
        return 1
    fi
    local sorted
    IFS=$'\n' sorted=($(printf '%s\n' "${heights[@]}" | sort -rn))
    unset IFS
    for h in "${sorted[@]}"; do
        echo_info "Checking height ${h} ..." >&2
        if snapshot_complete "${base_url}${h}/"; then
            echo "$h"
            return 0
        fi
        echo_warning "Height ${h} incomplete (no snapshot_date.txt), skipping." >&2
    done
    echo_error "No completed snapshots found at ${base_url}" >&2
    return 1
}

get_snapshot_hash() {
    # The utxo-headers filename is <hash>.utxo-headers; that hash is the seed hash.
    local snap_remote="$1"
    local listing
    listing=$(rclone lsf "${snap_remote}" 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9a-fA-F]{64})\.utxo-headers$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done <<<"$listing"
    return 1
}

verify_sha256() {
    local dir="$1"
    local sha_tool
    if command -v sha256sum >/dev/null 2>&1; then
        sha_tool="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        sha_tool="shasum -a 256"
    else
        echo_error "No sha256 tool (sha256sum or shasum) found — cannot verify snapshot integrity."
        return 1
    fi
    (
        cd "$dir" || exit 1
        local found=0
        for f in *.sha256; do
            [ -f "$f" ] || continue
            found=1
            echo_info "Verifying $(basename "$f" .sha256) ..."
            if ! $sha_tool -c "$f" >/dev/null; then
                echo_error "Checksum mismatch for $f"
                exit 1
            fi
        done
        if [ "$found" -eq 0 ]; then
            echo_error "No .sha256 files found in $dir — refusing to proceed without verification."
            exit 1
        fi
    )
}

ensure_rclone || exit 1

if ! [[ "$SEED_STREAMS" =~ ^[1-9][0-9]*$ ]]; then
    echo_error "SEED_STREAMS must be a positive integer (got: ${SEED_STREAMS})."
    exit 2
fi

NETWORK_BASE="${SNAPSHOT_BASE}/${NETWORK}-teranode/"
NETWORK_REMOTE="${SNAPSHOT_REMOTE}/${NETWORK}-teranode/"

if [ -n "${SEED_HEIGHT:-}" ]; then
    if ! [[ "$SEED_HEIGHT" =~ ^[0-9]+$ ]]; then
        echo_error "SEED_HEIGHT must be a numeric block height (got: ${SEED_HEIGHT})."
        exit 2
    fi
    HEIGHT="$SEED_HEIGHT"
    echo_info "Using SEED_HEIGHT override: $HEIGHT"
    if ! snapshot_complete "${NETWORK_BASE}${HEIGHT}/"; then
        echo_error "Snapshot at ${NETWORK_BASE}${HEIGHT}/ is not complete (no snapshot_date.txt)."
        exit 1
    fi
else
    echo_info "Discovering latest ${NETWORK}-teranode snapshot ..."
    HEIGHT=$(get_latest_height "$NETWORK_BASE" "$NETWORK_REMOTE") || exit 1
fi

SNAPSHOT_URL="${NETWORK_BASE}${HEIGHT}/"
SNAPSHOT_PATH="${NETWORK_REMOTE}${HEIGHT}/"
echo_success "Latest complete snapshot: height ${HEIGHT}"
echo_info "Source: ${SNAPSHOT_URL}"

HASH=$(get_snapshot_hash "$SNAPSHOT_PATH") || {
    echo_error "Could not derive snapshot hash from ${SNAPSHOT_URL}"
    exit 1
}
echo_info "Block hash: ${HASH}"

SEED_DATA="${REPO_ROOT}/seed-cache/${NETWORK}-teranode/${HEIGHT}"
mkdir -p "$SEED_DATA"

echo_info "Downloading to ${SEED_DATA} ..."
echo_warning "This is large (520+ GB on mainnet). May take hours."

if ! rclone copy "$SNAPSHOT_PATH" "$SEED_DATA" \
                --progress \
                --multi-thread-streams "$SEED_STREAMS" \
                --retries 3 \
                --low-level-retries 10 \
                --include "*.utxo-headers" \
                --include "*.utxo-headers.sha256" \
                --include "*.utxo-set" \
                --include "*.utxo-set.sha256"; then
    echo_error "rclone download failed."
    exit 1
fi

echo_info "Verifying checksums ..."
verify_sha256 "$SEED_DATA" || exit 1

# Persist for seed.sh to pick up automatically. Use printf %q so values
# with shell-special characters (spaces in REPO_ROOT, etc.) round-trip safely.
mkdir -p "${REPO_ROOT}/seed-cache"
{
    printf 'FETCHED_NETWORK=%q\n' "$NETWORK"
    printf 'FETCHED_HEIGHT=%q\n' "$HEIGHT"
    printf 'FETCHED_HASH=%q\n' "$HASH"
    printf 'FETCHED_DIR=%q\n' "$SEED_DATA"
} >"${REPO_ROOT}/seed-cache/.last-fetch.env"

echo ""
echo_success "Snapshot ready at: ${SEED_DATA}"
echo_info "Next: ./seed.sh ${HASH} ${SEED_DATA}"
