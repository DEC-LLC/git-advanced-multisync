# git-advanced-multisync — User Guide

## Overview

git-advanced-multisync (`gitmsyncd`) synchronizes Git repositories across multiple hosting providers — GitHub, GitLab, and Gitea — through a web interface. No CLI configuration, no config files. Everything is managed from the browser.

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

Each sync uses `git clone --mirror` from the source followed by `git push --mirror` to the target. This preserves all branches, tags, and refs.

### Conflict Handling

| Policy | Behavior | Use Case |
|--------|----------|----------|
| **ff-only** | Reject if target has commits not in source | Safe default — prevents data loss |
| **force-push** | Overwrite target with source state | One-way mirrors where source is authoritative |
| **reject** | Log conflict, do nothing | Alert-only mode for monitoring divergence |

---

## UX Workflow

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

A profile defines a sync relationship between two provider orgs/groups.

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

- API tokens are stored in the PostgreSQL database. In production, use encrypted storage or a secrets manager.
- All provider communication uses HTTPS (except local Gitea dev instance).
- Tokens are never displayed in the UI after initial entry — only the last 4 characters are shown.
- Sync operations use token-authenticated HTTPS clone URLs, not SSH.
- The web UI should be protected behind authentication in production deployments.

---

*git-advanced-multisync is open source software by Diwan Enterprise Consulting LLC (DEC-LLC).*
*Licensed under MIT and GPLv3. See LICENSE files for details.*
