#!/bin/bash
# Shared gRPC admin API key for every Teranode service.
#
# Teranode's Blockchain service refuses to start without grpc_admin_api_key,
# and every other service (and teranode-cli via docker exec) needs the same
# value to call it. env_file: .env passes it to all Teranode containers.
#
# ensure_admin_api_key <env_file>
#   Generates a random key when grpc_admin_api_key is missing or blank.
#   Never replaces a value that is already set, so an operator-chosen key or
#   one written by an earlier run survives. Sourced by setup.sh and start.sh.

ensure_admin_api_key() {
    local env_file="$1"
    local current

    current=$(grep -E '^grpc_admin_api_key=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
    if [ -n "$current" ]; then
        return 0
    fi

    local lib_dir key
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    key=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 64)
    "${lib_dir}/env_writer.sh" "$env_file" grpc_admin_api_key "$key"
    echo "Generated grpc_admin_api_key in ${env_file}."
}
