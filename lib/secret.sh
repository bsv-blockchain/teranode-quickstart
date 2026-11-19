#!/bin/bash
# Random secret for generated credentials (RPC password, Postgres password,
# client name suffix). Sourced by setup.sh and lib/rpc_creds.sh.

gen_secret() {
    openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32
}
