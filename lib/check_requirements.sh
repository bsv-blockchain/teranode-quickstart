#!/bin/bash
# System requirements check for Teranode Quickstart.
# Teranode is heavy: many services, ~16-32GB RAM, ~1TB disk depending on network.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/colors.sh"

NETWORK="${1:-testnet}"

check_docker() {
    echo_info "Checking Docker..."
    if ! command -v docker &> /dev/null; then
        echo_error "Docker not found. Install from https://docs.docker.com/get-docker/"
        return 1
    fi
    echo_success "Found: docker ($(docker --version))"

    if ! docker info &> /dev/null; then
        echo_error "Docker daemon not running. Start Docker Desktop or systemctl start docker."
        return 1
    fi
    echo_success "Docker daemon is running."
    return 0
}

check_compose() {
    echo_info "Checking Docker Compose..."
    if ! docker compose version &> /dev/null; then
        echo_error "Docker Compose v2 not found. Update Docker or install the compose plugin."
        return 1
    fi
    echo_success "Found: $(docker compose version | head -1)"
    return 0
}

check_disk_space() {
    echo_info "Checking disk space..."
    local required_gb
    case "$NETWORK" in
        mainnet)     required_gb=2000 ;;
        testnet)     required_gb=300 ;;
        teratestnet) required_gb=100 ;;
        regtest)     required_gb=20 ;;
        *)           required_gb=300 ;;
    esac
    echo_info "Network: $NETWORK — recommended free space: ${required_gb}GB"

    local available_gb
    if [[ "$OSTYPE" == "darwin"* ]]; then
        available_gb=$(df -g / | awk 'NR==2 {print $4}')
    else
        available_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    fi
    echo_info "Available: ${available_gb}GB on /"

    if [ "$available_gb" -lt "$required_gb" ]; then
        echo_warning "Less than recommended free space. Node may fill the disk during sync."
        return 1
    fi
    echo_success "Sufficient disk space."
    return 0
}

check_memory() {
    echo_info "Checking RAM..."
    local total_gb
    if [[ "$OSTYPE" == "darwin"* ]]; then
        total_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    else
        total_gb=$(free -g | awk 'NR==2 {print $2}')
    fi
    echo_info "Total RAM: ${total_gb}GB"

    local minimum_gb recommended_gb
    case "$NETWORK" in
        mainnet)     minimum_gb=128; recommended_gb=256 ;;
        testnet)     minimum_gb=16;  recommended_gb=32  ;;
        teratestnet) minimum_gb=16;  recommended_gb=32  ;;
        regtest)     minimum_gb=4;   recommended_gb=8   ;;
        *)           minimum_gb=16;  recommended_gb=32  ;;
    esac

    if [ "$total_gb" -lt "$minimum_gb" ]; then
        echo_warning "Below minimum (${minimum_gb}GB for $NETWORK). Node is likely to OOM during sync."
        return 1
    fi
    if [ "$total_gb" -lt "$recommended_gb" ]; then
        echo_warning "Below recommended (${recommended_gb}GB for $NETWORK). Expect degraded performance."
        return 1
    fi
    echo_success "Sufficient RAM for $NETWORK (${total_gb}GB >= ${recommended_gb}GB recommended)."
    return 0
}

check_cpu() {
    echo_info "Checking CPU..."
    local cores
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cores=$(sysctl -n hw.ncpu)
    else
        cores=$(nproc 2>/dev/null || echo 1)
    fi
    echo_info "Cores: $cores"

    local recommended_cores
    case "$NETWORK" in
        mainnet)     recommended_cores=16 ;;
        testnet)     recommended_cores=8  ;;
        teratestnet) recommended_cores=8  ;;
        regtest)     recommended_cores=4  ;;
        *)           recommended_cores=8  ;;
    esac

    if [ "$cores" -lt "$recommended_cores" ]; then
        echo_warning "Below recommended (${recommended_cores} cores for $NETWORK). Microservices will contend for CPU."
        return 1
    fi
    echo_success "Sufficient cores for $NETWORK (${cores} >= ${recommended_cores} recommended)."
    return 0
}

check_ports() {
    echo_info "Checking for port conflicts..."
    local ports=(3000 3005 5432 8000 8080 8081 8084 8090 9090 9092 9292 9905)
    local conflicts=()
    for port in "${ports[@]}"; do
        if lsof -i ":$port" 2>/dev/null | grep -q LISTEN; then
            conflicts+=("$port")
        fi
    done
    if [ ${#conflicts[@]} -gt 0 ]; then
        echo_warning "Ports already in use: ${conflicts[*]}"
        echo_warning "Stop the processes holding them or adjust HOST_IP / remap ports in docker-compose.yml"
        return 1
    fi
    echo_success "No port conflicts."
    return 0
}

main() {
    echo_green "=== Teranode Quickstart: System Check ==="
    echo ""
    local failed=0
    check_docker  || failed=1; echo ""
    check_compose || failed=1; echo ""
    check_disk_space || failed=1; echo ""
    check_memory  || failed=1; echo ""
    check_cpu     || failed=1; echo ""
    check_ports   || failed=1; echo ""
    if [ "$failed" -eq 0 ]; then
        echo_green "=== All checks passed ==="
        return 0
    fi
    echo_yellow "=== Warnings above — review before proceeding ==="
    return 1
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
