#!/bin/bash
# Reachability probe for full-mode operators.
# Tests that user-declared public endpoints are actually reachable from outside
# this host. We run curl / nc inside a one-shot throwaway container on the
# default bridge network so we never accidentally hit a loopback shortcut.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

ASSET_PUBLIC_URL="${1:-$ASSET_PUBLIC_URL}"
P2P_ADVERTISE_ADDR="${2:-$P2P_ADVERTISE_ADDR}"

check_asset_url() {
    if [ -z "$ASSET_PUBLIC_URL" ]; then
        echo_info "ASSET_PUBLIC_URL not set; skipping asset reachability probe (listen-only mode)."
        return 0
    fi
    echo_info "Probing ASSET_PUBLIC_URL=$ASSET_PUBLIC_URL ..."
    local probe_url="${ASSET_PUBLIC_URL%/}/health"
    local code
    code=$(docker run --rm curlimages/curl:8.8.0 -s -o /dev/null -w '%{http_code}' --max-time 15 "$probe_url" 2>/dev/null || echo "000")
    case "$code" in
        200|204|301|302|404)
            echo_success "asset endpoint reachable (HTTP $code from $probe_url)."
            ;;
        000)
            echo_error "asset endpoint unreachable — connection failed or DNS error."
            echo_warning "Check: reverse-proxy running, TLS cert valid, firewall open, DNS pointing here."
            return 1
            ;;
        *)
            echo_warning "asset endpoint returned HTTP $code. Probably reachable but misconfigured upstream."
            ;;
    esac
    return 0
}

check_p2p_addr() {
    if [ -z "$P2P_ADVERTISE_ADDR" ]; then
        echo_info "P2P_ADVERTISE_ADDR not set; skipping P2P probe (listen-only mode)."
        return 0
    fi
    local host="${P2P_ADVERTISE_ADDR%:*}"
    local port="${P2P_ADVERTISE_ADDR##*:}"
    if [ "$host" = "$port" ] || [ -z "$port" ]; then
        echo_error "P2P_ADVERTISE_ADDR must be host:port (got '$P2P_ADVERTISE_ADDR')"
        return 1
    fi
    echo_info "Probing P2P TCP connect to $host:$port ..."
    if docker run --rm busybox:1.36 sh -c "nc -z -w 10 $host $port" 2>/dev/null; then
        echo_success "P2P port reachable."
        return 0
    fi
    echo_error "P2P port NOT reachable. Check firewall / NAT / port-forward on $host:$port."
    return 1
}

main() {
    echo_green "=== Reachability probe ==="
    local failed=0
    check_asset_url || failed=1
    echo ""
    check_p2p_addr  || failed=1
    echo ""
    if [ "$failed" -eq 0 ]; then
        echo_green "=== Reachable ==="
        return 0
    fi
    echo_yellow "=== Some probes failed. Fix network exposure or stay in listen-only mode. ==="
    return 1
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main
fi
