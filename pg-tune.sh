#!/usr/bin/env bash
# pg-tune.sh — live Postgres tuning for Teranode IBD throughput.
# Mirrors aerospike-tune.sh in spirit: opt-in fast-mode for catch-up, reversible.
# Run with --help for usage.

set -euo pipefail

# ---- Configuration ----
CONTAINER="postgres"
PSQL_USER="postgres"
ASSUME_YES=0

# Params we toggle. Keep aligned with PG built-in defaults below.
# All are reload-only (no restart). Verified against PostgreSQL 17.
PARAMS=(synchronous_commit commit_delay commit_siblings)
DEFAULT_VALUES=(on 0 5)
# Catch-up values: trades last ~600ms of committed writes (host crash only)
# for ~20-50% throughput. Teranode re-syncs from peers on restart, so the
# lost window is recovered transparently.
#   synchronous_commit = off  → COMMIT returns before WAL fsync to disk
#   commit_delay       = 1000 → 1ms group-commit window
#   commit_siblings    = 10   → require 10 concurrent txns to engage delay
CATCHUP_VALUES=(off 1000 10)

# ---- Output helpers (TTY-only colors) ----
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi
red()   { printf '%s%s%s' "$C_RED" "$*" "$C_OFF"; }
green() { printf '%s%s%s' "$C_GRN" "$*" "$C_OFF"; }
yellow(){ printf '%s%s%s' "$C_YEL" "$*" "$C_OFF"; }
bold()  { printf '%s%s%s' "$C_BLD" "$*" "$C_OFF"; }

# ---- psql plumbing ----
psql_run() {
  docker exec "${CONTAINER}" psql -U "${PSQL_USER}" -tA "$@"
}

# ALTER SYSTEM writes to postgresql.auto.conf; pg_reload_conf() applies without restart.
pg_set() {
  local param=$1 value=$2 quoted
  # Quote string values (synchronous_commit), leave numerics bare.
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    quoted="$value"
  else
    quoted="'$value'"
  fi
  printf '  set %-22s = %-10s ... ' "$param" "$value"
  if psql_run -c "ALTER SYSTEM SET $param = $quoted;" >/dev/null 2>&1; then
    green "ok"; echo
    return 0
  fi
  red "FAIL"; echo
  return 1
}

pg_reset() {
  local param=$1
  printf '  reset %-20s ... ' "$param"
  if psql_run -c "ALTER SYSTEM RESET $param;" >/dev/null 2>&1; then
    green "ok"; echo
    return 0
  fi
  red "FAIL"; echo
  return 1
}

pg_reload() {
  printf '  reload config           ... '
  if psql_run -c "SELECT pg_reload_conf();" >/dev/null 2>&1; then
    green "ok"; echo
    return 0
  fi
  red "FAIL"; echo
  return 1
}

# Read the live value from pg_settings (post-reload).
pg_get() {
  local param=$1
  psql_run -c "SELECT setting FROM pg_settings WHERE name = '$param';" 2>/dev/null
}

verify_value() {
  local param=$1 expected=$2 actual
  actual=$(pg_get "$param")
  printf '  verify %-21s ... ' "$param"
  if [[ "$actual" == "$expected" ]]; then
    green "$actual"; echo
    return 0
  fi
  red "MISMATCH"; printf ' (expected %s, got %s)\n' "$expected" "$actual"
  return 1
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ans
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]]
}

cmd_help() {
  cat <<'EOF'
pg-tune.sh — live Postgres tuning for Teranode IBD throughput

USAGE
  ./pg-tune.sh [-y] <command>

COMMANDS
  catchup           Apply catch-up values (synchronous_commit=off,
                    commit_delay=1000, commit_siblings=10). Trades last
                    ~600ms of writes on host crash for ~20-50% throughput.
                    Reversible.
  restore-default   Revert to PostgreSQL defaults (synchronous_commit=on).
  status            Show current values + DB size + WAL pressure.
  -h, --help        Show this help.

FLAGS
  -y, --yes         Skip the [y/N] confirmation prompt.

EXAMPLES
  ./pg-tune.sh status
  ./pg-tune.sh catchup
  ./pg-tune.sh restore-default -y

SAFETY
  Cluster-wide setting — affects every database in this Postgres instance.
  On host OS crash / power loss: last few hundred ms of committed writes
  may be lost. Postgres NEVER corrupts; just loses recent commits.
  Postgres process crash alone is safe (OS page cache still flushes).

  Teranode recovers cleanly: blockchain re-syncs from peers, UTXO state
  re-derives from blocks. Not appropriate for production mainnet money;
  fine for quickstart experimentation.

Operates on the local 'postgres' docker container only.
EOF
}

