CREATE TABLE IF NOT EXISTS owners (
  id BIGSERIAL PRIMARY KEY,
  provider VARCHAR(32) NOT NULL CHECK (provider IN ('github','gitlab')),
  owner_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(provider, owner_name)
);

CREATE TABLE IF NOT EXISTS owner_mappings (
  id BIGSERIAL PRIMARY KEY,
  source_owner_id BIGINT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
  target_owner_id BIGINT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
  direction VARCHAR(32) NOT NULL CHECK (direction IN ('github_to_gitlab','gitlab_to_github','bidirectional')),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(source_owner_id, target_owner_id, direction)
);

CREATE TABLE IF NOT EXISTS repo_mappings (
  id BIGSERIAL PRIMARY KEY,
  source_provider VARCHAR(32) NOT NULL CHECK (source_provider IN ('github','gitlab','gitea')),
  source_full_path TEXT NOT NULL,
  target_provider VARCHAR(32) NOT NULL CHECK (target_provider IN ('github','gitlab','gitea')),
  target_full_path TEXT NOT NULL,
  direction VARCHAR(32) NOT NULL CHECK (direction IN ('github_to_gitlab','gitlab_to_github','bidirectional')),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  branch_filter TEXT DEFAULT NULL,
  profile_id BIGINT DEFAULT NULL,  -- FK added after sync_profiles table created
  -- Debug taps: like tcpdump for git syncs. Two checkpoints:
  --   source_tap: fires after clone — "what did we get from source?"
  --   target_tap: fires after push  — "what landed on the target?"
  -- Each independently toggleable. Auto-expires. Capped file count.
  -- Detail goes to sync_job_events ONLY, never syslog.
  debug_source_tap BOOLEAN NOT NULL DEFAULT FALSE,
  debug_target_tap BOOLEAN NOT NULL DEFAULT FALSE,
  debug_expires_at TIMESTAMPTZ DEFAULT NULL,
  debug_file_cap INT DEFAULT 5,
  debug_enabled_by TEXT DEFAULT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(source_provider, source_full_path, target_provider, target_full_path, direction)
);

-- Migrations for existing installs
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS branch_filter TEXT DEFAULT NULL;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS profile_id BIGINT;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS debug_source_tap BOOLEAN DEFAULT FALSE;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS debug_target_tap BOOLEAN DEFAULT FALSE;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS debug_expires_at TIMESTAMPTZ;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS debug_file_cap INT DEFAULT 10;
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS debug_enabled_by TEXT;

CREATE TABLE IF NOT EXISTS providers (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  provider_type VARCHAR(32) NOT NULL CHECK (provider_type IN ('github','gitlab','gitea')),
  base_url TEXT,  -- NULL for github.com (uses api.github.com)
  api_token TEXT NOT NULL,
  clone_protocol VARCHAR(8) NOT NULL DEFAULT 'https' CHECK (clone_protocol IN ('https','ssh')),
  push_protocol VARCHAR(8) NOT NULL DEFAULT 'https' CHECK (push_protocol IN ('https','ssh')),
  ssh_key_path TEXT DEFAULT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_tested_at TIMESTAMPTZ,
  test_status VARCHAR(32) DEFAULT 'untested'
);

-- Migrations for existing installs: provider SSH columns
ALTER TABLE providers ADD COLUMN IF NOT EXISTS clone_protocol VARCHAR(8) DEFAULT 'https';
ALTER TABLE providers ADD COLUMN IF NOT EXISTS push_protocol VARCHAR(8) DEFAULT 'https';
ALTER TABLE providers ADD COLUMN IF NOT EXISTS ssh_key_path TEXT DEFAULT NULL;

