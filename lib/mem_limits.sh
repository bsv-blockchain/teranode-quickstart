#!/bin/bash
# Per-service container memory limits, scaled to host RAM.
#
# Why: teranode's daemon auto-tunes the Go GC from the container's cgroup
# memory limit (GOMEMLIMIT = 90% of the limit, see daemon/daemon_memlimit.go
# in the teranode repo). Without a mem_limit the cgroup reads "max", no
# GOMEMLIMIT is set, and a single service can balloon until the HOST runs out
# of memory — at which point Aerospike trips stop-writes
# (stop-writes-sys-memory-pct) and the whole node wedges. Observed in the
# wild: legacy decoding a 3.9 GB testnet block grew to 26 GiB RSS on a 32 GB
# host. With a cap, the worst case is one service OOM-killing and restarting
# visibly while the datastores stay healthy.
#
# The limits are caps, not reservations — the percentages deliberately
# overcommit. Real-world services don't peak simultaneously; the point is
# that no single service can starve Aerospike/Postgres/Kafka/OS.
#
# Sourceable library. Provides:
#   detect_total_ram_gb                     -> echoes host RAM in GB
#   compute_mem_limits <network> <total_gb> -> echoes MEM_LIMIT_<SVC>=<val> lines
#   write_mem_limits <env_file> <network> <total_gb> [--only-missing]
#
# The <network> argument is reserved for per-network ratio tables; the ratios
# are currently identical for all networks (hosts scale via the RAM
# percentage, and check_requirements.sh already gates minimum host size per
# network).

# Service -> percentage of host RAM. Bash-3.2 compatible (macOS): plain list.
#
#   legacy            — decodes whole legacy-wire blocks in memory; by far the
#                       biggest consumer during initial block download
#   subtreevalidation — holds subtree tx batches + utxo meta cache
#   blockvalidation   — holds full blocks during validation/catchup
#   blockassembly     — in-memory subtree assembly
#   seeder            — bulk-loads the UTXO set (runs with the stack down)
#   rpc / pruner      — thin coordinators
MEM_LIMIT_TABLE="
legacy:40
subtreevalidation:20
blockvalidation:20
blockassembly:15
seeder:15
blockchain:10
asset:10
propagation:10
blockpersister:10
peer:10
rpc:5
pruner:5
"

# Floor so tiny (regtest) hosts don't produce caps too small for the Go
# runtime + service baseline to even start.
MEM_LIMIT_FLOOR_MB=512

detect_total_ram_gb() {
    local bytes gb
    # Prefer the Docker daemon's view of memory: that is the budget the
    # containers actually share. On macOS the host's physical RAM is the
    # wrong number — containers run inside the Docker Desktop VM, which is
    # typically allocated far less than the Mac has.
    bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
        gb=$(( (bytes / 1024 / 1024 + 512) / 1024 ))
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    else
        # free -g truncates (31.7 GB -> 31); compute from MB and round.
        gb=$(free -m | awk 'NR==2 {print int(($2 + 512) / 1024)}')
    fi
    # Clamp to >= 1: sub-1GB hosts would otherwise round to 0, fail
    # compute_mem_limits' input guard, and — under `set -eo pipefail` in
    # setup.sh — abort setup mid-run. The 512m per-service floor is the real
    # protection at that size anyway.
    if ! [[ "$gb" =~ ^[0-9]+$ ]] || [ "$gb" -lt 1 ]; then
        gb=1
    fi
    echo "$gb"
}

# compute_mem_limits <network> <total_gb>
# Echoes one MEM_LIMIT_<SERVICE>=<value> line per service (value like "12g"
# or "768m"), suitable for .env.
compute_mem_limits() {
    local network="$1"
    local total_gb="$2"

    if ! [[ "$total_gb" =~ ^[0-9]+$ ]] || [ "$total_gb" -lt 1 ]; then
        echo "compute_mem_limits: invalid total_gb '$total_gb'" >&2
        return 1
    fi

    local entry service pct limit_mb
    local IFS=$' \t\n' # the table split below must not inherit a caller's IFS
    for entry in $MEM_LIMIT_TABLE; do
        service="${entry%%:*}"
        pct="${entry##*:}"
        limit_mb=$(( total_gb * 1024 * pct / 100 ))
        if [ "$limit_mb" -lt "$MEM_LIMIT_FLOOR_MB" ]; then
            limit_mb=$MEM_LIMIT_FLOOR_MB
        fi
        # Whole gigs read better in .env; anything fractional stays in MB so
        # the formatted value never truncates below the computed cap.
        if [ $(( limit_mb % 1024 )) -eq 0 ]; then
            echo "MEM_LIMIT_$(echo "$service" | tr '[:lower:]' '[:upper:]')=$(( limit_mb / 1024 ))g"
        else
            echo "MEM_LIMIT_$(echo "$service" | tr '[:lower:]' '[:upper:]')=${limit_mb}m"
        fi
    done
}

# write_mem_limits <env_file> <network> <total_gb> [--only-missing]
# Writes computed limits into <env_file> via env_writer.sh.
# --only-missing: skip keys already present (update.sh path — never clobber
# user tuning).
write_mem_limits() {
    local env_file="$1"
    local network="$2"
    local total_gb="$3"
    local only_missing="${4:-}"

    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local line key value
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        if [ "$only_missing" = "--only-missing" ] && grep -qE "^${key}=" "$env_file" 2>/dev/null; then
            continue
        fi
        "${lib_dir}/env_writer.sh" "$env_file" "$key" "$value"
    done < <(compute_mem_limits "$network" "$total_gb")
}
