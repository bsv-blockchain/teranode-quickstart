#!/bin/bash
# Thin wrapper around teranode-cli running inside the blockchain container.
# Usage: ./cli.sh getinfo | ./cli.sh setfsmstate --fsmstate RUNNING | etc.

set -eo pipefail

if ! docker ps --format '{{.Names}}' | grep -q '^blockchain$'; then
    echo "Error: blockchain container is not running. Start with ./start.sh" >&2
    exit 1
fi

exec docker exec -it blockchain teranode-cli "$@"
