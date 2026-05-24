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
    local escaped
    printf -v escaped '%q ' "$@"
    ssh "$SSH_HOST" "docker exec ${CONTAINER} asinfo ${escaped}"
  else
    docker exec "${CONTAINER}" asinfo "$@"
  fi
}

asinfo_set() {
  local param=$1 value=$2
  local cmd="${SET_CONFIG_PREFIX};${param}=${value}"
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
cmd_help() {
  cat <<'EOF'
aerospike-tune.sh — live Aerospike tuning for Teranode IBD throughput

USAGE
  ./aerospike-tune.sh [GLOBAL_FLAGS] <command>

COMMANDS
  throttle-for-ibd        Apply IBD-throttle values (raises defrag-lwm-pct to 70,
                          drops defrag-sleep to 0, doubles caches). Reversible.
  restore-steady-state    Revert to values that mirror config/aerospike.conf.
  status                  Show namespace stats + defrag drain estimate.
  -h, --help              Show this help.

GLOBAL FLAGS
  -y, --yes               Skip the [y/N] confirmation prompt.
  --ssh-host <name>       Run asinfo via 'ssh <name> docker exec aerospike asinfo ...'.

EXAMPLES
  ./aerospike-tune.sh status
  ./aerospike-tune.sh throttle-for-ibd
  ./aerospike-tune.sh restore-steady-state -y
  ./aerospike-tune.sh --ssh-host bsva-ovh-teranode-eu-3 status

See docs/specs/2026-05-24-aerospike-ibd-throttle.md for design and rationale.
EOF
}

# Parse a single key out of a semicolon-separated asinfo response.
get_stat() {
  local blob=$1 key=$2
  echo "$blob" | tr ';' '\n' | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

human_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b == "" || b+0 == 0) { print "0 B"; exit }
    split("B KiB MiB GiB TiB PiB", u);
    i=1; while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

human_duration() {
  awk -v s="$1" 'BEGIN{
    s = int(s);
    h = int(s/3600); s %= 3600;
    m = int(s/60);   s %= 60;
    printf "%dh %dm %ds", h, m, s
  }'
}

# Print a stat row, substituting "—" when the key is missing/empty.
stat_or_dash() {
  local v=$1
  [[ -z "$v" ]] && echo "—" || echo "$v"
}

cmd_status() {
  bold "Aerospike namespace: ${NAMESPACE}"; echo
  echo "─────────────────────────────────────────────────"
  local stats sleep_us used total pct defrag_q drain_sec free_wb
  stats=$(asinfo_run -v "namespace/${NAMESPACE}")
  sleep_us=$(asinfo_get_param "defrag-sleep")
  # AS 8.x uses data_* keys, not device_*.
  used=$(get_stat "$stats" data_used_bytes);   used=${used:-0}
  total=$(get_stat "$stats" data_total_bytes); total=${total:-0}
  pct=$(awk -v u="$used" -v t="$total" 'BEGIN{ if (t>0) printf "%.1f%%", 100*u/t; else print "?" }')
  defrag_q=$(get_stat "$stats" defrag_q); defrag_q=${defrag_q:-0}
  free_wb=$(get_stat "$stats" free_wblocks)
  drain_sec=$(awk -v s="$sleep_us" -v q="$defrag_q" 'BEGIN{ printf "%d", (s*q)/1000000 }')

  printf "  %-26s %s\n"            "stop_writes"            "$(stat_or_dash "$(get_stat "$stats" stop_writes)")"
  printf "  %-26s %s\n"            "hwm_breached"           "$(stat_or_dash "$(get_stat "$stats" hwm_breached)")"
  printf "  %-26s %s\n"            "client_write_error"     "$(stat_or_dash "$(get_stat "$stats" client_write_error)")"
  printf "  %-26s %s / %s (%s)\n"  "data usage"             "$(human_bytes "$used")" "$(human_bytes "$total")" "$pct"
  printf "  %-26s %s\n"            "data_avail_pct"         "$(stat_or_dash "$(get_stat "$stats" data_avail_pct)")"
  printf "  %-26s %s\n"            "free_wblocks"           "$(stat_or_dash "$free_wb")"
  printf "  %-26s %s\n"            "defrag_q"               "$defrag_q"
  printf "  %-26s %s µs\n"         "defrag-sleep (current)" "$sleep_us"
  printf "  %-26s %s  (lower bound; ignores per-wblock I/O)\n" "defrag drain estimate" "$(human_duration "$drain_sec")"
}
# Print a (param, current, → target) table for the named mode.
print_diff_table() {
  local mode=$1 i param current target
  printf '  %-20s %-12s    %-12s\n' "param" "current" "→ target"
  printf '  %-20s %-12s    %-12s\n' "-----" "-------" "--------"
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    if [[ "$mode" == "throttle" ]]; then
      target=${THROTTLE_VALUES[$i]}
    else
      target=${STEADY_VALUES[$i]}
    fi
    current=$(asinfo_get_param "$param")
    printf '  %-20s %-12s → %-12s\n' "$param" "$current" "$target"
  done
}

# Apply the named mode's values and verify each via get-config.
apply_values() {
  local mode=$1 i param target failed=0
  for i in "${!PARAMS[@]}"; do
    param=${PARAMS[$i]}
    if [[ "$mode" == "throttle" ]]; then
      target=${THROTTLE_VALUES[$i]}
    else
      target=${STEADY_VALUES[$i]}
    fi
    asinfo_set "$param" "$target" || failed=1
    verify_value "$param" "$target" || failed=1
  done
  return $failed
}

cmd_throttle() {
  bold "Aerospike IBD throttle"; echo " — namespace ${NAMESPACE}"
  echo
  echo "Will apply (values are TEMPORARY — run 'restore-steady-state' after IBD):"
  print_diff_table throttle
  echo
  confirm || { echo "Aborted."; exit 1; }
  echo
  apply_values throttle
}

cmd_restore() {
  bold "Aerospike restore-steady-state"; echo " — namespace ${NAMESPACE}"
  echo
  echo "Will apply (values mirror config/aerospike.conf):"
  print_diff_table restore
  echo
  confirm || { echo "Aborted."; exit 1; }
  echo
  apply_values restore
}

# ---- Main ----
main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) ASSUME_YES=1; shift ;;
      --ssh-host)
        [[ $# -ge 2 ]] || { red "Missing argument for --ssh-host"; echo; exit 2; }
        SSH_HOST=$2; shift 2 ;;
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
