#!/bin/bash
# setup-test-env.sh — Stand up the integration-test harness and seed it.
# Usage: cd t/harness && ./setup-test-env.sh
# Requires: podman-compose, psql (libpq client), curl, jq (or grep/cut fallback)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SCHEMA_SQL="$SCRIPT_DIR/../../db/schema.sql"
GITEA_URL="http://localhost:13000"
DB_HOST="127.0.0.1"
DB_PORT="25432"
DB_NAME="gitmsyncd_test"
DB_USER="gitmsyncd_test"
DB_PASS="testpass"
GITEA_ADMIN_USER="testadmin"
GITEA_ADMIN_PASS="testpass123"
GITEA_ADMIN_EMAIL="test@test.com"

# ── Helper: coloured output ────────────────────────────────────────
info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

# ── Helper: JSON field extraction ──────────────────────────────────
# Prefer jq; fall back to grep/cut for systems without it.
json_field() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$field // empty"
    else
        grep -o "\"$field\":[[:space:]]*\"[^\"]*\"" | head -1 | cut -d'"' -f4
    fi
}

# ── 1. Start containers ───────────────────────────────────────────
info "Starting containers with podman-compose ..."
podman-compose up -d

# ── 2. Wait for PostgreSQL to become healthy ───────────────────────
info "Waiting for PostgreSQL on $DB_HOST:$DB_PORT ..."
retries=0
max_retries=30
until PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c '\q' >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
        fail "PostgreSQL did not become ready after $max_retries attempts."
    fi
    sleep 2
done
ok "PostgreSQL is ready."

# ── 3. Load schema ────────────────────────────────────────────────
if [ ! -f "$SCHEMA_SQL" ]; then
    fail "Schema file not found: $SCHEMA_SQL"
fi
info "Loading schema from $SCHEMA_SQL ..."
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SCHEMA_SQL"
ok "Schema loaded."

# ── 4. Wait for Gitea to become healthy ────────────────────────────
info "Waiting for Gitea at $GITEA_URL ..."
retries=0
max_retries=40
until curl -sf "$GITEA_URL/api/v1/version" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
        fail "Gitea did not become ready after $max_retries attempts."
    fi
    sleep 3
done
ok "Gitea is ready."

# ── 5. Create Gitea admin user via CLI inside container ────────────
# Determine the container name — podman-compose names it based on the
# directory (harness) and the service name.
GITEA_CONTAINER=$(podman-compose ps -q test-gitea 2>/dev/null || true)
if [ -z "$GITEA_CONTAINER" ]; then
    # Fallback: try common naming patterns
    GITEA_CONTAINER=$(podman ps --filter "name=test-gitea" --format '{{.ID}}' | head -1)
fi
if [ -z "$GITEA_CONTAINER" ]; then
    fail "Could not determine Gitea container ID."
fi

info "Creating Gitea admin user '$GITEA_ADMIN_USER' ..."
podman exec "$GITEA_CONTAINER" gitea admin user create \
    --admin \
    --username "$GITEA_ADMIN_USER" \
    --password "$GITEA_ADMIN_PASS" \
    --email "$GITEA_ADMIN_EMAIL" \
    --must-change-password=false 2>/dev/null \
  || info "Admin user may already exist — continuing."
ok "Admin user ready."

# ── 6. Obtain API token ───────────────────────────────────────────
info "Requesting API token ..."
TOKEN_RESPONSE=$(curl -sf -X POST "$GITEA_URL/api/v1/users/$GITEA_ADMIN_USER/tokens" \
    -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASS" \
    -H 'Content-Type: application/json' \
    -d '{"name":"test-token","scopes":["all"]}')

TOKEN=$(echo "$TOKEN_RESPONSE" | json_field sha1)
if [ -z "$TOKEN" ]; then
    fail "Failed to obtain API token. Response: $TOKEN_RESPONSE"
fi
ok "API token obtained."

# ── Helper: create a repo and optional branches ────────────────────
create_repo() {
    local repo_name="$1"
    local auto_init="$2"
    shift 2
    # remaining args are branch names to create off main

    info "Creating repo '$repo_name' (auto_init=$auto_init) ..."
    curl -sf -X POST "$GITEA_URL/api/v1/user/repos" \
        -H "Authorization: token $TOKEN" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$repo_name\",\"auto_init\":$auto_init,\"default_branch\":\"main\"}" >/dev/null
    ok "Repo '$repo_name' created."

    for branch in "$@"; do
        info "  Creating branch '$branch' on '$repo_name' ..."
        curl -sf -X POST "$GITEA_URL/api/v1/repos/$GITEA_ADMIN_USER/$repo_name/branches" \
            -H "Authorization: token $TOKEN" \
            -H 'Content-Type: application/json' \
            -d "{\"new_branch_name\":\"$branch\",\"old_branch_name\":\"main\"}" >/dev/null
        ok "  Branch '$branch' created."
    done
}

# ── 7. Seed test repositories ─────────────────────────────────────
# Source repos (with content)
create_repo "test-repo-alpha" true   "develop"
create_repo "test-repo-beta"  true   "release/v1.0" "feature/x"
create_repo "test-repo-gamma" false                                # empty repo — edge case

# Mirror/destination repos (empty, for sync targets)
create_repo "test-repo-alpha-mirror" false
create_repo "test-repo-beta-mirror"  false
create_repo "test-repo-gamma-mirror" false

# ── 8. Print environment summary ──────────────────────────────────
echo ""
echo "========================================================"
echo " Test harness is ready."
echo "========================================================"
echo ""
echo "Run integration tests with:"
echo ""
echo "  export GITMSYNCD_TEST_DSN='dbi:Pg:dbname=$DB_NAME;host=$DB_HOST;port=$DB_PORT'"
echo "  export GITMSYNCD_TEST_DB_USER='$DB_USER'"
echo "  export GITMSYNCD_TEST_DB_PASS='$DB_PASS'"
echo "  export GITMSYNCD_TEST_GITEA_URL='$GITEA_URL'"
echo "  export GITMSYNCD_TEST_GITEA_TOKEN='$TOKEN'"
echo "  export GITMSYNCD_TEST_GITEA_USER='$GITEA_ADMIN_USER'"
echo "  export GITMSYNCD_TEST_GITEA_PASS='$GITEA_ADMIN_PASS'"
echo "  prove -Ilib t/"
echo ""
echo "Tear down with:  ./teardown.sh"
echo "========================================================"