CREATE TABLE IF NOT EXISTS sync_profiles (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  direction VARCHAR(32) NOT NULL CHECK (direction IN ('github_to_gitlab','gitlab_to_github')),
  source_owner TEXT NOT NULL,
  target_owner TEXT NOT NULL,
  source_provider_id BIGINT REFERENCES providers(id),
  target_provider_id BIGINT REFERENCES providers(id),
  protected_branches TEXT NOT NULL DEFAULT 'main master develop',
  conflict_policy VARCHAR(32) NOT NULL DEFAULT 'ff-only',
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sync_interval_minutes INT DEFAULT NULL,
  next_sync_at TIMESTAMPTZ DEFAULT NULL,
  last_synced_at TIMESTAMPTZ DEFAULT NULL,
  sync_locked BOOLEAN DEFAULT FALSE,
  sync_locked_at TIMESTAMPTZ DEFAULT NULL,
  sync_locked_by VARCHAR(64) DEFAULT NULL
);

-- Migration for existing installs: add scheduler columns
ALTER TABLE sync_profiles ADD COLUMN IF NOT EXISTS sync_interval_minutes INT DEFAULT NULL;
ALTER TABLE sync_profiles ADD COLUMN IF NOT EXISTS next_sync_at TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE sync_profiles ADD COLUMN IF NOT EXISTS last_synced_at TIMESTAMPTZ DEFAULT NULL;

CREATE TABLE IF NOT EXISTS sync_jobs (
  id BIGSERIAL PRIMARY KEY,
  profile_id BIGINT NOT NULL REFERENCES sync_profiles(id) ON DELETE CASCADE,
  status VARCHAR(32) NOT NULL CHECK (status IN ('queued','running','success','failed','stopped')),
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  message TEXT
);

CREATE TABLE IF NOT EXISTS sync_job_events (
  id BIGSERIAL PRIMARY KEY,
  job_id BIGINT NOT NULL REFERENCES sync_jobs(id) ON DELETE CASCADE,
  level VARCHAR(16) NOT NULL CHECK (level IN ('info','warn','error')),
  event_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  message TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  role VARCHAR(16) NOT NULL DEFAULT 'readonly' CHECK (role IN ('admin', 'readonly')),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at TIMESTAMPTZ
);

-- Worker set definitions (optional — profiles can be unassigned)
CREATE TABLE IF NOT EXISTS worker_sets (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  max_forks_per_worker INT NOT NULL DEFAULT 4,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add worker set assignment to profiles
ALTER TABLE sync_profiles ADD COLUMN IF NOT EXISTS worker_set_id BIGINT
  REFERENCES worker_sets(id) ON DELETE SET NULL;

-- Worker instance registry (self-registered by worker daemons)
CREATE TABLE IF NOT EXISTS workers (
  id BIGSERIAL PRIMARY KEY,
  worker_set TEXT NOT NULL DEFAULT 'default',
  hostname TEXT NOT NULL,
  pid INT NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'stopping', 'stopped', 'dead', 'paused')),
  paused BOOLEAN NOT NULL DEFAULT FALSE,
  active_forks INT NOT NULL DEFAULT 0,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Migration for existing installs
ALTER TABLE workers ADD COLUMN IF NOT EXISTS paused BOOLEAN NOT NULL DEFAULT FALSE;

