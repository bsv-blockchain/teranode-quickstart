#!/bin/bash
# RPC credentials backfill.
#
# Teranode has no default RPC credentials: with rpc_user/rpc_pass unset,
# JSON-RPC rejects every request and Asset admin routes and dashboard login
# answer 401. setup.sh always writes both, but an .env copied by hand from
# .env.example leaves them blank.
#
# ensure_rpc_credentials <env_file>
#   Fills rpc_user (teranode, as setup.sh does) and rpc_pass (gen_secret) when
#   missing or blank, each on its own. Never replaces a value that is already
#   set. Never prints the password. Returns non-zero when a value cannot be
#   generated or written, so the caller decides whether that is fatal.
#   Sourced by start.sh.

# Values of every <key>= line, quotes and whitespace stripped, run together.
# Empty only when every line is blank: env_writer.sh rewrites all of them, so a
# value set on a later line (after a blank one copied from .env.example) must
# count as set.
_rpc_env_value() {
    grep -E "^$2=" "$1" 2>/dev/null | cut -d= -f2- | tr -d "[:space:]\"'" || true
}

ensure_rpc_credentials() {
    local env_file="$1"
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/secret.sh
    source "${lib_dir}/secret.sh"

    if [ -z "$(_rpc_env_value "$env_file" rpc_user)" ]; then
        "${lib_dir}/env_writer.sh" "$env_file" rpc_user teranode || return 1
        echo "Set rpc_user=teranode in ${env_file} (was blank)."
    fi

    if [ -z "$(_rpc_env_value "$env_file" rpc_pass)" ]; then
        local pass
        pass=$(gen_secret)
        if [ -z "$pass" ]; then
            echo "Could not generate rpc_pass (neither openssl nor xxd worked)." >&2
            return 1
        fi
        "${lib_dir}/env_writer.sh" "$env_file" rpc_pass "$pass" || return 1
        echo "Generated rpc_pass in ${env_file} (was blank)."
    fi
}
