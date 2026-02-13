# gitlab-advanced-multisync alpha-200 Architecture

## Objective
Perl-based standalone service (`syncd`) for multi-account, multi-owner GitHub<->GitLab synchronization with mapping controls, API, and minimal UI.

## Core Components
- `syncd` daemon (Perl): scheduler + worker orchestration.
- PostgreSQL metadata DB: mappings, profiles, sync runs, conflict logs.
- REST API: config + job control.
- Minimal Web UI: mapping management and run controls.

## Service Boundaries
- Git provider adapters:
  - GitHub adapter
  - GitLab adapter
- Sync engine:
  - forward/reverse sync runner
  - branch conflict policy checks
- Policy engine:
  - protected branch ff-only handling
  - force policy gates

## Data Model (high level)
- owners
- owner_mappings
- repo_mappings
- sync_profiles
- sync_jobs
- sync_job_events

## Security
- Store only credential references in DB.
- Resolve secrets from env/file secret stores.
- Strict audit trail for all sync actions.

## Packaging Direction
- Standalone Perl app deployable via systemd.
- Build with cpanfile + carton; later explore packed binary workflow.
