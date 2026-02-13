# git-advanced-multisync (alpha-200 scaffold)

Perl-based standalone add-on for multi-account GitHub<->GitLab sync management.

## Included in alpha-200 scaffold
- `bin/gitmsyncd.pl` backend entrypoint
- PostgreSQL schema: `db/schema.sql`
- REST API skeleton
- Minimal web UI template
- Architecture document in `docs/ARCHITECTURE-ALPHA-200.md`

## Alpha-100 legacy baseline
- Snapshot of current working bash sync stack is stored under `legacy/alpha-100/`.
- This baseline is tagged as `alpha-100` in this repository to preserve behavior history.
- Gap and planning docs:
  - `docs/ALPHA-100-CAPABILITIES.md`
  - `docs/TODO-ALPHA-100-vs-ALPHA-200.md`
  - `docs/issues/ISSUE-0001-privacy-policy-engine.md`
  - `docs/issues/ISSUE-0002-cross-system-work-items-sync.md`
  - `docs/SYNC-SCOPE-MIN-MAX.md`

## Quick start (dev)
```bash
cd git-advanced-multisync
cpanm --installdeps .
psql -U gitmsyncd -d gitmsyncd -f db/schema.sql
GITMSYNCD_DSN='dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432' \
GITMSYNCD_DB_USER='gitmsyncd' \
GITMSYNCD_DB_PASS='gitmsyncd' \
  perl bin/gitmsyncd.pl
```

Then open `http://127.0.0.1:9097`.
