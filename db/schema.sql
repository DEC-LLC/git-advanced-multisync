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
  source_provider VARCHAR(32) NOT NULL CHECK (source_provider IN ('github','gitlab')),
  source_full_path TEXT NOT NULL,
  target_provider VARCHAR(32) NOT NULL CHECK (target_provider IN ('github','gitlab')),
  target_full_path TEXT NOT NULL,
  direction VARCHAR(32) NOT NULL CHECK (direction IN ('github_to_gitlab','gitlab_to_github','bidirectional')),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  branch_filter TEXT DEFAULT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(source_provider, source_full_path, target_provider, target_full_path, direction)
);

-- Migration for existing installs: add branch_filter column
ALTER TABLE repo_mappings ADD COLUMN IF NOT EXISTS branch_filter TEXT DEFAULT NULL;

CREATE TABLE IF NOT EXISTS providers (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  provider_type VARCHAR(32) NOT NULL CHECK (provider_type IN ('github','gitlab','gitea')),
  base_url TEXT,  -- NULL for github.com (uses api.github.com)
  api_token TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_tested_at TIMESTAMPTZ,
  test_status VARCHAR(32) DEFAULT 'untested'
);

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
  sync_locked BOOLEAN DEFAULT FALSE,
  sync_locked_at TIMESTAMPTZ DEFAULT NULL,
  sync_locked_by VARCHAR(64) DEFAULT NULL
);

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

-- Default admin user (password: admin — user MUST change on first login)
-- Hash format: sha256:<salt>:<hex_digest> using Digest::SHA
INSERT INTO users (username, password_hash, role)
VALUES ('admin', 'sha256:gitmsyncd-default-salt:6691ec27bd95337f5b7321240a619035be1f2378d97a32fedd012f4479ef82b8', 'admin')
ON CONFLICT (username) DO NOTHING;
