# git-advanced-multisync — User Guide

## Overview

git-advanced-multisync (`gitmsyncd`) synchronizes Git repositories across multiple hosting providers — GitHub, GitLab, and Gitea — through a web interface. No CLI configuration, no config files. Everything is managed from the browser.

All access requires authentication. The default login is `admin` / `admin`.

## Supported Providers

| Provider | Type | API | Notes |
|----------|------|-----|-------|
| **GitHub** | Cloud | api.github.com | Orgs and personal repos |
| **GitLab** | Self-hosted or Cloud | `{url}/api/v4` | Groups and user namespaces |
| **Gitea** | Self-hosted | `{url}/api/v1` | Orgs and personal repos |

---

## Architecture

```
                    ┌──────────┐
                    │  GitHub  │
                    │  (cloud) │
                    └────┬─────┘
                   ↗     │     ↖
                  ╱      │      ╲
                 ╱       │       ╲
    ┌──────────┐    ↕    │   ↕    ┌──────────┐
    │  Gitea   │─────────┼────────│ GitLab   │
    │  (self-  │    ↕    │   ↕    │ (self-   │
    │  hosted) │←────────┼───────→│  hosted) │
    └──────────┘         │        └──────────┘
                         │
              All connected through
                gitmsyncd web UI
```

Each provider is registered with its URL and API token. Sync profiles define which org/group on one provider maps to which org/group on another. Repo mappings define the individual repository pairs.

---

## Authentication

All pages and API endpoints (except `/api/health`) require authentication. Unauthenticated web requests redirect to `/login`. Unauthenticated API requests receive `401 Unauthorized`.

### Login Page

Navigate to `http://localhost:9097/login`. Default credentials: `admin` / `admin`.

### Roles

| Role | Can view | Can modify |
|------|----------|------------|
| **admin** | Everything | Providers, profiles, mappings, syncs, users |
| **readonly** | Dashboard, providers, profiles, mappings, jobs, status | Nothing — all write operations return 403 |

Admins see all management controls in the UI (add/edit/delete buttons, sync triggers). Read-only users see the same data but without action buttons.

### Sessions

Authentication uses Mojolicious session cookies. Sessions persist across browser restarts. Log out via the navigation bar or `GET /logout`.

---

## Sync Flows

### One-Way Sync (6 directions)

```
Flow 1: Gitea  ──→ GitHub     Push local repos to public cloud
Flow 2: GitHub ──→ Gitea      Pull cloud repos to local instance
Flow 3: Gitea  ──→ GitLab     Push between self-hosted instances
Flow 4: GitLab ──→ Gitea      Pull between self-hosted instances
Flow 5: GitHub ──→ GitLab     Mirror cloud repos to self-hosted
Flow 6: GitLab ──→ GitHub     Publish self-hosted repos to cloud
```

### Bidirectional Sync (3 pairs)

```
Flow 7: Gitea  ←──→ GitHub    Two-way sync (local ↔ cloud)
Flow 8: Gitea  ←──→ GitLab    Two-way sync (self-hosted ↔ self-hosted)
Flow 9: GitHub ←──→ GitLab    Two-way sync (cloud ↔ self-hosted)
```

### Sync Method

Each sync uses `git clone --mirror` from the source followed by a push to the target. The push strategy depends on the conflict policy (see below). Both HTTPS (token-authenticated) and SSH (key-based) transport are supported per-provider.

### Conflict Policy Details

Conflict policies are **enforced at sync time** — not advisory. The sync engine performs divergence checks before pushing.

| Policy | Behavior | Implementation |
|--------|----------|----------------|
| **ff-only** | Skips diverged protected branches, syncs the rest | Fetches target refs into `refs/remotes/destination/*`. For each protected branch, runs `merge-base --is-ancestor` to verify fast-forward. Diverged branches are skipped. Builds per-branch refspecs instead of `--mirror`. Tags always included. |
| **force-push** | Overwrites target with source state | Runs `git push --mirror --force`. Source is authoritative — target history is overwritten. |
| **reject** | Checks all branches, skips entire repo if any diverged | Fetches target refs, checks every branch with `merge-base --is-ancestor`. If any branch has diverged, the entire repo is skipped and logged as a conflict. |

