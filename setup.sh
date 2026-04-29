#!/bin/bash
# Interactive first-time setup for Teranode Quickstart.
# Picks network + mode, gathers credentials, and writes .env.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

source "${REPO_ROOT}/lib/colors.sh"

ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

prompt() {
    local msg="$1"
    local default="$2"
    local var
    if [ -n "$default" ]; then
        read -r -p "$(echo -e "${CYAN}${msg}${NC} [${default}]: ")" var
        echo "${var:-$default}"
    else
        read -r -p "$(echo -e "${CYAN}${msg}${NC}: ")" var
        echo "$var"
    fi
}

pick_one() {
    local prompt_msg="$1"; shift
    local options=("$@")
    local i=1
    echo_cyan "$prompt_msg" >&2
    for opt in "${options[@]}"; do
        if [ "$i" -eq 1 ]; then
            echo "  $i) $opt  (default — press Enter)" >&2
        else
            echo "  $i) $opt" >&2
        fi
        i=$((i + 1))
    done
    local choice
    while true; do
        read -r -p "Selection [1-${#options[@]}]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice - 1))]}"
            return
        fi
        echo_warning "Pick a number between 1 and ${#options[@]}." >&2
    done
}

# yes_no <prompt> [Y|N]
# Default Y → enter accepts yes. Default N → enter accepts no.
# Returns 0 on yes, 1 on no.
yes_no() {
    local msg="$1"
    local default="${2:-Y}"
    local hint
    if [ "$default" = "Y" ]; then hint="Y/n"; else hint="y/N"; fi
    local var
    while true; do
        read -r -p "$(echo -e "${CYAN}${msg}${NC} [${hint}]: ")" var
        var="${var:-$default}"
        case "$var" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo_warning "Answer y or n." >&2 ;;
        esac
    done
}

gen_secret() {
    openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32
}

echo_green "=================================================="
echo_green "  Teranode Quickstart — first-time setup"
echo_green "=================================================="
echo ""

NETWORK=$(pick_one "Which network?" "teratestnet" "testnet" "mainnet" "regtest")
echo_info "Selected: $NETWORK"
echo ""

if [ "$NETWORK" = "mainnet" ]; then
    echo_yellow "Mainnet has substantial resource requirements; review docs/NETWORKS.md before continuing."
    echo ""
fi

echo_cyan "Run mode:"
echo "   listen_only  — safe default, no public exposure"
echo "   full         — requires public endpoints (asset URL + P2P advertise addr)"
if yes_no "Run in full mode?" N; then
    MODE=full
else
    MODE=listen_only
fi
echo_info "Mode: $MODE"
echo ""

echo_cyan "Archival mode runs the optional blockpersister service, which keeps full"
echo_cyan "raw block history on disk. Most operators don't need it (Teranode prunes"
echo_cyan "spent UTXOs after 288 blocks by default). Useful for indexers / explorers /"
echo_cyan "research. Costs significant disk (multiple TB on mainnet)."
if yes_no "Enable archival mode?" N; then ARCHIVAL=true; else ARCHIVAL=false; fi
echo ""

echo_cyan "Monitoring stack: Grafana dashboards, Prometheus, Aerospike exporter, and"
echo_cyan "the Kafka (Redpanda) console. Optional — handy for visibility while syncing"
echo_cyan "and tuning, but not required to run a node. Adds ~4 containers and ~1GB RAM."
if yes_no "Enable monitoring stack?" Y; then MONITORING=true; else MONITORING=false; fi
echo ""

PROFILES="legacy,p2p"
[ "$ARCHIVAL" = "true" ]   && PROFILES="${PROFILES},blockpersister"
[ "$MONITORING" = "true" ] && PROFILES="${PROFILES},monitoring"

echo_info "Running system checks for $NETWORK..."
if ! "${REPO_ROOT}/lib/check_requirements.sh" "$NETWORK" "$PROFILES"; then
    echo_warning "Some checks warned."
    yes_no "Proceed anyway?" N || exit 1
fi
echo ""

ASSET_PUBLIC_URL=""
P2P_ADVERTISE_ADDR=""
if [ "$MODE" = "full" ]; then
    echo_cyan "Full mode requires you to expose this node to the public internet."
    echo_cyan "Quickstart does NOT configure a reverse proxy, TLS, or tunnel for you."
    echo_cyan "Set these up yourself (Caddy, Cloudflare Tunnel, nginx, VPS, etc.)"
    echo_cyan "then tell us the resulting public addresses:"
    echo ""
    ASSET_BASE_URL=""
    while [ -z "$ASSET_BASE_URL" ]; do
        ASSET_BASE_URL=$(prompt "Asset API public base URL (https://node.example.com)" "")
    done
    ASSET_PUBLIC_URL="${ASSET_BASE_URL%/}/api/v1"
    echo_cyan "P2P advertise address — libp2p multiaddr format:"
    echo "   /dns4/<hostname>/tcp/9905    (DNS, recommended)"
    echo "   /ip4/<ip>/tcp/9905           (IPv4 literal)"
    echo "   /ip6/<ip>/tcp/9905           (IPv6 literal)"
    while [ -z "$P2P_ADVERTISE_ADDR" ]; do
        P2P_ADVERTISE_ADDR=$(prompt "P2P advertise addr" "")
    done
    echo_info "Reachability will be probed automatically after start.sh."
    echo ""
