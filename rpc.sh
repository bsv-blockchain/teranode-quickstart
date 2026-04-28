#!/bin/bash
# Call Teranode's JSON-RPC endpoint (http://localhost:9292) with credentials
# from .env. Usage: ./rpc.sh <method> [param1] [param2] ...
#
# Examples:
#   ./rpc.sh getblockcount
#   ./rpc.sh getblock <hash>
#   ./rpc.sh generate 10
#
# Numeric / true / false / null args are sent unquoted; everything else is
# sent as a JSON string. For anything more exotic, use curl directly.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

set -a
[ -f .env ] && source .env
set +a

if [ -z "$rpc_user" ] || [ -z "$rpc_pass" ]; then
    echo "Error: rpc_user / rpc_pass not set in .env — run ./setup.sh" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: ./rpc.sh <method> [params...]" >&2
    exit 2
fi

METHOD="$1"
shift

PARAMS=""
for p in "$@"; do
    if [[ "$p" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [ "$p" = "true" ] || [ "$p" = "false" ] || [ "$p" = "null" ]; then
        PARAMS+="$p,"
    else
        escaped=$(printf '%s' "$p" | sed 's/\\/\\\\/g; s/"/\\"/g')
        PARAMS+="\"$escaped\","
    fi
done
PARAMS="${PARAMS%,}"

BODY="{\"jsonrpc\":\"1.0\",\"id\":\"quickstart\",\"method\":\"$METHOD\",\"params\":[$PARAMS]}"

response=$(curl -sS -u "$rpc_user:$rpc_pass" \
    -H 'Content-Type: application/json' \
    --data "$BODY" \
    http://localhost:9292/)

if command -v jq >/dev/null 2>&1; then
    printf '%s' "$response" | jq .
else
    printf '%s\n' "$response"
fi
