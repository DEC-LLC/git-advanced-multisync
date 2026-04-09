#!/bin/bash
# teardown.sh — Stop and remove all test-harness containers and volumes.
set -euo pipefail
cd "$(dirname "$0")"
podman-compose down -v
echo "Test harness torn down."
