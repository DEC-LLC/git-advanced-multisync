# Tutorial Screenshots Plan

## Goal

Replace the current development screenshots with polished tutorial-quality images that teach by example. Anyone viewing the GitHub README should understand the product workflow just by looking at the screenshots — no reading required.

## Current State

The existing screenshots (in `docs/screenshots/`) show real data from our test session:
- Org names like `lab-sync-test` and `diwan-consulting-labs` — meaningless to a visitor
- Provider names like `Gitea Local` and `GITHUB` — generic
- Repo name `hello-sync` — doesn't convey a real use case

## Target State

Screenshots that tell a story: **"A company called Acme Engineering mirrors their internal GitLab repos to GitHub for open-source visibility, and syncs a Gitea dev instance for local development."**

## Test Data Setup

### Providers

| Name | Type | URL | Purpose in Story |
|------|------|-----|------------------|
| `GitLab Production` | GitLab | https://gitlab1.decllc.biz | The company's internal GitLab — source of truth |
| `GitHub Public` | GitHub | (default) | Public mirror for open-source repos |
| `Gitea Dev` | Gitea | http://localhost:3300 | Developer's local Gitea for fast iteration |

### Organizations/Groups

| Provider | Org/Group | Story |
|----------|-----------|-------|
| GitLab | `acme-engineering` | Company's main engineering group |
| GitHub | `acme-oss` (or use `diwan-consulting-labs`) | Public open-source mirror |
| Gitea | `acme-dev` | Local development sandbox |

### Repositories (create on all three)

| Repo | Description | Why it syncs |
|------|-------------|--------------|
| `webapp` | Main web application | Production code, mirrored to GitHub for contributors |
| `api-service` | Backend REST API | Core service, needs to be on all three |
| `infrastructure` | Terraform/Ansible configs | Internal only — syncs GitLab → Gitea, NOT to GitHub |
| `docs` | Public documentation | Syncs everywhere |
| `mobile-app` | Mobile client | Bidirectional between GitLab and GitHub |

### Sync Profiles

| Profile Name | Source | Target | Direction | Policy | Schedule | Story |
|-------------|--------|--------|-----------|--------|----------|-------|
| `production-to-public-mirror` | GitLab Production / acme-engineering | GitHub Public / acme-oss | → One-way | force-push | Every 30 min | Authoritative mirror for OSS visibility |
| `production-to-dev-sync` | GitLab Production / acme-engineering | Gitea Dev / acme-dev | → One-way | ff-only | Every 15 min | Devs get latest code locally |
| `mobile-bidirectional` | GitLab Production / acme-engineering | GitHub Public / acme-oss | ↔ Bidirectional | ff-only | Every hour | External contributors can PR on GitHub |
| `internal-only-infra` | GitLab Production / acme-engineering | Gitea Dev / acme-dev | → One-way | ff-only | Manual | Infrastructure code, sync on demand |

### Repo Mappings per Profile

**production-to-public-mirror:**
- webapp, api-service, docs, mobile-app (4 repos)
- NOT infrastructure (internal only)

**production-to-dev-sync:**
- webapp, api-service, infrastructure, docs (4 repos)
- NOT mobile-app (devs don't need it locally)

**mobile-bidirectional:**
- mobile-app only (1 repo)

**internal-only-infra:**
- infrastructure only (1 repo, manual sync)

## Screenshot Sequence (the tutorial story)

### 1. `01-dashboard-empty.png` — Fresh Install
- No providers, no profiles
- Getting Started section visible
- Caption: "First launch — the Getting Started guide walks you through setup"

### 2. `02-add-provider.png` — Adding GitLab Production
- Provider form open with GitLab selected
- URL filled in, token masked
- Help text visible showing how to generate a token
- Caption: "Add your first provider — GitLab, GitHub, or Gitea"

### 3. `03-providers-all-green.png` — Three Providers Connected
- All three providers with green status dots
- Test results showing authenticated usernames
- Caption: "All three providers connected and tested"

### 4. `04-create-profile.png` — Creating the Mirror Profile
- Profile form with meaningful names filled in
- `production-to-public-mirror` as the name
- Source: GitLab Production / acme-engineering
- Target: GitHub Public / acme-oss
- Direction: One-way, Policy: force-push
- Schedule: Every 30 minutes
- Caption: "Create a sync profile — source, target, direction, conflict policy, and schedule"

### 5. `05-profiles-list.png` — All Four Profiles
- Table showing all four profiles with schedule badges
- Different directions and policies visible
- Caption: "Multiple profiles between the same providers — different repos, different policies"

### 6. `06-profile-discover-repos.png` — Auto-Discover
- Profile detail panel open
- Auto-discover showing 5 repos from source
- Some checked, `infrastructure` unchecked for the public mirror
- Caption: "Auto-discover repos from the source provider — select which ones to sync"

### 7. `07-profile-repos-configured.png` — Repos Added
- Profile detail showing 4 repos in the synced repos table
- Enable/disable toggles visible
- Caption: "Repos configured for this profile — enable, disable, or remove individually"

### 8. `08-sync-running.png` — Sync in Progress
- Jobs page showing a running job
- Spinner or "running" badge
- Caption: "Sync in progress — each repo is cloned and pushed"

### 9. `09-sync-complete.png` — Successful Sync
- Jobs page showing green "success" badge
- Event log panel showing the per-repo results
- "synced 4/4" message
- Caption: "Sync complete — event log shows what happened for each repo"

### 10. `10-dashboard-active.png` — Dashboard with Activity
- All stats populated (3 providers, 4 profiles, recent jobs)
- Provider status, profile summary, job history all filled
- Last sync: success
- Caption: "Dashboard at a glance — providers, profiles, and recent sync activity"

## Execution Steps

1. **Wipe test data:** Drop and recreate the gitmsyncd database
2. **Create providers:** GitLab Production, GitHub Public, Gitea Dev
3. **Create orgs/repos:** acme-engineering (GitLab), acme-oss or reuse diwan-consulting-labs (GitHub), acme-dev (Gitea)
4. **Create profiles:** All four with the names and settings above
5. **Add repos via auto-discover:** Screenshot at each step
6. **Run sync:** Screenshot the job progress and completion
7. **Dashboard screenshot:** Final state with all data populated
8. **Capture at 1440x900:** Consistent viewport, Chrome headless or manual
9. **Replace** `docs/screenshots/` with new images
10. **Update README** with new screenshot descriptions and captions

## Timing

Do this as part of the pre-announcement prep, right before:
- Reddit post to r/selfhosted, r/devops, r/git
- Hacker News "Show HN" post
- DEC-LLC forum announcement
- Open source page update on dec-llc.biz

## Notes

- Use Chrome at 1440x900 for consistency
- Take screenshots manually (not headless) so cursor/focus states look natural
- Crop the browser chrome — show just the page content
- Consider a dark-mode variant for some screenshots (future)
- The story should feel like a real company's workflow, not a toy example