**Protected branches** default to `main master develop` and are configurable per-profile.

### Retry Logic

Clone and push operations retry up to **3 attempts** with exponential backoff:
- Attempt 1: immediate
- Attempt 2: 2 second delay
- Attempt 3: 4 second delay

If all 3 attempts fail, the repo mapping is marked as failed in the job log and the sync continues with the next mapping.

---

## UX Workflow

### Step 0: Log In

Navigate to the login page. Default credentials: `admin` / `admin`.

```
┌─────────────────────────────────────────────────────┐
│  git-advanced-multisync                    DEC-LLC   │
│  ─────────────────────────────────────────────────── │
│                                                      │
│              ┌─────────────────────┐                │
│              │      Log In         │                │
│              │                     │                │
│              │  User: [admin    ]  │                │
│              │  Pass: [●●●●●    ]  │                │
│              │                     │                │
│              │    [  Log In  ]     │                │
│              └─────────────────────┘                │
│                                                      │
└─────────────────────────────────────────────────────┘
```

After login, you are redirected to the dashboard.

### Step 1: Add Providers

Register each Git hosting provider with a name, type, URL, and API token.

```
┌─────────────────────────────────────────────────────┐
│  PROVIDERS                                           │
│                                                      │
│  ┌─────────────────────────────────────────────┐    │
│  │ Name:  [My Gitea                          ] │    │
│  │ Type:  [Gitea ▼]                            │    │
│  │ URL:   [https://gitea.example.com         ] │    │
│  │ Token: [●●●●●●●●●●●●●●●●●●               ] │    │
│  │                                              │    │
│  │              [Test Connection]  [Save]        │    │
│  └─────────────────────────────────────────────┘    │
│                                                      │
│  Provider List:                                      │
│  ┌──────────┬────────┬──────────────────┬────────┐  │
│  │ Name     │ Type   │ URL              │ Status │  │
│  ├──────────┼────────┼──────────────────┼────────┤  │
│  │ My Gitea │ Gitea  │ localhost:3300   │ ✓ OK   │  │
│  │ GitHub   │ GitHub │ api.github.com   │ ✓ OK   │  │
│  │ GitLab1  │ GitLab │ gitlab1.decl...  │ ✓ OK   │  │
│  └──────────┴────────┴──────────────────┴────────┘  │
└─────────────────────────────────────────────────────┘
```

The **Test Connection** button verifies the token works by calling the provider's API (`/user` endpoint). Green = connected, Red = failed.

### Step 2: Create Sync Profiles

A profile defines a sync relationship between two provider orgs/groups. You can create **multiple profiles between the same provider pair** with different names, directions, and conflict policies. For example:

- `gitlab-to-github-mirror` (one-way, force-push) — authoritative mirror
- `gitlab-to-github-safe` (one-way, ff-only) — safe sync that rejects on divergence
- `gitlab-github-bidirectional` (bidirectional, ff-only) — two-way sync

The profile name is the unique identifier, not the provider pair. Use as many profiles as your workflow needs.

```
┌─────────────────────────────────────────────────────┐
│  NEW SYNC PROFILE                                    │
│                                                      │
│  Name:     [gitea-to-github                       ]  │
│                                                      │
│  Source:   [My Gitea ▼]  Org: [lab-sync-test     ]  │
│  Target:   [GitHub ▼]    Org: [diwan-consulting.. ]  │
│                                                      │
│  Direction:        [→ Source to Target ▼]            │
│  Conflict Policy:  [ff-only ▼]                       │
│  Protected Branches: [main master develop         ]  │
│  Schedule:         [Every 30 minutes ▼]              │
│                                                      │
│                              [Create Profile]        │
│                                                      │
│  Existing Profiles:                                  │
│  ┌────────────────────┬───────────────────┬────────┐│
│  │ Name               │ Source → Target   │ Status ││
│  ├────────────────────┼───────────────────┼────────┤│
│  │ gitea-to-github    │ Gitea → GitHub    │ Active ││
│  │ gitlab-to-github   │ GitLab → GitHub   │ Active ││
│  │ github-to-gitea    │ GitHub → Gitea    │ Paused ││
│  └────────────────────┴───────────────────┴────────┘│
└─────────────────────────────────────────────────────┘
```

