#!/bin/bash
# Wait for a TCP port to become reachable, then sleep a grace period.
# Usage: wait.sh <host> <port> <grace_seconds>

set -eo pipefail

host="$1"
port="$2"
waitfor="$3"

until (echo > /dev/tcp/"$host"/"$port") &>/dev/null; do
  >&2 echo "$host:$port is unavailable - sleeping"
  sleep 1
done

>&2 echo "$host:$port is up - waiting ${waitfor}s grace period"
sleep "$waitfor"
>&2 echo "$host:$port ready"
