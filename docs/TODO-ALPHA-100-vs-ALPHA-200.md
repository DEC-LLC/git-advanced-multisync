# TODO: Alpha-100 -> Alpha-200

## Policy and privacy
- [ ] Add privacy policy enforcement defaults in alpha-200 (`private-only` unless explicit per-repo override).
- [ ] Add per-repo override model with approval metadata and expiration.
- [ ] Add policy audit logs for every sync decision (`allow/deny/skip`).
- [ ] Add dry-run policy report endpoint.

## Core backend
- [ ] Implement persistent mapping tables (owner/repo/profile).
- [ ] Build scheduler + worker queue (`sync_jobs`, retries, backoff).
- [ ] Add repository visibility validation before push in both directions.
- [ ] Add idempotent repo bootstrap path for GitHub/GitLab.

## API/UI
- [ ] REST endpoints for mappings, profiles, jobs, policy checks.
- [ ] Minimal UI for per-repo start/stop and visibility policy status.
- [ ] Add role-based admin controls for policy overrides.

## QA and release
- [ ] Add integration tests for ff-only race/conflict cases.
- [ ] Add privacy regression tests (private->public blocked by default).
- [ ] Add packaging/release pipeline for standalone Perl distribution.
- [ ] Define alpha-200 acceptance checklist and rollback plan.