**Schedule options**: Manual only, Every 5 minutes, Every 15 minutes, Every 30 minutes, Every hour, Every 6 hours, Every 12 hours, Every 24 hours.

### Step 3: Map Repositories

For each profile, map which source repos sync to which target repos.

```
┌─────────────────────────────────────────────────────┐
│  REPO MAPPINGS — gitea-to-github                     │
│                                                      │
│  [Auto-Discover Repos]  [+ Add Manual Mapping]      │
│                                                      │
│  Auto-discovered from source (My Gitea):            │
│  ┌────┬─────────────────┬──────────────────┬──────┐ │
│  │ ✓  │ Source Repo      │ Target Repo      │ Act  │ │
│  ├────┼─────────────────┼──────────────────┼──────┤ │
│  │ [✓]│ hello-sync       │ hello-sync       │ Sync │ │
│  │ [✓]│ project-alpha    │ project-alpha    │ Sync │ │
│  │ [ ]│ internal-notes   │ —                │ Skip │ │
│  └────┴─────────────────┴──────────────────┴──────┘ │
│                                                      │
│  [Save Selected Mappings]                            │
└─────────────────────────────────────────────────────┘
```

**Auto-Discover** queries the source provider's API to list all repos in the org. The user checks which ones to sync. Target repo names default to matching the source name.

### Step 4: Run Sync

Trigger a sync manually or view scheduled sync status.

