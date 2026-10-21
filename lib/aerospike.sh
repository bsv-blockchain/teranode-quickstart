#!/bin/bash
# Aerospike batch-index helpers: thread floor and stall check.
#
# batch-index-threads defaults to the core count, and each thread owns one
# response queue. A 16-core teratestnet node stopped completing batch reads
# entirely: every one of its 16 queues held requests, the unused buffer pool
# was empty, process CPU was 0 and batch_index_complete did not move for over
# an hour. Only restarting the aerospike container cleared it. The root cause
# in Aerospike is not confirmed; the working theory is that a few client
# sockets that stop draining responses can occupy every queue when there are
# this few of them. A 128-core node on the same config never stalled.
#
# config/aerospike.conf sets batch-index-threads 64, which survives any
# restart. A static value cannot follow the core count, so start.sh also
# raises it live to the core count on hosts with more than 64 cores. That
# live step also covers an existing install whose aerospike container
# predates the config change: `docker compose up -d` does not recreate a
# container when only a bind-mounted file changes.
#
# Sourceable library. Provides:
#   batch_index_threads_target <ncpu>      -> echoes max(64, ncpu), capped at 256
#   apply_batch_index_threads_floor        -> raises the running value to the target
#   batch_index_stalled <stats1> <stats2>  -> 0 when the two samples show a stall
#   check_batch_index_stall                -> samples twice, warns on a stall

AEROSPIKE_CONTAINER="aerospike"
BATCH_INDEX_THREADS_FLOOR=64
# Aerospike's own upper bound for batch-index-threads.
BATCH_INDEX_THREADS_MAX=256
BATCH_STALL_SAMPLE_SECS=5

_as_info() {
    docker exec "$AEROSPIKE_CONTAINER" asinfo -v "$1" 2>/dev/null
}

# Value of one key from a semicolon-separated asinfo response.
_as_field() {
    echo "$1" | tr ';' '\n' | awk -F= -v k="$2" '$1==k {print $2; exit}'
}

batch_index_threads_target() {
    local ncpu="$1"
    awk -v n="$ncpu" -v lo="$BATCH_INDEX_THREADS_FLOOR" -v hi="$BATCH_INDEX_THREADS_MAX" \
        'BEGIN { t = (n > lo) ? n : lo; if (t > hi) t = hi; print t }'
}

# Waits up to <timeout> seconds for Aerospike to answer, then raises
# batch-index-threads to the target. Never lowers a value set higher by hand.
# Returns non-zero when Aerospike is unreachable or the set fails.
apply_batch_index_threads_floor() {
    local timeout="${1:-120}" elapsed=0 ncpu target current result
    until [ "$(_as_info status)" = "ok" ]; do
        if [ "$elapsed" -ge "$timeout" ]; then
            echo_warning "Aerospike did not answer within ${timeout}s; batch-index-threads not checked."
            return 1
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    ncpu=$(docker exec "$AEROSPIKE_CONTAINER" nproc 2>/dev/null || echo 0)
    target=$(batch_index_threads_target "$ncpu")
    current=$(_as_field "$(_as_info "get-config:context=service")" batch-index-threads)
    if [ -z "$current" ]; then
        echo_warning "Could not read batch-index-threads from Aerospike."
        return 1
    fi
    if [ "$current" -ge "$target" ]; then
        return 0
    fi
    result=$(_as_info "set-config:context=service;batch-index-threads=${target}" || true)
    if [ "$result" != "ok" ]; then
        echo_warning "Could not raise Aerospike batch-index-threads ${current} -> ${target}: ${result:-no response}"
        return 1
    fi
    echo_info "Aerospike batch-index-threads ${current} -> ${target} (${ncpu} cores, floor ${BATCH_INDEX_THREADS_FLOOR})."
}

# Sum of queued requests across every batch_index_queue entry
# (format: Q1_REQUESTS:Q1_BUFFERS,Q2_REQUESTS:Q2_BUFFERS,...).
_batch_queued_requests() {
    echo "$1" | tr ',' '\n' | awk -F: '{ sum += $1 } END { print sum + 0 }'
}

# Stalled = requests sit in the queues, the unused buffer pool is empty, and
# no batch completed between the two samples. An idle node also reports 0
# unused buffers and a flat complete counter, but with empty queues.
batch_index_stalled() {
    local s1="$1" s2="$2" c1 c2 unused queued
    c1=$(_as_field "$s1" batch_index_complete)
    c2=$(_as_field "$s2" batch_index_complete)
    unused=$(_as_field "$s2" batch_index_unused_buffers)
    queued=$(_batch_queued_requests "$(_as_field "$s2" batch_index_queue)")
    [ -n "$c1" ] && [ "$c1" = "$c2" ] && [ "$unused" = "0" ] && [ "$queued" -gt 0 ]
}

# Warn-only: always returns 0 so status output carries on.
check_batch_index_stall() {
    local s1 s2 threads queued
    s1=$(_as_info statistics || true)
    if [ -z "$s1" ]; then
        echo_warning "aerospike running but asinfo statistics failed"
        return 0
    fi
    threads=$(_as_field "$(_as_info "get-config:context=service" || true)" batch-index-threads)
    queued=$(_batch_queued_requests "$(_as_field "$s1" batch_index_queue)")
    echo "batch-index-threads: ${threads:-?}   queued batch requests: ${queued}   unused buffers: $(_as_field "$s1" batch_index_unused_buffers)"

    # Only a node with queued requests and no spare buffers can be stalled;
    # skip the second sample otherwise so status.sh stays fast.
    if [ "$queued" -eq 0 ] || [ "$(_as_field "$s1" batch_index_unused_buffers)" != "0" ]; then
        return 0
    fi
    sleep "$BATCH_STALL_SAMPLE_SECS"
    s2=$(_as_info statistics || true)
    [ -n "$s2" ] || return 0
    if ! batch_index_stalled "$s1" "$s2"; then
        return 0
    fi

    # delay = response sends that hit WOULDBLOCK; both help tell a client
    # that stopped reading apart from a server that stopped sending.
    local d_delay d_error
    d_delay=$(( $(_as_field "$s2" batch_index_delay || true) + 0 - $(_as_field "$s1" batch_index_delay || true) + 0 ))
    d_error=$(( $(_as_field "$s2" batch_index_error || true) + 0 - $(_as_field "$s1" batch_index_error || true) + 0 ))
    echo_warning "Aerospike batch processing looks stalled: no batch completed in ${BATCH_STALL_SAMPLE_SECS}s with ${queued} requests queued and no free response buffers."
    echo_warning "batch_index_complete=$(_as_field "$s2" batch_index_complete)  delay +${d_delay}  error +${d_error}  queues: $(_as_field "$s2" batch_index_queue)"
    echo_warning "Run ./status.sh again to confirm. A stalled node logs STORAGE_ERROR / MAX_RETRIES_EXCEEDED from the UTXO store and stops advancing."
    echo_warning "Recovery: docker restart aerospike   (data persists on the volume; startup can take a minute or more)."
    echo_warning "On hosts with more than 64 cores, run ./start.sh afterwards to re-apply the higher batch-index-threads."
    return 0
}
