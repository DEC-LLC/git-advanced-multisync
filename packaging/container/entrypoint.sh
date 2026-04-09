#!/bin/bash
# gitmsyncd container entrypoint
# Starts both web UI and worker in one container.
# Worker runs in background, web runs in foreground (PID 1 for signal handling).

set -e

WORKER_SET="${GITMSYNCD_WORKER_SET:-default}"

echo "[entrypoint] starting gitmsyncd-worker --set=$WORKER_SET in background"
perl /opt/gitmsyncd/bin/gitmsyncd-worker.pl --set="$WORKER_SET" &
WORKER_PID=$!

# Trap SIGTERM/SIGINT — forward to both processes
cleanup() {
    echo "[entrypoint] shutting down..."
    kill -TERM "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[entrypoint] starting gitmsyncd web on ${GITMSYNCD_LISTEN:-http://0.0.0.0:9097}"
exec perl /opt/gitmsyncd/bin/gitmsyncd.pl
