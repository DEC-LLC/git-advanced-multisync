# git-advanced-multisync alpha-200 Architecture

## Objective

Perl-based standalone service (`gitmsyncd`) for multi-account, multi-owner Git repository synchronization across GitHub, GitLab, and Gitea with mapping controls, conflict policies, scheduling, RBAC, REST API, and web UI.

## Core Components

- `gitmsyncd` daemon (Perl/Mojolicious): web server + background worker in a single process.
- PostgreSQL metadata DB: providers, profiles, mappings, jobs, events, users.
- REST API: full CRUD for all entities + sync control. ~25 endpoints.
- Web UI: 7 pages (login, dashboard, providers, profiles, mappings, jobs, status).
- Background worker: 5-second event loop processing queued jobs and scheduled profiles.

## Service Boundaries

- **Git provider adapters** (3):
  - GitHub (api.github.com, token auth)
  - GitLab (self-hosted or cloud, `/api/v4`, PRIVATE-TOKEN)
  - Gitea (self-hosted, `/api/v1`, token auth)
- **Sync engine**:
  - Clone-mirror from source, push to target
  - Three conflict policy implementations (ff-only, force-push, reject)
  - SSH and HTTPS transport support
  - Retry with exponential backoff (3 attempts)
- **Policy engine**:
  - Protected branch ff-only (per-branch merge-base ancestor check)
  - Force-push mirror (`--mirror --force`)
  - Reject (full divergence check, skip entire repo on any conflict)
- **Scheduler**:
  - Per-profile intervals with staggered start
  - Dual-purpose worker: queued jobs take priority, then scheduled profiles
- **Auth layer**:
  - Session-based authentication
  - Admin/readonly role enforcement
  - Auth middleware on all routes except `/api/health` and `/login`

## Data Model

### Tables

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `owners` | Legacy owner tracking | `provider`, `owner_name` |
| `owner_mappings` | Legacy owner-to-owner relationships | `source_owner_id`, `target_owner_id`, `direction` |
| `providers` | Git hosting provider connections | `name`, `provider_type` (github/gitlab/gitea), `base_url`, `api_token`, `clone_protocol`, `push_protocol`, `ssh_key_path`, `test_status`, `last_tested_at` |
| `sync_profiles` | Sync relationship definitions | `name`, `direction`, `source_provider_id`, `target_provider_id`, `source_owner`, `target_owner`, `conflict_policy`, `protected_branches`, `sync_interval_minutes`, `next_sync_at`, `last_synced_at`, `sync_locked`, `sync_locked_at`, `sync_locked_by` |
| `repo_mappings` | Individual repository pair mappings | `source_full_path`, `target_full_path`, `profile_id`, `direction`, `enabled` |
| `sync_jobs` | Sync execution records | `profile_id`, `status` (queued/running/success/failed/stopped), `started_at`, `finished_at`, `message` |
| `sync_job_events` | Per-job event log | `job_id`, `level` (info/warn/error), `event_at`, `message` |
| `users` | Authentication and authorization | `username`, `password_hash` (sha256:salt:digest), `role` (admin/readonly), `enabled`, `last_login_at` |

### Seed data

- Default admin user: `admin` / `admin` (sha256 hashed with static salt)

## Security

### Authentication

- **Session-based** — Mojolicious session cookies with configurable secret (`GITMSYNCD_SECRET` env var).
- **Auth middleware** — `under '/'` block intercepts all requests after `/login` and `/api/health`.
- **Login flow** — `POST /login` verifies password against `sha256:salt:digest` hash, sets `user_id` in session, updates `last_login_at`.
- **Logout** — `GET /logout` expires session and redirects to `/login`.

### Role enforcement

- `$require_admin` helper checks `current_user.role` before every write operation.
- API routes return `403 Forbidden` with `{"error":"admin access required"}`.
- Web routes redirect to `/` (dashboard).
- Read-only users can access all GET endpoints and view all pages.

