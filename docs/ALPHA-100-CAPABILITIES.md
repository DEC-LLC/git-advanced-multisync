# Alpha-100 Capabilities Snapshot

Date: 2026-02-13
Source: Existing production bash-based mirror implementation from `DECLLC-GITLAB`.

## Included components
- GitHub -> GitLab mirror script (`github_gitlab_mirror.sh`)
- GitLab -> GitHub mirror script (`gitlab_github_mirror.sh`)
- Profile runner (`run_sync_profile.sh`)
- Example env/profile/map files
- Existing architecture/deployment docs from current install

## What Alpha-100 does now
- Bidirectional sync using systemd timer/service orchestration.
- Supports API mode and list-file mode.
- Supports repo-name mapping via `REPO_MAP_FILE`.
- Creates missing repos as private when API-token create path is used.
- Uses ff-only conflict policy for protected branches.
- Avoids forced history rewrites on protected branches.

## Known limits in Alpha-100
- No mandatory privacy policy guardrail engine for existing destination repos.
- No centralized owner/account mapping DB.
- No API/UI control plane for per-repo start/stop.
- No policy lifecycle/audit table for sync decisions.
- Bash-driven control plane is harder to test at scale.
