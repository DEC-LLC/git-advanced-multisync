# TODO: git-advanced-multisync alpha-200

## Product Scope
- [ ] Finalize feature scope for alpha-200 and hard non-goals.
- [ ] Confirm deployment target (single-node service on gitlab1 or dedicated host).

## Backend (Perl)
- [ ] Implement `gitmsyncd` daemon service with worker loop.
- [ ] Add config loader and env validation.
- [ ] Add DB migration runner for schema versioning.
- [ ] Add incremental work-item sync workers (issues/PRs/MRs + comments).

## DB (PostgreSQL)
- [ ] Owner mapping tables + repo mapping tables.
- [ ] Sync profile + credential reference tables.
- [ ] Sync run history, status, and conflict log tables.

## REST API
- [ ] CRUD for owners, mappings, profiles.
- [ ] Start/stop/retry sync jobs.
- [ ] Health, metrics, and recent runs endpoint.
- [ ] Work-item sync endpoints (mapping/status/replay).

## Minimal UI
- [ ] Dashboard with profile status and recent jobs.
- [ ] Mapping editor (owner/repo).
- [ ] Per-repo sync start/stop controls.

## Packaging
- [ ] Build portable Perl distribution strategy.
- [ ] Add systemd unit templates.
- [ ] Add checksum/signature release artifacts.
