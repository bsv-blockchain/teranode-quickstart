#!/usr/bin/env bash
# aerospike-tune.sh — live Aerospike tuning for Teranode IBD throughput.
# See docs/specs/2026-05-24-aerospike-ibd-throttle.md for design and rationale.

set -euo pipefail

# ---- Configuration ----
CONTAINER="aerospike"
NAMESPACE="utxo-store"
SSH_HOST=""
ASSUME_YES=0

# Steady-state values — MUST MIRROR config/aerospike.conf. Keep in sync.
PARAMS=(defrag-sleep defrag-lwm-pct max-write-cache post-write-cache)
STEADY_VALUES=(1000 50 4096M 1024)
# IBD-throttle values.
# defrag-lwm-pct is RAISED (not lowered) per AS guidance:
#   https://aerospike.com/docs/database/manage/namespace/storage/defrag/
#   "When defragmentation cannot keep pace with storage demand,
#    operators should temporarily decrease defrag-sleep and increase
#    defrag-lwm-pct."
THROTTLE_VALUES=(0 70 8192M 2048)

# Aerospike 8.x storage-engine sub-context uses dotted-path within the namespace context.
SET_CONFIG_PREFIX="set-config:context=namespace;id=${NAMESPACE}"
GET_CONFIG_NAMESPACE="get-config:context=namespace;id=${NAMESPACE}"

# ---- Output helpers (TTY-only colors) ----
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi
red()   { printf '%s%s%s' "$C_RED" "$*" "$C_OFF"; }
green() { printf '%s%s%s' "$C_GRN" "$*" "$C_OFF"; }
bold()  { printf '%s%s%s' "$C_BLD" "$*" "$C_OFF"; }

# ---- asinfo plumbing ----
asinfo_run() {
  if [[ -n "$SSH_HOST" ]]; then
    ssh "$SSH_HOST" "docker exec ${CONTAINER} asinfo $*"
  else
    docker exec "${CONTAINER}" asinfo "$@"
  fi
}

asinfo_set() {
  local param=$1 value=$2
  local cmd="${SET_CONFIG_PREFIX};storage-engine.${param}=${value}"
  printf '  set %-20s = %-10s ... ' "$param" "$value"
  local result
  if result=$(asinfo_run -v "$cmd" 2>&1); then
    if [[ "$result" == "ok" ]]; then
      green "ok"; echo
      return 0
    fi
  fi
  red "FAIL"; printf ' (%s)\n' "$result"
  return 1
}

asinfo_get_param() {
  local param=$1
  asinfo_run -v "$GET_CONFIG_NAMESPACE" \
    | tr ';' '\n' \
    | awk -F= -v p1="storage-engine.$param" -v p2="$param" '$1==p1 || $1==p2 {print $2; exit}'
}

verify_value() {
  local param=$1 expected=$2 actual normalized
  actual=$(asinfo_get_param "$param")
  # AS 8.x echoes size-suffixed values (K/M/G) back as raw bytes.
  # Normalize the expected value so the comparison succeeds either way.
  normalized=$(awk -v e="$expected" 'BEGIN{
    n = e + 0
    suf = toupper(substr(e, length(e), 1))
    if      (suf == "K") n *= 1024
    else if (suf == "M") n *= 1024*1024
    else if (suf == "G") n *= 1024*1024*1024
    printf "%d", n
  }')
  printf '  verify %-20s ... ' "$param"
  if [[ "$actual" == "$expected" || "$actual" == "$normalized" ]]; then
    green "$actual"; echo
    return 0
  fi
  red "MISMATCH"; printf ' (expected %s or %s, got %s)\n' "$expected" "$normalized" "$actual"
  return 1
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ans
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]]
}

# ---- Subcommand stubs (filled in Tasks 5–7) ----
cmd_help() { echo "TODO: filled in Task 7"; }
cmd_status() { echo "TODO: filled in Task 5"; }
cmd_throttle() { echo "TODO: filled in Task 6"; }
cmd_restore() { echo "TODO: filled in Task 6"; }

# ---- Main ----
main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1; shift ;;
      --ssh-host) SSH_HOST=$2; shift 2 ;;
      -h|--help) cmd_help; exit 0 ;;
      throttle-for-ibd|restore-steady-state|status) cmd=$1; shift ;;
      *) red "Unknown argument: $1"; echo; cmd_help; exit 2 ;;
    esac
  done
  case "$cmd" in
    throttle-for-ibd) cmd_throttle ;;
    restore-steady-state) cmd_restore ;;
    status) cmd_status ;;
    "") cmd_help; exit 2 ;;
  esac
}

main "$@"