### Password hashing

- `sha256:<random-16-char-salt>:<hex-digest>` format using `Digest::SHA`.
- Verification: extract salt from stored hash, recompute, compare.
- bcrypt preferred but not available as an OS package — SHA-256 with per-user salt is the current implementation.

### Token storage

- API tokens stored in `providers.api_token` column — **plain text** currently.
- Tokens never returned in API responses for provider listings (selected columns only).
- Tokens masked in UI (last 4 characters only).
- **Roadmap**: application-level encryption at rest.

## Sync Engine

### Clone-push architecture

1. `git clone --mirror` from source URL into temp directory (`/tmp/gitmsyncd-workdir/<org>--<repo>.git`)
2. Apply conflict policy checks (see below)
3. Push to target URL
4. Clean up temp directory

### Conflict policy implementations

**ff-only** (default):
1. Fetch target refs: `git fetch <target> '+refs/heads/*:refs/remotes/destination/*'`
2. For each branch in source:
   - If branch is protected (`main`, `master`, `develop` by default):
     - Check if target branch tip is ancestor of source branch tip: `merge-base --is-ancestor`
     - If diverged: skip that branch, log warning
   - If not protected: include in refspec
3. Build explicit refspecs: `refs/heads/<branch>:refs/heads/<branch>` for each non-skipped branch + `refs/tags/*:refs/tags/*`
4. Push: `git push --prune <target> <refspecs>`

**force-push**:
1. Push: `git push --mirror --force <target>`
2. No divergence checks — source is authoritative.

**reject**:
1. Fetch target refs (same as ff-only)
2. Check **every** branch (not just protected) for divergence
3. If any branch has diverged: skip entire repo, log conflict
4. If all branches are clean: `git push --mirror <target>`

### Transport

- **HTTPS** (default): Token-authenticated clone URLs.
  - GitHub: `https://<token>@github.com/<path>.git`
  - GitLab: `https://oauth2:<token>@<host>/<path>.git`
  - Gitea: `https://<token>@<host>/<path>.git`
- **SSH**: Key-based clone URLs with `GIT_SSH_COMMAND`.
  - GitHub: `git@github.com:<path>.git`
  - GitLab: `git@<host>:<path>.git`
  - Gitea: `git@<host>:<path>.git` or `ssh://git@<host>:<port>/<path>.git` for non-standard ports
  - SSH key path stored in `providers.ssh_key_path`
  - `StrictHostKeyChecking=no` and `IdentitiesOnly=yes` set via `GIT_SSH_COMMAND`

### Retry logic

- Helper function wraps shell commands with retry.
- **3 attempts** with exponential backoff: 2s after first failure, 4s after second.
- Applied to both clone and push operations.
- Failure events logged at each attempt.

## Worker

### Architecture

Single `Mojo::IOLoop->recurring(5)` timer — runs every 5 seconds within the main process. No separate daemon or fork.

### Dual-purpose loop

Each tick:
1. **Queued jobs first** — Check `sync_jobs` for `status = 'queued'`, pick oldest. If found, run it and return (one job per tick).
2. **Scheduled profiles** — If no queued jobs, check `sync_profiles` for profiles where `enabled = TRUE`, `sync_interval_minutes > 0`, `next_sync_at <= NOW()`, and not locked. Pick the most overdue. Create a job, bump `next_sync_at`, run the sync.

### Lock acquisition

- Atomic `UPDATE ... RETURNING` pattern:
  ```sql
  UPDATE sync_profiles SET sync_locked = TRUE, sync_locked_at = NOW(),
    sync_locked_by = 'worker-' || pg_backend_pid()
  WHERE id = ? AND (sync_locked = FALSE OR sync_locked_at < NOW() - INTERVAL '30 minutes')
  RETURNING id
  ```
