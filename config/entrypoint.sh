#!/bin/bash
set -eo pipefail

# Wait for a service's TCP port + a grace period before continuing.
# Usage: wait_for_service <host> <port> <grace_seconds>
wait_for_service() {
  /app/wait.sh "$1" "$2" "$3"
}

if [ "$USE_LOCAL_AEROSPIKE" = "true" ]; then
  wait_for_service aerospike 3000 2
fi

# postgres: 11s grace because postmaster opens the TCP port before
# accepting connections (postmaster vs pg_isready window).
if [ "$USE_LOCAL_POSTGRES" = "true" ]; then
  wait_for_service postgres 5432 11
fi

if [ "$USE_LOCAL_KAFKA" = "true" ]; then
  wait_for_service kafka-shared 9092 0
fi

exec /app/teranode.run "$@"
