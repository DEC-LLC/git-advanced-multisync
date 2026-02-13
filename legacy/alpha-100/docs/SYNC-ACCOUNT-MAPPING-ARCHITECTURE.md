# Sync Architecture: Multi-Account and Bi-Directional Mirroring

## Goals
- Support GitHub -> GitLab and GitLab -> GitHub mirroring.
- Support multiple GitHub owners/accounts and multiple GitLab namespaces.
- Allow per-account and per-repo ownership mappings.
- Run as manageable systemd services/timers (start/stop/status) rather than cron.

## Key Constraints
- True active-active bi-directional writes can conflict if both sides receive unrelated commits on the same branch before next sync.
- Current framework uses mirror-style push semantics for predictable parity.
- Recommended operational policy:
  - Primary workflow: write on either side, sync quickly.
  - Avoid simultaneous conflicting history rewrites.
  - Keep protected branches to reduce accidental force-history changes.

## Components

### 1) Sync Profiles
Each profile is an env file that defines:
- Direction: `github_to_gitlab` or `gitlab_to_github`
- Credentials/token references
- Source account/group
- Default target owner/namespace
- Optional map files for overrides

Profiles are stored in `scripts/sync/profiles/`.

### 2) Mapping Files
Two optional mapping layers:
- Owner map: source owner/namespace -> target owner/namespace
- Repo map: explicit source repo path -> explicit target owner/repo

Repo map has highest priority, then owner map, then profile defaults.

### 3) Direction Scripts
- `scripts/github_gitlab_mirror.sh` for GitHub -> GitLab
- `scripts/sync/gitlab_github_mirror.sh` for GitLab -> GitHub

### 4) Profile Runner
- `scripts/sync/run_sync_profile.sh`
- Loads one profile and dispatches to the correct direction script.

## Recommended Service Layout (gitlab1)
- User `githubgitlabsync`: GitHub -> GitLab service/timer
- User `gitlabgithubsync`: GitLab -> GitHub service/timer
- Separate env files and workdirs per direction

## Access Model
- Synced repos live in GitLab group `github-mirror`.
- `madhav` is explicit Owner of group and projects.
- Additional user access can be granted via group/project membership (Owner/Maintainer as needed).

## Safety/Operational Controls
- `DRY_RUN=true` support for pre-flight validation.
- `flock` locking prevents overlapping runs.
- `retry` logic for transient network/API failures.
- Separate timers with offset schedule to reduce overlap.

## Future Enhancements
- Add conflict detection mode (`--ff-only` style) for selected branches.
- Add webhook-triggered immediate sync alongside periodic timer.
- Move secrets from plain env files to a secret manager or encrypted file workflow.

## Branch Conflict Policy (Protected Branches)

Implemented in both directions:
- `BRANCH_CONFLICT_POLICY=ff-only`
- `PROTECTED_BRANCHES="main master develop"` (space-separated)
- `UNPROTECTED_FORCE_PUSH=false` (recommended)

Behavior:
- For protected branches, destination is fetched first.
- Push is allowed only when destination branch tip is an ancestor of source tip (fast-forward).
- If non-fast-forward conflict is detected, that protected branch is skipped and logged.
- Tags are synced normally.

This prevents protected-branch history rewrites during race conditions in bi-directional sync.
