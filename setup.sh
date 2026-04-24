#!/bin/bash
# Interactive first-time setup for Teranode Quickstart.
# Picks network + mode, gathers credentials, writes .env and settings_local.conf.

set -e

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
        echo "  $i) $opt" >&2
        i=$((i + 1))
    done
    local choice
    while true; do
        read -r -p "Selection [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice - 1))]}"
            return
        fi
        echo_warning "Pick a number between 1 and ${#options[@]}." >&2
    done
}

gen_secret() {
    openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32
}

echo_green "=================================================="
echo_green "  Teranode Quickstart — first-time setup"
echo_green "=================================================="
echo ""

NETWORK=$(pick_one "Which network?" "testnet" "mainnet" "regtest")
echo_info "Selected: $NETWORK"
echo ""

if [ "$NETWORK" = "mainnet" ]; then
    echo_yellow "WARNING: Teranode mainnet support is still maturing."
    echo_yellow "The upstream project has not declared production readiness."
    echo_yellow "Do not run this on consensus-critical infrastructure yet."
    confirm=$(prompt "Type 'I understand' to continue" "")
    if [ "$confirm" != "I understand" ]; then
        echo_error "Aborting."
        exit 1
    fi
    echo ""
fi

echo_info "Running system checks for $NETWORK..."
if ! "${REPO_ROOT}/lib/check_requirements.sh" "$NETWORK"; then
    echo_warning "Some checks warned. Continue anyway?"
    ans=$(prompt "Proceed? (y/N)" "N")
    [[ "$ans" =~ ^[Yy] ]] || exit 1
fi
echo ""

MODE=$(pick_one "Run mode?" "listen_only (safe default, no public exposure)" "full (requires public endpoints)")
case "$MODE" in
    "listen_only"*) MODE=listen_only ;;
    "full"*)        MODE=full ;;
esac
echo_info "Mode: $MODE"
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
    while [ -z "$P2P_ADVERTISE_ADDR" ]; do
        P2P_ADVERTISE_ADDR=$(prompt "P2P advertise addr (host:9905)" "")
    done
    echo_info "Reachability will be probed automatically after start.sh."
    echo ""
fi

CLIENT_NAME=$(prompt "Client name (shown in explorer)" "My Teranode")
echo ""

rpc_choice=$(pick_one "RPC credentials?" "auto-generate" "enter manually")
case "$rpc_choice" in
    auto*)
        RPC_USER="teranode"
        RPC_PASS=$(gen_secret)
        ;;
    enter*)
        RPC_USER=""
        while [ -z "$RPC_USER" ]; do
            RPC_USER=$(prompt "RPC user" "teranode")
        done
        RPC_PASS=""
        while [ -z "$RPC_PASS" ]; do
            RPC_PASS=$(prompt "RPC password" "$(gen_secret)")
        done
        ;;
esac

HOST_IP=$(prompt "Host IP to bind ports (127.0.0.1 = localhost only)" "127.0.0.1")

echo ""
echo_green "Summary"
echo "  Network:     $NETWORK"
echo "  Mode:        $MODE"
echo "  Client name: $CLIENT_NAME"
[ -n "$ASSET_PUBLIC_URL" ]  && echo "  Asset URL:   $ASSET_PUBLIC_URL"
[ -n "$P2P_ADVERTISE_ADDR" ] && echo "  P2P addr:    $P2P_ADVERTISE_ADDR"
[ -n "$RPC_USER" ]          && echo "  RPC user:    $RPC_USER  (password hidden)"
echo "  Host IP:     $HOST_IP"
echo ""
confirm=$(prompt "Write .env? (Y/n)" "Y")
[[ "$confirm" =~ ^[Nn] ]] && { echo_warning "Aborted — nothing written."; exit 0; }

if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo_info "Created .env from .env.example"
fi

"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" TERANODE_NETWORK       "$NETWORK"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" SETTINGS_CONTEXT       "docker.m"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" HOST_IP                "$HOST_IP"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" LISTEN_MODE            "$([ "$MODE" = "listen_only" ] && echo listen_only || echo '')"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" ASSET_PUBLIC_URL       "$ASSET_PUBLIC_URL"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" P2P_ADVERTISE_ADDR     "$P2P_ADVERTISE_ADDR"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" RPC_USER               "$RPC_USER"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" RPC_PASS               "$RPC_PASS"
"${REPO_ROOT}/lib/env_writer.sh" "$ENV_FILE" CLIENT_NAME            "$CLIENT_NAME"

echo ""
echo_green "Setup complete."
echo_info "Next: ./start.sh"