- If no row returned: profile is locked by another sync, job is stopped with "profile locked" message.
- Lock is **always released** in a finally block (eval + release_lock), even if sync throws an error.
- Stale lock breaker: locks older than 30 minutes are broken.

### Schedule advance

- `next_sync_at` is bumped **before** the sync runs:
  ```sql
  UPDATE sync_profiles SET next_sync_at = NOW() + (sync_interval_minutes || ' minutes')::interval
  ```
- Prevents re-triggering if a sync takes longer than its interval.

## API

All endpoints except `/api/health` and `/login` require session authentication. Write operations require `admin` role.

### Public endpoints (no auth)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/health` | Health check — returns `{"status":"ok"}` |

### Authentication

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/login` | Login page (redirects to `/` if already logged in) |
| `POST` | `/login` | Authenticate — sets session cookie |
| `GET` | `/logout` | Destroy session, redirect to `/login` |

### Providers (admin write, all read)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/providers` | List all providers (token excluded) |
| `POST` | `/api/providers` | Create provider |
| `PUT` | `/api/providers/:id` | Update provider |
| `DELETE` | `/api/providers/:id` | Delete provider |
| `POST` | `/api/providers/:id/test` | Test provider connectivity |
| `GET` | `/api/providers/:id/repos` | Discover repos (`?owner=<org>`) |

### Profiles (admin write, all read)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/profiles` | List all profiles (with provider names, schedule, lock status) |
| `POST` | `/api/profiles` | Create profile (supports `sync_interval_minutes`) |
| `PUT` | `/api/profiles/:id` | Update profile (recalculates `next_sync_at` if interval changed) |
| `DELETE` | `/api/profiles/:id` | Delete profile |

### Repo Mappings (admin write, all read)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/mappings` | List all mappings |
| `POST` | `/api/mappings` | Create mapping (duplicate + reverse check, returns 409 on conflict) |
| `PUT` | `/api/mappings/:id` | Update mapping |
| `DELETE` | `/api/mappings/:id` | Delete mapping |

### Sync (admin only)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/sync/start/:profile_id` | Queue a sync job (background worker picks it up) |
| `POST` | `/api/sync/run/:profile_id` | Run sync immediately (synchronous, returns results) |
| `POST` | `/api/sync/stop/:job_id` | Stop a queued or running job |
| `GET` | `/api/sync/jobs` | List jobs (`?limit=N`, default 25) |
| `GET` | `/api/sync/jobs/:id` | Get job details with event log |

### Web UI pages

| Path | Page |
|------|------|
| `/` | Dashboard |
| `/providers` | Provider management |
| `/profiles` | Sync profile management |
| `/mappings` | Repo mapping audit view |
| `/jobs` | Job history |
| `/status` | System status |

## Packaging

### RPM (`packaging/rpm/git-advanced-multisync.spec`)

- Package: `git-advanced-multisync`
- Installs to: `/usr/share/gitmsyncd/` (app), `/etc/gitmsyncd/` (config)
- systemd service: `gitmsyncd.service`
- Environment file: `/etc/gitmsyncd/gitmsyncd.env`
- Requires: `perl-Mojolicious`, `perl-DBI`, `perl-DBD-Pg`, `perl-Digest-SHA`, `git`, `postgresql-server`

### DEB (`packaging/deb/debian/`)

- Package: `git-advanced-multisync`
- Same layout as RPM
- Requires: `libmojolicious-perl`, `libdbi-perl`, `libdbd-pg-perl`, `libdigest-sha-perl`, `git`, `postgresql`

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GITMSYNCD_DSN` | `dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432` | Database connection string |
| `GITMSYNCD_DB_USER` | `gitmsyncd` | Database username |
| `GITMSYNCD_DB_PASS` | `gitmsyncd` | Database password |
| `GITMSYNCD_LISTEN` | `http://127.0.0.1:9097` | Listen address |
| `GITMSYNCD_SECRET` | `dev` | Session cookie secret |
