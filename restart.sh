#!/bin/bash
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${REPO_ROOT}/stop.sh"
sleep 2
"${REPO_ROOT}/start.sh"