fi

default_client_name="teranode-$(gen_secret | head -c 4)"
CLIENT_NAME=$(prompt "Client name (shown in explorer)" "$default_client_name")
echo ""

if yes_no "Auto-generate RPC credentials?" Y; then
    RPC_USER="teranode"
    RPC_PASS=$(gen_secret)
else
    RPC_USER=""
    while [ -z "$RPC_USER" ]; do
        RPC_USER=$(prompt "RPC user" "teranode")
    done
    RPC_PASS=""
    while [ -z "$RPC_PASS" ]; do
        RPC_PASS=$(prompt "RPC password" "$(gen_secret)")
    done
fi

echo ""
echo_cyan "Host IP binding — controls ONLY these 3 ports:"
echo "   8090  asset viewer UI                  (always on)"
echo "   8000  asset-cache public API           (p2p profile only)"
echo "   9905  P2P inbound peer connections     (p2p profile only)"
echo_cyan "Everything else (RPC, Grafana, Prometheus, Kafka, Postgres, Aerospike) stays"
echo_cyan "hardcoded to 127.0.0.1 regardless. Options:"
echo "   127.0.0.1  localhost only (safe default, works behind NAT)"
echo "   0.0.0.0    all interfaces (needed when another host / reverse proxy needs to reach these)"
HOST_IP=$(prompt "Host IP" "127.0.0.1")

echo ""
echo_green "Summary"
echo "  Network:     $NETWORK"
echo "  Mode:        $MODE"
echo "  Archival:    $ARCHIVAL"
echo "  Monitoring:  $MONITORING"
echo "  Client name: $CLIENT_NAME"
[ -n "$ASSET_PUBLIC_URL" ]  && echo "  Asset URL:   $ASSET_PUBLIC_URL"
[ -n "$P2P_ADVERTISE_ADDR" ] && echo "  P2P addr:    $P2P_ADVERTISE_ADDR"
[ -n "$RPC_USER" ]          && echo "  RPC user:    $RPC_USER  (password hidden)"
echo "  Host IP:     $HOST_IP"
echo ""
if ! yes_no "Write .env?" Y; then
    echo_warning "Aborted — nothing written."
    exit 0
fi

if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    echo_info "Backed up existing .env to .env.bak"
fi
cp "$ENV_EXAMPLE" "$ENV_FILE"
echo_info "Wrote fresh .env from .env.example"

case "$NETWORK" in
    mainnet)     MIN_FEE="0.00000100"; BLOCK_MAX="4294967296"; EXCESSIVE="10737418240" ;;
    testnet)     MIN_FEE="0.00000001"; BLOCK_MAX="4294967296"; EXCESSIVE="10737418240" ;;
    regtest)     MIN_FEE="0";          BLOCK_MAX="4294967296"; EXCESSIVE="10737418240" ;;
    teratestnet) MIN_FEE="0.00000001"; BLOCK_MAX="1073741824"; EXCESSIVE="1073741824"  ;;
esac

"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" network                  "$NETWORK"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" SETTINGS_CONTEXT         "docker.m"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" HOST_IP                  "$HOST_IP"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" COMPOSE_PROFILES         "$PROFILES"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" listen_mode              "$MODE"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" asset_httpPublicAddress  "$ASSET_PUBLIC_URL"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" p2p_advertise_addresses  "$P2P_ADVERTISE_ADDR"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" rpc_user                 "$RPC_USER"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" rpc_pass                 "$RPC_PASS"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" clientName               "$CLIENT_NAME"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" minminingtxfee           "$MIN_FEE"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" blockmaxsize             "$BLOCK_MAX"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" excessiveblocksize       "$EXCESSIVE"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" POSTGRES_PASSWORD        "$(gen_secret)"

echo ""
echo_green "Setup complete."
if [ "$NETWORK" = "teratestnet" ]; then
    echo_info "Next — pick one:"
    echo_info "  ./start.sh"
    echo_info "    (sync from scratch)"
    echo_info "  ./seed.sh 000000002ea94a515ad9fd40d710fd249fe8610acef7b74f459446812d565187 && ./start.sh"
    echo_info "    (seed from the canonical teratestnet snapshot first — much faster)"
else
    echo_info "Next: ./start.sh"
fi
