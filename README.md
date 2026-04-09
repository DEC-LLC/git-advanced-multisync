# git-advanced-multisync

**Keep your repositories in sync across GitHub, GitLab, and Gitea — from a single web interface.**

Most teams have repositories scattered across multiple Git hosting platforms. A mirror on GitHub for open source visibility, the real development on a self-hosted GitLab, a Gitea instance for the lab. Keeping them in sync means scripts, cron jobs, SSH keys, and hoping nobody forgets to push to the other remote.

git-advanced-multisync replaces all of that with a web UI and parallel workers. Add your providers, define sync profiles, map your repos, and click Sync. One-way mirrors, bidirectional sync, conflict detection, branch-level filtering — all configured from your browser. Workers run independently, fork per-repo for parallelism, and survive web UI restarts. No scripts. No cron. No "which remote did I push to?"

> **Looking for multi-instance fleet orchestration?** See [Git Advanced Fleet Sync (GA-FS)](https://dec-llc.biz/products/ga-fs.html) — the commercial product that manages multiple git-advanced-multisync instances from a single dashboard. GA-FS uses git-advanced-multisync as its core sync engine.

## Architecture

git-advanced-multisync uses a split architecture: the web UI and sync workers are separate processes that communicate through PostgreSQL. Jobs keep running even when the UI restarts. Workers can be started, stopped, and paused from the browser.

```text
                         ┌──────────────────────────────────────────────┐
                         │         git-advanced-multisync instance      │
                         │                                              │
┌─────────┐    HTTPS     │  ┌──────────────────┐   ┌────────────────┐  │
│ Browser  │◄───────────►│  │  gitmsyncd (web)  │   │  PostgreSQL    │  │
│ / API    │             │  │  ─────────────────│   │  ──────────────│  │
│ client   │             │  │  UI + REST API    │   │  providers     │  │
└─────────┘              │  │  Worker control   │◄─►│  profiles      │  │
                         │  │  Never runs git   │   │  mappings      │  │
                         │  └────────┬─────────┘   │  jobs + events  │  │
                         │           │ auto-start   │  workers        │  │
                         │           ▼              │  worker_sets    │  │
                         │  ┌──────────────────┐   │                 │  │
                         │  │  gitmsyncd-worker │   │                 │  │
                         │  │  ─────────────────│   │                 │  │
                         │  │  Polls job queue  │◄─►│                 │  │
                         │  │  Checks schedule  │   │                 │  │
                         │  │  Forks per-repo   │   └────────────────┘  │
                         │  │  Resource governor│                       │
                         │  └───┬───┬───┬──────┘                       │
                         │      │   │   │  fork()                      │
                         │      ▼   ▼   ▼                              │
                         │  ┌─────────────────────────────────────┐    │
                         │  │  Child processes (one per repo)     │    │
                         │  │  ┌───────┐ ┌───────┐ ┌───────┐     │    │
                         │  │  │clone  │ │clone  │ │clone  │     │    │
                         │  │  │push   │ │push   │ │push   │ ... │    │
                         │  │  │repo-A │ │repo-B │ │repo-C │     │    │
                         │  │  └───────┘ └───────┘ └───────┘     │    │
                         │  └─────────────────────────────────────┘    │
                         └──────────────────────────────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    ▼                     ▼                     ▼
              ┌──────────┐         ┌──────────┐         ┌──────────┐
              │  GitHub   │         │  GitLab   │         │  Gitea   │
              └──────────┘         └──────────┘         └──────────┘
```

### Multi-Instance Support

git-advanced-multisync supports running multiple independent instances on the same host or across hosts — each with its own database, port, and worker pool. systemd template units and container images are included.

```text
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ Instance "infra" │   │ Instance "oss"   │   │ Instance "web"   │
│ port 9097        │   │ port 9098        │   │ container on     │
│ DB: gitmsyncd    │   │ DB: gitmsyncd_oss│   │ host-B           │
│ 2 workers, 24    │   │ 1 worker, 6      │   │ 1 worker, 2      │
│ repos            │   │ repos            │   │ repos            │
└──────────────────┘   └──────────────────┘   └──────────────────┘
       Host A                 Host A                 Host B
```

Each instance is the same software — same RPM, same container image — configured with different environment variables pointing to different databases.

For fleet-scale management of many instances, see [Git Advanced Fleet Sync (GA-FS)](https://dec-llc.biz/products/ga-fs.html), the commercial orchestration product.

## Sync Workflow

```text
  1. CONFIGURE                2. SCHEDULE / TRIGGER      3. EXECUTE
  ─────────────               ─────────────────────      ─────────

  Add providers               Set interval (5m-24h)      Worker picks up job
  (API tokens)                   or                         │
       │                      Click "Sync Now"              ▼
       ▼                           │                  Resource governor
  Create sync                      │                  checks CPU/mem/disk
  profiles                         │                        │ OK
       │                           ▼                        ▼
       ▼                      Job queued              Fork child per repo
  Map repos                   in PostgreSQL                 │
  (auto-discover                                            ▼
   or manual)                                         Clone source
       │                                                    │
       ▼                                                    ▼
  Set branch                                          Apply conflict
  filters                                             policy (ff-only /
  (optional)                                          force-push / reject)
                                                            │
                                                            ▼
                                                      Push to target
                                                      (filtered branches)
                                                            │
                                                            ▼
                                                      Log results
                                                      to job events
```

## Worker Lifecycle

Workers are independent processes managed through the web UI. No command-line access needed for normal operations.

```text
  Web UI boots ──► Auto-starts workers for all configured sets
                                    │
        Admin clicks                │
       [+ Start Worker] ───► Enter set name ───► Worker spawns
                                                       │
                                                       ▼
                                                 ┌───────────┐
                                                 │  Worker    │
                                                 │  running   │
                                                 └─────┬─────┘
                                                       │
                           ┌───────────────────────────┼──────────────────┐
                           │                           │                  │
                     [Pause]                     [Resume]            [Stop]
                           │                           │                  │
                           ▼                           ▼                  ▼
                     Finishes current            Resumes normal      Graceful
                     jobs, stops                 operation           shutdown:
                     picking up new                                  finish
                     work. Keeps                                     children,
                     heartbeating.                                   deregister.
```

## What it does

- **Multi-provider support** — GitHub, GitLab (self-hosted or cloud), and Gitea. Connect as many instances as you need.
- **Web-based configuration** — Add providers, create sync profiles, map repositories, trigger syncs, and view logs — all from the browser.
- **Flexible sync profiles** — One-way push, one-way pull, or bidirectional. Multiple profiles between the same providers for different policies.
- **Branch-level sync** — Per-mapping include-glob filter (e.g., `main,release/*,website-pages`). Sync only the branches you choose. Leave empty to sync all.
- **Parallel workers** — Separate worker process forks per-repo for concurrent sync. Configurable fork pool size. Workers auto-start with the web UI and can be started, stopped, and paused from the browser.
- **Resource-aware scheduling** — Workers check CPU load, available memory, and disk space before forking. Overloaded hosts automatically throttle sync operations.
- **Worker sets** — Group profiles into named sets. Each set can have its own worker with independent parallelism settings.
- **Scheduled sync** — Per-profile intervals from 5 minutes to 24 hours with staggered start times.
- **Conflict detection and enforcement** — Fast-forward-only, force-push, or reject-and-log. Policies are enforced, not advisory.
- **Auto-discovery** — Discover repos from a provider's org/group and select which ones to sync.
- **Duplicate prevention** — Same repo pair blocked across profiles. Reverse-direction also blocked.
- **RBAC** — Admin and read-only roles.
- **Sync locking** — Concurrent syncs of the same profile are prevented. Stale locks auto-expire.
- **Retry logic** — Clone and push retry up to 3 times with exponential backoff.
- **System status page** — Worker health, host resources (CPU, memory, load), scheduled syncs, job history — all at `/status`.
- **SSH and HTTPS transport** — Per-provider clone and push protocol selection.
- **REST API** — Everything the UI does is available via JSON API.
- **Multi-instance support** — systemd template units and container images for running multiple instances.

## Screenshots

### Dashboard
![Dashboard](docs/screenshots/dashboard-overview.png)
*At-a-glance view: 3 providers connected, 3 sync profiles, recent job history.*

### Providers
![Providers](docs/screenshots/providers-all-connected.png)
*Three providers configured and tested: Gitea (local), GitHub, GitLab. Green status = connected.*

### Sync Profiles with Repo Discovery
![Profiles](docs/screenshots/profiles-with-repo-discovery.png)
*Click a profile to manage its repos. Auto-discover finds repos from the source provider.*

### Create Profile
![Create Profile](docs/screenshots/profile-create-form.png)
*Profile form with source/target providers, direction, conflict policy, and help text.*

### Repo Mappings (Audit View)
![Mappings](docs/screenshots/repo-mappings-audit.png)
*Read-only view of all repo mappings across profiles. Source and target paths shown.*

### Sync Jobs
![Jobs](docs/screenshots/sync-jobs-history.png)
*Job history with status badges. Click a job to view its event log.*

## Quick Start

### Prerequisites

- Perl 5.26+ with Mojolicious, DBI, DBD::Pg
- PostgreSQL 12+
- Git

### Install and run (from source)

```bash
git clone https://github.com/DEC-LLC/git-advanced-multisync.git
cd git-advanced-multisync

# Install Perl dependencies
cpanm --installdeps .

# Create database
createdb gitmsyncd
psql -d gitmsyncd -f db/schema.sql

# Start the server (workers auto-start)
GITMSYNCD_DSN='dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432' \
GITMSYNCD_DB_USER='gitmsyncd' \
GITMSYNCD_DB_PASS='gitmsyncd' \
  perl bin/gitmsyncd.pl
```

Open `http://localhost:9097` and log in with the default credentials: **admin / admin**.

A default worker auto-starts on boot. Visit `/status` to see worker health and controls.

### First steps

1. **Log in** — Default credentials are `admin` / `admin`. Change the password after first login.
2. **Add Providers** — Connect your GitHub, GitLab, or Gitea instances with an API token.
3. **Create a Sync Profile** — Pick source and target providers, direction, conflict policy, and optional schedule.
4. **Map Repos** — Auto-discover repos from the source org or add them manually. Set branch filters to sync only specific branches.
5. **Sync** — Click "Sync Now" and watch the job log, or let the schedule handle it.
6. **Monitor** — Visit `/status` for worker health, host resources, scheduled syncs, and job history.

## Sync Profiles

A sync profile defines a relationship between two provider orgs:

| Profile | Direction | Policy | Use case |
|---------|-----------|--------|----------|
| `gitlab-to-github-mirror` | One-way | force-push | Authoritative mirror to GitHub |
| `gitlab-to-github-safe` | One-way | ff-only | Safe sync that rejects if diverged |
| `gitlab-github-bidi` | Bidirectional | ff-only | Two-way sync for collaborative repos |

Each profile can have an optional **schedule** (5 minutes to 24 hours) and can be assigned to a **worker set** for dedicated processing.

## Conflict Policies

| Policy | Behavior | When to use |
|--------|----------|-------------|
| **ff-only** | Skips diverged protected branches, syncs the rest | Safe default for most workflows |
| **force-push** | Overwrites target with source state | One-way mirrors |
| **reject** | Skips entire repo if any branch diverged | Monitoring mode |

## Branch Filtering

Each repo mapping can have a branch filter — comma-separated globs:

| Filter | Matches | Doesn't match |
|--------|---------|---------------|
| `main` | `main` | `develop`, `feature/x` |
| `release/*` | `release/v1.0`, `release/v2.0` | `main`, `hotfix/x` |
| `main,release/*` | `main`, `release/v1.0` | `develop`, `feature/x` |
| *(empty)* | All branches | *(nothing excluded)* |

## Deployment

### RPM (Rocky/RHEL/Fedora)

```bash
rpm -ivh git-advanced-multisync-0.3.0-1.el10.noarch.rpm
vim /etc/gitmsyncd/gitmsyncd.env    # set DB password
createdb gitmsyncd
psql -d gitmsyncd -f /opt/gitmsyncd/db/schema.sql
systemctl enable --now gitmsyncd    # web + workers auto-start
```

### DEB (Debian/Ubuntu)

```bash
dpkg -i git-advanced-multisync_0.3.0-1_all.deb
vim /etc/gitmsyncd/gitmsyncd.env
createdb gitmsyncd
psql -d gitmsyncd -f /opt/gitmsyncd/db/schema.sql
systemctl enable --now gitmsyncd
```

### Container

```bash
podman build -t gitmsyncd:0.3.0 .
podman run -d --name gitmsyncd -p 9097:9097 \
  -e GITMSYNCD_DSN='dbi:Pg:dbname=gitmsyncd;host=db.example.com;port=5432' \
  -e GITMSYNCD_DB_USER=gitmsyncd \
  -e GITMSYNCD_DB_PASS=changeme \
  -v gitmsyncd-workdir:/var/lib/gitmsyncd/workdir \
  gitmsyncd:0.3.0
```

A compose template is included at `packaging/container/docker-compose.example.yml`.

### Multi-Instance (same host)

```bash
cp /etc/gitmsyncd/gitmsyncd.env /etc/gitmsyncd/oss.env
# Edit oss.env: unique DSN, LISTEN port, WORKDIR
createdb gitmsyncd_oss
psql -d gitmsyncd_oss -f /opt/gitmsyncd/db/schema.sql
systemctl enable --now gitmsyncd@oss
systemctl enable --now gitmsyncd-worker@oss
```

**Resource warning:** Multiple instances on the same host require adequate CPU (4+ cores), memory (4+ GB), disk I/O, and network bandwidth. The status page shows host resource metrics and displays a warning when multiple workers run on the same host. For production multi-instance, use containers on separate hosts.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITMSYNCD_DSN` | `dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432` | PostgreSQL connection string |
| `GITMSYNCD_DB_USER` | `gitmsyncd` | Database username |
| `GITMSYNCD_DB_PASS` | `gitmsyncd` | Database password |
| `GITMSYNCD_LISTEN` | `http://127.0.0.1:9097` | Web UI listen address and port |
| `GITMSYNCD_WORKDIR` | `/tmp/gitmsyncd-workdir` | Temporary directory for git clone operations |
| `GITMSYNCD_MAX_FORKS` | `4` | Maximum concurrent repo syncs per worker |
| `GITMSYNCD_MAX_LOAD` | `3.2` | CPU load threshold — worker throttles above this |
| `GITMSYNCD_MIN_MEM_MB` | `256` | Minimum free memory (MB) — worker throttles below this |
| `GITMSYNCD_MIN_DISK_MB` | `1024` | Minimum free disk (MB) — worker throttles below this |
| `GITMSYNCD_SECRET` | `dev` | Session signing secret (change in production) |

## API

All UI operations are available via REST API. Endpoints except `/api/health` require session authentication.

```bash
# Health check
curl http://localhost:9097/api/health

# Log in
curl -c cookies.txt -X POST http://localhost:9097/login \
  -d 'username=admin&password=admin'

# Providers
curl -b cookies.txt http://localhost:9097/api/providers
curl -b cookies.txt -X POST http://localhost:9097/api/providers/1/test

# Discover repos
curl -b cookies.txt http://localhost:9097/api/providers/1/repos?owner=my-org

# Sync
curl -b cookies.txt -X POST http://localhost:9097/api/sync/start/1
curl -b cookies.txt http://localhost:9097/api/sync/jobs?limit=10

# Workers
curl -b cookies.txt http://localhost:9097/api/workers
curl -b cookies.txt -X POST http://localhost:9097/api/workers/start \
  -H 'Content-Type: application/json' -d '{"set":"infra"}'
curl -b cookies.txt -X POST http://localhost:9097/api/workers/1/pause
curl -b cookies.txt -X POST http://localhost:9097/api/workers/1/resume
curl -b cookies.txt -X POST http://localhost:9097/api/workers/1/stop
```

## Roadmap

### Completed (v0.3.0)

- [x] Authentication and RBAC
- [x] Scheduled sync with stagger
- [x] System status page with host resource metrics
- [x] Sync locking with stale lock timeout
- [x] Duplicate mapping prevention
- [x] Retry logic with exponential backoff
- [x] SSH transport with per-provider key paths
- [x] Conflict policy enforcement (ff-only, force-push, reject)
- [x] RPM and DEB packaging with systemd services
- [x] Branch-level sync with glob filters
- [x] Parallel workers with fork-per-repo concurrency
- [x] Resource governor (CPU, memory, disk)
- [x] Worker sets for profile-to-worker assignment
- [x] Worker UI controls (start, stop, pause, resume)
- [x] Auto-start workers on web boot
- [x] Multi-instance support (systemd template units)
- [x] Container packaging (Containerfile + compose template)

### Planned

- [ ] **Persistent sync cache** — Keep cloned bare repos between sync cycles instead of deleting after each push. Subsequent syncs use `git fetch` to update incrementally. Eliminates full re-clone on every cycle — critical for large repositories.
- [ ] **rsync transport** — Alternative sync transport for force-push mirrors between self-hosted providers. Uses `rsync -avz --delete` over SSH to transfer only changed pack files. Dramatically faster than git clone+push for large repos with small deltas. Configurable per-profile. Requires SSH filesystem access to target bare repo path (not available for cloud providers).
- [ ] **Chained sync** — Sync a repo across three or more providers in sequence with per-hop conflict policies.
- [ ] **Custom provider support** — Define API endpoint patterns for any Git hosting platform.
- [ ] **Webhook triggers** — Sync immediately on push instead of polling.
- [ ] **Diff preview** — Show what commits would be pushed before syncing.
- [ ] **Issue and PR/MR sync** — Synchronize issues and pull requests across providers.
- [ ] **SSH key trust terminal** — Accept host keys from the web UI for SSH-based sync.
- [ ] **TLS/HTTPS** — Native TLS with user-provided certificates.
- [ ] **Forced password change** — First login requires password change.
- [ ] **Encrypted token storage** — API tokens encrypted at rest.

## Git Advanced Fleet Sync (GA-FS)

For organizations managing multiple git-advanced-multisync instances across hosts, [Git Advanced Fleet Sync](https://dec-llc.biz/products/ga-fs.html) provides a unified orchestration dashboard:

- Consolidated status, jobs, and worker health across all instances
- Provider credential management — configure tokens once, push to instances
- Instance provisioning — create new instances from the Fleet UI (container, RPM, or local)
- Cross-instance analytics and drift detection
- Register independently-running instances into Fleet management

GA-FS Fleet uses git-advanced-multisync as its core sync engine. Each managed instance is a standard git-advanced-multisync installation — same RPM, same container image — with Fleet providing the orchestration layer on top.

GA-FS Fleet is a commercial product available from [DEC-LLC](https://dec-llc.biz/products/ga-fs.html).

## Security

- **Session-based authentication** — All routes except `/api/health` and `/login` require an active session.
- **Role enforcement** — Write operations require admin role.
- **Token masking** — API tokens never displayed after entry.
- **Sync locking** — Database-level lock prevents concurrent syncs of the same profile.
- **HTTPS transport** — Default for all provider API calls and git operations.

## Documentation

- [User Guide](docs/USER-GUIDE.md) — Full walkthrough with UX diagrams and test matrix
- [Architecture](docs/ARCHITECTURE-ALPHA-200.md) — Technical design and data model

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](Legal/LICENSE-APACHE.md) for details.

## About

Built by [Diwan Enterprise Consulting LLC (DEC-LLC)](https://dec-llc.biz). Part of the DEC-LLC infrastructure management product line.

DEC-LLC builds infrastructure management software: [NIVMIA](https://dec-llc.biz/products/nivmia.html) (network), [IVMIA](https://dec-llc.biz/products/ivmia.html) (virtualization), [OpenUTM](https://dec-llc.biz/products/openutm.html) (security), [VaultSync](https://dec-llc.biz/products/vaultsync.html) (backup). git-advanced-multisync keeps our own repos in sync across GitHub and GitLab — and now it can do the same for yours.