-- ── Sync Authorizations — immutable governance ledger ────────────────
-- Records WHO authorized WHAT sync. Private→public syncs are BLOCKED
-- by default and require explicit admin authorization with acknowledgment.
-- This table is append-only: no UPDATEs on core fields, only revocation.
CREATE TABLE IF NOT EXISTS sync_authorizations (
  id BIGSERIAL PRIMARY KEY,
  mapping_id BIGINT REFERENCES repo_mappings(id) ON DELETE SET NULL,
  profile_id BIGINT REFERENCES sync_profiles(id) ON DELETE SET NULL,
  source_repo TEXT NOT NULL,
  target_repo TEXT NOT NULL,
  source_visibility VARCHAR(16) NOT NULL DEFAULT 'unknown'
    CHECK (source_visibility IN ('private', 'public', 'internal', 'unknown')),
  target_visibility VARCHAR(16) NOT NULL DEFAULT 'unknown'
    CHECK (target_visibility IN ('private', 'public', 'internal', 'unknown')),
  risk_level VARCHAR(24) NOT NULL DEFAULT 'normal'
    CHECK (risk_level IN ('private_to_public', 'admin_block', 'normal')),
  authorization_status VARCHAR(16) NOT NULL DEFAULT 'blocked'
    CHECK (authorization_status IN ('authorized', 'blocked', 'revoked')),
  authorized_by TEXT NOT NULL,
  authorized_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledgment TEXT NOT NULL DEFAULT '',
  revoked_by TEXT,
  revoked_at TIMESTAMPTZ,
  revocation_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Governance alert log — blocked sync attempts, warnings shown on dashboard
CREATE TABLE IF NOT EXISTS governance_alerts (
  id BIGSERIAL PRIMARY KEY,
  alert_type VARCHAR(32) NOT NULL
    CHECK (alert_type IN ('private_to_public_blocked', 'authorization_revoked', 'admin_block', 'visibility_changed')),
  severity VARCHAR(16) NOT NULL DEFAULT 'warning'
    CHECK (severity IN ('critical', 'warning', 'info')),
  mapping_id BIGINT REFERENCES repo_mappings(id) ON DELETE SET NULL,
  profile_id BIGINT REFERENCES sync_profiles(id) ON DELETE SET NULL,
  source_repo TEXT,
  target_repo TEXT,
  message TEXT NOT NULL,
  acknowledged BOOLEAN NOT NULL DEFAULT FALSE,
  acknowledged_by TEXT,
  acknowledged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Fleet Binding Lock ──────────────────────────────────────────────
-- When a Fleet instance binds to this core, it stores its identity here.
-- Only ONE Fleet can bind at a time. Governance-sensitive operations
-- (authorizing private→public, unblocking admin blocks) require the
-- bound Fleet's ID once locked. Local admins retain block/read authority.
-- Unbinding requires admin auth + reason (audit logged).
CREATE TABLE IF NOT EXISTS fleet_lock (
  id BIGSERIAL PRIMARY KEY,
  fleet_id TEXT NOT NULL UNIQUE,                -- Fleet's UUID (generated once on Fleet install)
  fleet_name TEXT NOT NULL,                      -- Human-readable Fleet name
  fleet_url TEXT,                                -- Fleet's API URL (for reference)
  bound_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  bound_by TEXT NOT NULL,                        -- Username that initiated the bind
  active BOOLEAN NOT NULL DEFAULT TRUE,
  unbound_at TIMESTAMPTZ,
  unbound_by TEXT,
  unbind_reason TEXT
);

-- Fleet binding audit — every bind/unbind recorded permanently
CREATE TABLE IF NOT EXISTS fleet_lock_audit (
  id BIGSERIAL PRIMARY KEY,
  action VARCHAR(16) NOT NULL CHECK (action IN ('bind', 'unbind', 'reject')),
  fleet_id TEXT NOT NULL,
  fleet_name TEXT,
  performed_by TEXT NOT NULL,
  performed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  details TEXT,
  ip_address TEXT
);

-- ── Instance Settings (key-value, API-exposed for Fleet) ────────────
CREATE TABLE IF NOT EXISTS instance_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by TEXT
);

-- Default syslog settings (disabled until configured)
INSERT INTO instance_settings (key, value) VALUES
  ('syslog_enabled', 'false'),
  ('syslog_host', ''),
  ('syslog_port', '514'),
  ('syslog_protocol', 'udp'),
  ('syslog_facility', 'local0'),
  ('syslog_tag', 'gitmsyncd'),
  ('syslog_level', 'standard'),
  ('instance_name', 'default')
ON CONFLICT (key) DO NOTHING;

-- Default admin user (password: admin — user MUST change on first login)
-- Hash format: sha256:<salt>:<hex_digest> using Digest::SHA
INSERT INTO users (username, password_hash, role)
VALUES ('admin', 'sha256:gitmsyncd-default-salt:6691ec27bd95337f5b7321240a619035be1f2378d97a32fedd012f4479ef82b8', 'admin')
ON CONFLICT (username) DO NOTHING;