```
┌─────────────────────────────────────────────────────┐
│  SYNC JOBS                                           │
│                                                      │
│  Profile: [gitea-to-github ▼]   [▶ Sync Now]       │
│                                                      │
│  ┌─────┬────────────────┬──────────┬───────┬──────┐ │
│  │ Job │ Profile        │ Started  │Status │Repos │ │
│  ├─────┼────────────────┼──────────┼───────┼──────┤ │
│  │ #3  │ gitea-to-github│ 14:22:01 │✓ Done │ 2/2  │ │
│  │ #2  │ gitlab-to-githu│ 13:15:30 │✓ Done │ 1/1  │ │
│  │ #1  │ gitea-to-github│ 12:00:00 │✗ Fail │ 1/2  │ │
│  └─────┴────────────────┴──────────┴───────┴──────┘ │
│                                                      │
│  ▼ Job #3 — gitea-to-github                         │
│  ┌─────────────────────────────────────────────────┐│
│  │ 14:22:01 [info]  Starting sync for profile 1    ││
│  │ 14:22:02 [info]  Cloning lab-sync-test/hello... ││
│  │ 14:22:05 [info]  Pushing to diwan-consulting... ││
│  │ 14:22:08 [info]  hello-sync: success (ff-only)  ││
│  │ 14:22:08 [info]  Cloning lab-sync-test/proje... ││
│  │ 14:22:11 [info]  Pushing to diwan-consulting... ││
│  │ 14:22:14 [info]  project-alpha: success          ││
│  │ 14:22:14 [info]  Sync complete: 2/2 succeeded   ││
│  └─────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

### Step 5: Dashboard (Home)

The landing page shows at-a-glance status of everything.

```
┌─────────────────────────────────────────────────────┐
│  git-advanced-multisync                    DEC-LLC   │
│  ─────────────────────────────────────────────────── │
│  Dashboard │ Providers │ Profiles │ Mappings │ Jobs  │
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐│
│  │  Providers   │ │   Profiles   │ │  Last Sync   ││
│  │              │ │              │ │              ││
│  │   3 active   │ │   3 active   │ │  2 min ago   ││
│  │   0 failed   │ │   1 paused   │ │  ✓ success   ││
│  │              │ │              │ │              ││
│  │ [Manage →]   │ │ [Manage →]   │ │ [View →]     ││
│  └──────────────┘ └──────────────┘ └──────────────┘│
│                                                      │
│  Recent Activity:                                    │
│  ┌─────────────────────────────────────────────────┐│
│  │ 14:22  gitea-to-github  ✓ 2 repos synced       ││
│  │ 13:15  gitlab-to-github ✓ 1 repo synced        ││
│  │ 12:00  gitea-to-github  ✗ 1 conflict (ff-only) ││
│  │ 11:30  Provider "GitLab1" test: ✓ connected     ││
│  └─────────────────────────────────────────────────┘│
│                                                      │
│  Quick Actions:                                      │
│  [+ Add Provider]  [+ New Profile]  [▶ Sync All]   │
└─────────────────────────────────────────────────────┘
```

### Step 6: System Status

The status page at `/status` provides a system health overview.

```
┌─────────────────────────────────────────────────────┐
│  SYSTEM STATUS                                       │
│  ─────────────────────────────────────────────────── │
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐│
│  │  Providers   │ │   Profiles   │ │   Mappings   ││
│  │  3 total     │ │  3 total     │ │  8 total     ││
│  │  3 tested OK │ │  2 scheduled │ │  8 enabled   ││
│  └──────────────┘ └──────────────┘ └──────────────┘│
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐│
│  │   Workers    │ │  Disk Usage  │ │   Database   ││
│  │  0 running   │ │  workdir:12M │ │  size: 24 MB ││
│  │  0 queued    │ │              │ │              ││
│  └──────────────┘ └──────────────┘ └──────────────┘│
│                                                      │
│  Next Scheduled Syncs:                               │
│  ┌─────────────────┬──────────┬─────────────────┐   │
│  │ Profile         │ Interval │ Next Run        │   │
│  ├─────────────────┼──────────┼─────────────────┤   │
│  │ gitea-to-github │ 30 min   │ 14:52:00        │   │
│  │ gitlab-to-github│ 1 hr     │ 15:15:30        │   │
│  └─────────────────┴──────────┴─────────────────┘   │
│                                                      │
│  Recent Jobs:                                        │
│  ┌─────┬─────────────────┬──────────┬───────┐       │
│  │ #5  │ gitea-to-github │ 14:22:01 │ done  │       │
│  │ #4  │ gitlab-to-github│ 13:15:30 │ done  │       │
│  │ #3  │ gitea-to-github │ 12:00:00 │ fail  │       │
│  └─────┴─────────────────┴──────────┴───────┘       │
│                                                      │
│  Users:                                              │
│  ┌──────────┬─────────┬────────────────────┐        │
│  │ Username │ Role    │ Last Login         │        │
│  ├──────────┼─────────┼────────────────────┤        │
│  │ admin    │ admin   │ 2026-04-08 14:00   │        │
│  └──────────┴─────────┴────────────────────┘        │
└─────────────────────────────────────────────────────┘
```

---

## Scheduling

Each sync profile can have an optional schedule interval. When set, the background worker automatically triggers syncs at the configured frequency.

### How it works

- **Interval options**: 5 minutes, 15 minutes, 30 minutes, 1 hour, 6 hours, 12 hours, 24 hours, or manual only (no schedule).
- **Staggered start** — When a profile is created with a schedule, its `next_sync_at` is set to a random offset within the interval window. This prevents all profiles from firing at the same moment.
- **Worker loop** — The background worker runs every 5 seconds. It first checks for manually queued jobs, then checks for scheduled profiles that are due. One job per tick to avoid stacking.
- **next_sync_at advance** — The next sync time is bumped **before** the sync runs, so a slow sync cannot cause the next run to pile up.
- **Manual triggers** — Clicking "Sync Now" or calling `POST /api/sync/start/:profile_id` queues a job that runs independently of the schedule. The schedule is not affected.

### Viewing schedules

- The `/status` page shows all scheduled profiles with their interval and next run time.
- The profiles list shows `sync_interval_minutes` and `last_synced_at` for each profile.

---

## Sync Locking

Concurrent syncs of the same profile are prevented via database-level locking.

- When a sync starts, the worker sets `sync_locked = TRUE`, `sync_locked_at = NOW()`, and `sync_locked_by = 'worker-<pid>'` on the profile.
- If another sync attempts to run while the lock is held, it is skipped with a "profile locked" message.
- **Stale lock timeout** — Locks older than 30 minutes are considered stale and can be broken by a new sync. This prevents a crashed worker from permanently blocking a profile.
- The lock is **always released** after sync completes, even if the sync threw an error (wrapped in eval + finally pattern).

---

## Duplicate Prevention

Repo mappings are checked for duplicates at creation time:

- **Same pair** — If `source_full_path` and `target_full_path` already exist in any profile, the mapping is rejected with a `409 Conflict` response identifying which profile owns it.
- **Reverse direction** — If the reverse pair (target as source, source as target) exists in any profile, it is also rejected to prevent sync loops.

This applies across all profiles, not just within a single profile. A repo pair can only be synced in one direction by one profile at a time.

---

## Test Matrix

The following sync scenarios should be verified before release:

| # | Source | Target | Direction | Expected Result |
|---|--------|--------|-----------|-----------------|
| 1 | Gitea | GitHub | → | Repos appear in GitHub org |
| 2 | GitHub | Gitea | → | Repos appear in Gitea org |
| 3 | Gitea | GitLab | → | Repos appear in GitLab group |
| 4 | GitLab | Gitea | → | Repos appear in Gitea org |
| 5 | GitHub | GitLab | → | Repos appear in GitLab group |
| 6 | GitLab | GitHub | → | Repos appear in GitHub org |
| 7 | Gitea | GitHub | ↔ | Changes in either direction sync |
| 8 | Gitea | GitLab | ↔ | Changes in either direction sync |
| 9 | GitHub | GitLab | ↔ | Changes in either direction sync |
| 10 | Any | Any | → (diverged) | ff-only rejects, logs conflict |
| 11 | Any | Any | → (force) | Force-push overwrites target |
| 12 | Any | Any | ↔ (both changed) | Conflict detected and logged |

## Test Environment

| Provider | Instance | Org/Group | Repo |
|----------|----------|-----------|------|
| Gitea | localhost:3300 | lab-sync-test | hello-sync |
| GitHub | github.com | diwan-consulting-labs | hello-sync |
| GitLab | gitlab1.decllc.biz | sync-test-lab | hello-sync |

---

## Security Notes

- **Authentication required** — All pages and API endpoints (except `/api/health`) require an active session. Unauthenticated API requests return `401`. Write operations by read-only users return `403`.
- **Session-based auth** — Mojolicious session cookies with configurable secret (`GITMSYNCD_SECRET` env var).
- **Default credentials** — `admin` / `admin`. Change immediately after first login.
- **API tokens** — Stored in PostgreSQL in plain text. Encrypted storage is on the roadmap. Tokens are never displayed in the UI after entry — only the last 4 characters are shown.
- **Transport** — All provider API calls use HTTPS. Git clone/push operations support both HTTPS (token-authenticated) and SSH (key-based) per-provider.
- **Sync locking** — Database-level locks prevent concurrent syncs of the same profile. Stale lock timeout: 30 minutes.

---

*git-advanced-multisync is open source software by Diwan Enterprise Consulting LLC (DEC-LLC).*
*Licensed under MIT and GPLv3. See LICENSE files for details.*
