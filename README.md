# gitlab-advanced-multisync (alpha-200 scaffold)

Perl-based standalone add-on for multi-account GitHub<->GitLab sync management.

## Included in alpha-200 scaffold
- `bin/syncd.pl` backend entrypoint
- PostgreSQL schema: `db/schema.sql`
- REST API skeleton
- Minimal web UI template
- Architecture document in `docs/ARCHITECTURE-ALPHA-200.md`

## Quick start (dev)
```bash
cd gitlab-advanced-multisync
cpanm --installdeps .
psql -U syncd -d syncd -f db/schema.sql
SYNCD_DSN='dbi:Pg:dbname=syncd;host=127.0.0.1;port=5432' \
SYNCD_DB_USER='syncd' \
SYNCD_DB_PASS='syncd' \
  perl bin/syncd.pl
```

Then open `http://127.0.0.1:9097`.
