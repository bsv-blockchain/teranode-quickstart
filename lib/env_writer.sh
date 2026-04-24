#!/bin/bash
# Idempotent KEY=VALUE upsert for .env files.
# Usage: env_writer.sh <file> <KEY> <VALUE>
# - If KEY exists, rewrites that line.
# - Otherwise appends KEY=VALUE.
# - Preserves comments and ordering.
# Safe for repeated calls from update.sh / setup.sh.

set -e

FILE="$1"
KEY="$2"
VALUE="$3"

if [ -z "$FILE" ] || [ -z "$KEY" ]; then
    echo "usage: env_writer.sh <file> <KEY> <VALUE>" >&2
    exit 2
fi

touch "$FILE"

escaped_value=$(printf '%s' "$VALUE" | sed -e 's/[\/&]/\\&/g')

if grep -qE "^${KEY}=" "$FILE"; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -E "s|^${KEY}=.*|${KEY}=${escaped_value}|" "$FILE"
    else
        sed -i -E "s|^${KEY}=.*|${KEY}=${escaped_value}|" "$FILE"
    fi
else
    echo "${KEY}=${VALUE}" >> "$FILE"
fi