cmd_status() {
  bold "Postgres tuning status"; echo " — container: ${CONTAINER}"
  echo "─────────────────────────────────────────────────"

  local i param current default padded
  printf '  %-22s %-12s    %s\n' "param" "current" "default"
  printf '  %-22s %-12s    %s\n' "-----" "-------" "-------"
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    default=${DEFAULT_VALUES[$i]}
    current=$(pg_get "$param")
    # Pad first, then colorize — ANSI escapes count as printable chars to
    # printf and break %-Ns width when applied before padding.
    padded=$(printf '%-12s' "$current")
    if [[ "$current" != "$default" ]]; then
      printf '  %-22s %s    %s\n' "$param" "$(yellow "$padded")" "$default"
    else
      printf '  %-22s %s    %s\n' "$param" "$padded" "$default"
    fi
  done
  echo

  bold "  health"; echo
  local db_size wal_size connections active
  db_size=$(psql_run -c "SELECT pg_size_pretty(pg_database_size('teranode'));" 2>/dev/null)
  wal_size=$(psql_run -c "SELECT pg_size_pretty(SUM(size)) FROM pg_ls_waldir();" 2>/dev/null)
  connections=$(psql_run -c "SELECT COUNT(*) FROM pg_stat_activity WHERE datname='teranode';" 2>/dev/null)
  active=$(psql_run -c "SELECT COUNT(*) FROM pg_stat_activity WHERE datname='teranode' AND state='active';" 2>/dev/null)
  printf '  %-22s %s\n' "teranode db size" "${db_size:-?}"
  printf '  %-22s %s\n' "WAL dir size" "${wal_size:-?}"
  printf '  %-22s %s (%s active)\n' "connections" "${connections:-?}" "${active:-?}"
}

target_for_mode() {
  local mode=$1 idx=$2
  if [[ "$mode" == "catchup" ]]; then
    echo "${CATCHUP_VALUES[$idx]}"
  else
    echo "${DEFAULT_VALUES[$idx]}"
  fi
}

print_diff_table() {
  local mode=$1 i param current target
  printf '  %-22s %-12s    %-12s\n' "param" "current" "→ target"
  printf '  %-22s %-12s    %-12s\n' "-----" "-------" "--------"
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    target=$(target_for_mode "$mode" "$i")
    current=$(pg_get "$param")
    printf '  %-22s %-12s → %-12s\n' "$param" "$current" "$target"
  done
}

apply_values() {
  local mode=$1 i param target failed=0
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    target=$(target_for_mode "$mode" "$i")
    pg_set "$param" "$target" || failed=1
  done
  pg_reload || failed=1
  echo
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    target=$(target_for_mode "$mode" "$i")
    verify_value "$param" "$target" || failed=1
  done
  return $failed
}

reset_values() {
  local i param failed=0
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    pg_reset "$param" || failed=1
  done
  pg_reload || failed=1
  echo
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    verify_value "$param" "${DEFAULT_VALUES[$i]}" || failed=1
  done
  return $failed
}

cmd_catchup() {
  bold "Postgres catch-up"; echo " — container ${CONTAINER}"
  echo
  echo "Will apply (TEMPORARY — run 'restore-default' once at tip):"
  print_diff_table catchup
  echo
  yellow "  WARNING:"; echo " synchronous_commit=off — last few hundred ms of"
  echo "           writes may be lost on host crash. Teranode re-syncs from"
  echo "           peers, so the window is recovered transparently."
  echo
  confirm || { echo "Aborted."; exit 1; }
  echo
  apply_values catchup
}

cmd_restore() {
  bold "Postgres restore-default"; echo " — container ${CONTAINER}"
  echo
  echo "Will reset (returns to PG built-in defaults):"
  print_diff_table default
  echo
  confirm || { echo "Aborted."; exit 1; }
  echo
  reset_values
}

# ---- Main ----
main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) cmd_help; exit 0 ;;
      catchup|restore-default|status) cmd=$1; shift ;;
      *) red "Unknown argument: $1"; echo; cmd_help; exit 2 ;;
    esac
  done
  case "$cmd" in
    catchup) cmd_catchup ;;
    restore-default) cmd_restore ;;
    status) cmd_status ;;
    "") cmd_help; exit 2 ;;
  esac
}

main "$@"
