#!/bin/bash
# Conflict WAL guard for leaving Teranode v0.16.0.
#
# v0.16.0 writes conflict intents without a recovery checklist. v0.16.1 and
# later refuse such an intent at startup, and block assembly does not start
# until it is repaired (bsv-blockchain/teranode#2023). Any stop can leave one
# behind, a graceful one included, so the WAL has to be read empty after block
# assembly has stopped and before the new image runs.
#
# The check is one read-only `docker exec aerospike asinfo` call. It needs
# Aerospike up and block assembly down. Sourced by update.sh.

CONFLICT_WAL_REPAIR_URL="https://github.com/bsv-blockchain/teranode/blob/v0.16.1/docs/topics/conflict-recovery.md#upgrade-and-repair"
CONFLICT_WAL_UPGRADE_URL="https://github.com/bsv-blockchain/teranode/releases/tag/v0.16.1#before-you-upgrade"

# Quickstart's UTXO store is upstream's utxostore.docker.m:
# aerospike://aerospike:3000/utxo-store?...&set=utxo. The WAL is the
# <set>_conflictwal set in that namespace.
CONFLICT_WAL_NAMESPACE="utxo-store"
CONFLICT_WAL_SET="utxo_conflictwal"

# leaves_v0160 <current> <target>
#   Succeeds when <current> is v0.16.0 or a v0.16.0 pre-release and <target> is
#   v0.16.1 or later, pre-releases of v0.16.1 included. A target that doesn't
#   parse as vX.Y.Z[-...] counts as later: checking costs one query, skipping
#   can leave block assembly unable to start.
leaves_v0160() {
    local current="$1" target="$2"
    case "$current" in
        v0.16.0|v0.16.0-*) ;;
        *) return 1 ;;
    esac

    local base="${target#v}"
    base="${base%%-*}"
    if ! [[ "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 0
    fi
    local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    [ "$major" -gt 0 ] && return 0
    [ "$minor" -gt 16 ] && return 0
    [ "$minor" -eq 16 ] && [ "$patch" -ge 1 ] && return 0
    return 1
}

_container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

_wal_cannot_tell() {
    echo_error "Cannot verify the conflict WAL is empty: $1"
    shift
    local line
    for line in "$@"; do
        echo_error "  $line"
    done
    echo_error "v0.16.1 and later refuse a conflict intent left by v0.16.0, and block assembly"
    echo_error "will not start. .env is unchanged. Fix the above and re-run, or check the WAL"
    echo_error "yourself (${CONFLICT_WAL_UPGRADE_URL})"
    echo_error "and set TERANODE_VERSION in .env by hand."
}

# check_conflict_wal
#   Expects .env sourced (utxostore, SETTINGS_CONTEXT). Prints what it found.
#   Returns 0 when the WAL is empty, 1 when it holds records, 2 when it cannot
#   tell. Only 0 should let the caller write .env.
check_conflict_wal() {
    if [ -n "${utxostore:-}" ]; then
        _wal_cannot_tell "utxostore is set in .env, so the node may not use quickstart's Aerospike set." \
            "This check only reads ${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET} on the aerospike container."
        return 2
    fi
    if [ "${SETTINGS_CONTEXT:-docker.m}" != "docker.m" ]; then
        _wal_cannot_tell "SETTINGS_CONTEXT=${SETTINGS_CONTEXT}, so the node may not use quickstart's Aerospike set." \
            "This check only reads ${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET} on the aerospike container."
        return 2
    fi
    if ! command -v docker >/dev/null 2>&1; then
        _wal_cannot_tell "docker is not on PATH."
        return 2
    fi
    if _container_running blockassembly; then
        _wal_cannot_tell "block assembly is running, and v0.16.0 can write an intent at any moment." \
            "Stop it first: docker stop blockassembly" \
            "(./start.sh starts it again after the update. Don't use ./stop.sh: it stops Aerospike too.)"
        return 2
    fi
    if ! _container_running aerospike; then
        _wal_cannot_tell "the aerospike container is not running." \
            "Start Aerospike on its own: docker compose up -d aerospike"
        return 2
    fi

    local out
    if ! out=$(docker exec aerospike asinfo -v "sets/${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET}" 2>&1); then
        _wal_cannot_tell "asinfo failed: ${out}"
        return 2
    fi
    out="${out//[[:space:]]/}"

    # A set that was never written doesn't exist: asinfo answers with nothing.
    if [ -z "$out" ]; then
        echo_success "Conflict WAL is empty (${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET} does not exist)."
        return 0
    fi
    if [[ "$out" =~ ^objects=([0-9]+)(:|\;|$) ]]; then
        local objects="${BASH_REMATCH[1]}"
        if [ "$objects" -eq 0 ]; then
            echo_success "Conflict WAL is empty (${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET}: objects=0)."
            return 0
        fi
        echo_error "The conflict WAL holds ${objects} record(s) (${CONFLICT_WAL_NAMESPACE}/${CONFLICT_WAL_SET})."
        echo_error "v0.16.1 and later refuse a v0.16.0 conflict intent, and block assembly will not start."
        echo_error "Keep block assembly stopped and repair it first: ${CONFLICT_WAL_REPAIR_URL}"
        echo_error ".env is unchanged."
        return 1
    fi

    # e.g. ns_type=unknown when the namespace doesn't exist.
    _wal_cannot_tell "unexpected asinfo answer: ${out}"
    return 2
}
