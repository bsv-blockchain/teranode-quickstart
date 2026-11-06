#!/bin/bash
# Aerospike batch-index stall check for status.sh.
#
# Two teratestnet nodes (16 and 128 cores) stopped completing Aerospike batch
# requests: requests sat in the batch-index queues, the unused buffer pool was
# empty, process CPU was 0 and batch_index_complete did not move until the
# aerospike container was restarted. The cause is still under investigation;
# docs/TROUBLESHOOTING.md has the symptoms and what is known so far.
#
# Sourceable library. Provides:
#   batch_index_stalled <stats1> <stats2>  -> 0 when the two samples show a stall
#   check_batch_index_stall                -> samples twice, warns on a stall

AEROSPIKE_CONTAINER="aerospike"
BATCH_STALL_SAMPLE_SECS=5

_as_info() {
    docker exec "$AEROSPIKE_CONTAINER" asinfo -v "$1" 2>/dev/null
}

# Value of one key from a semicolon-separated asinfo response.
_as_field() {
    echo "$1" | tr ';' '\n' | awk -F= -v k="$2" '$1==k {print $2; exit}'
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
    local s1 s2 queued
    s1=$(_as_info statistics || true)
    if [ -z "$s1" ]; then
        echo_warning "aerospike running but asinfo statistics failed"
        return 0
    fi
    queued=$(_batch_queued_requests "$(_as_field "$s1" batch_index_queue)")
    echo "queued batch requests: ${queued}   unused buffers: $(_as_field "$s1" batch_index_unused_buffers)   completed: $(_as_field "$s1" batch_index_complete)"

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
    echo_warning "See docs/TROUBLESHOOTING.md for what to capture before restarting."
    return 0
}
