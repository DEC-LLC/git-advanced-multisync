# git-advanced-multisync

**Keep your repositories in sync across GitHub, GitLab, and Gitea — from a single web interface.**

Most teams have repositories scattered across multiple Git hosting platforms. A mirror on GitHub for open source visibility, the real development on a self-hosted GitLab, a Gitea instance for the lab. Keeping them in sync means scripts, cron jobs, SSH keys, and hoping nobody forgets to push to the other remote.

git-advanced-multisync replaces all of that with a web UI. Add your providers, define sync profiles, map your repos, and click Sync. One-way mirrors, bidirectional sync, conflict detection — all configured from your browser. No scripts. No cron. No "which remote did I push to?"

## What it does

- **Multi-provider support** — GitHub, GitLab (self-hosted or cloud), and Gitea. Connect as many instances as you need.
- **Web-based configuration** — Add providers, create sync profiles, map repositories, trigger syncs, and view logs — all from the browser. No config files to edit.
- **Flexible sync profiles** — One-way push, one-way pull, or bidirectional. Multiple profiles between the same providers for different policies (e.g., a safe ff-only profile and a force-push mirror profile for the same pair).
- **Conflict detection** — Fast-forward-only (safe default), force-push (authoritative source), or reject-and-log (monitoring mode).
- **Auto-discovery** — Discover repos from a provider's org/group and select which ones to sync. No manual typing of every repo name.
- **Job history and logs** — Every sync run is logged with per-repo event details. See what synced, what failed, and why.
- **REST API** — Everything the UI does is available via JSON API for automation and integration.

## Screenshot

![Dashboard](docs/screenshots/dashboard.png)

*Dashboard showing providers, profiles, and recent sync jobs.*

## Quick Start

### Prerequisites

- Perl 5.26+ with Mojolicious, DBI, DBD::Pg
- PostgreSQL 12+
- Git

### Install and run

```bash
git clone https://github.com/DEC-LLC/git-advanced-multisync.git
cd git-advanced-multisync

# Install Perl dependencies
cpanm --installdeps .

# Create database
createdb gitmsyncd
psql -d gitmsyncd -f db/schema.sql

# Start the server
GITMSYNCD_DSN='dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432' \
GITMSYNCD_DB_USER='gitmsyncd' \
GITMSYNCD_DB_PASS='gitmsyncd' \
  perl bin/gitmsyncd.pl
```

Open `http://localhost:9097` and follow the Getting Started guide on the dashboard.

### First steps

1. **Add Providers** — Connect your GitHub, GitLab, or Gitea instances with an API token
2. **Create a Sync Profile** — Pick a source and target provider, choose a direction and conflict policy
3. **Map Repos** — Auto-discover repos from the source org or add them manually
4. **Sync** — Click "Sync Now" and watch the job log

## Sync Profiles

A sync profile defines a relationship between two provider orgs. You can create **multiple profiles** between the same pair of providers — for example:

| Profile | Direction | Policy | Use case |
|---------|-----------|--------|----------|
| `gitlab-to-github-mirror` | One-way | force-push | Authoritative mirror to GitHub |
| `gitlab-to-github-safe` | One-way | ff-only | Safe sync that rejects if diverged |
| `gitlab-github-bidi` | Bidirectional | ff-only | Two-way sync for collaborative repos |

The profile name is the unique identifier, not the provider pair. Use as many as you need.

## Supported Providers

| Provider | Hosting | How it connects |
|----------|---------|-----------------|
| **GitHub** | Cloud (github.com) | API token via api.github.com |
| **GitLab** | Self-hosted or cloud | API token via your instance URL |
| **Gitea** | Self-hosted | API token via your instance URL |

## Sync Directions

| Direction | Behavior |
|-----------|----------|
| **Source to Target** | One-way push. Source is authoritative. |
| **Target to Source** | One-way pull. Target is authoritative. |
| **Bidirectional** | Changes sync both ways. Conflicts detected. |

## Conflict Policies

| Policy | Behavior | When to use |
|--------|----------|-------------|
| **ff-only** | Rejects sync if target has diverged | Safe default for most workflows |
| **force-push** | Overwrites target with source state | One-way mirrors where source is authoritative |
| **reject** | Logs the conflict, doesn't sync | Monitoring mode — detect drift without acting |

## Documentation

- [User Guide](docs/USER-GUIDE.md) — Full walkthrough with UX diagrams and test matrix
- [Architecture](docs/ARCHITECTURE-ALPHA-200.md) — Technical design and data model

## API

All UI operations are available via REST API:

```bash
# Health check
curl http://localhost:9097/api/health

# List providers
curl http://localhost:9097/api/providers

# Add a provider
curl -X POST http://localhost:9097/api/providers \
  -H 'Content-Type: application/json' \
  -d '{"name":"My GitLab","provider_type":"gitlab","base_url":"https://gitlab.example.com","api_token":"glpat-xxx"}'

# Test a provider connection
curl -X POST http://localhost:9097/api/providers/1/test

# Discover repos in an org
curl http://localhost:9097/api/providers/1/repos?owner=my-org

# Trigger a sync
curl -X POST http://localhost:9097/api/sync/run/1
```

## Roadmap

- **Authentication and RBAC** — Login page with admin and read-only user roles. Admins can add providers, create profiles, and trigger syncs. Read-only users can view status, jobs, and logs.
- **Chained sync** — Sync a repo across three or more providers in sequence (e.g., GitLab → GitHub → Gitea) in a single profile, with per-hop conflict policies.
- **Custom provider support** — Add any Git hosting platform that speaks a standard API. Define the API endpoint patterns (repos list, clone URL format, auth header) and use it alongside the built-in GitHub/GitLab/Gitea adapters.
- **Scheduled sync** — Cron-style schedules per profile. Set it and forget it.
- **Webhook triggers** — Receive push webhooks from providers and sync immediately on change instead of polling.
- **Diff preview** — Before syncing, show what commits would be pushed and flag potential conflicts.

## License

Dual-licensed under MIT and GPLv3. See [LICENSE](Legal/) files for details.

## About

Built by [Diwan Enterprise Consulting LLC (DEC-LLC)](https://dec-llc.biz). Part of the DEC-LLC open source initiative.

We build infrastructure management software: [NIVMIA](https://dec-llc.biz/products/nivmia.html) (network), [IVMIA](https://dec-llc.biz/products/ivmia.html) (virtualization), [OpenUTM](https://dec-llc.biz/products/openutm.html) (security), [VaultSync](https://dec-llc.biz/products/vaultsync.html) (backup). git-advanced-multisync keeps our own repos in sync across GitHub and GitLab — and now it can do the same for yours.
