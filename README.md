# git-advanced-multisync

<div align="center">

**Provider-neutral multi-account Git sync engine.**

Sync repositories across GitHub, GitLab, Bitbucket, and self-hosted instances — with conflict resolution, branch mapping, and a web dashboard.

[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

[Features](#features) · [Quick Start](#quick-start) · [Architecture](#architecture) · [Contributing](#contributing)

</div>

---

## What is git-advanced-multisync?

If you host code on GitHub AND GitLab AND a self-hosted instance — or you manage multiple accounts across providers — keeping them in sync is a headache. Mirror scripts break. Webhooks miss events. Branch naming conventions differ. And when two people push to different remotes at the same time, nobody wins.

**git-advanced-multisync** is a standalone sync engine that:

- Syncs repositories across **any combination** of GitHub, GitLab, Bitbucket, Gitea, and self-hosted Git servers
- Handles **multi-account** scenarios (personal + work + org, across providers)
- Resolves **conflicts** when the same branch is pushed to different remotes
- Maps **branch names** between providers (your `main` can be their `master`)
- Provides a **web dashboard** showing sync status, history, and failures
- Runs as a **daemon** with a REST API, or as a one-shot CLI command
- Stores sync state in **PostgreSQL** for reliability and auditability

## Features

- **Provider-neutral** — not tied to any single Git hosting platform
- **Conflict resolution** — configurable strategies (ours-wins, theirs-wins, manual review)
- **Branch mapping** — rename branches across providers automatically
- **Privacy policy engine** — control which repos sync where (don't leak private repos to public providers)
- **Web UI** — real-time sync status, history, manual trigger
- **REST API** — automate everything, integrate with CI/CD
- **CI modes** — multiple `.gitlab-ci.yml` configurations for different sync aggressiveness levels
- **Audit trail** — every sync operation is logged with timestamps, sources, and outcomes

## Quick Start

### Requirements

- Perl 5.26+
- PostgreSQL 14+
- Git 2.30+
- cpanm (for Perl dependencies)

### Install

```bash
git clone https://github.com/DEC-LLC/git-advanced-multisync.git
cd git-advanced-multisync
cpanm --installdeps .
```

### Set up the database

```bash
createdb gitmsyncd
psql -U gitmsyncd -d gitmsyncd -f db/schema.sql
```

### Configure

Edit your sync configuration (providers, repos, branch mappings) — see `docs/ARCHITECTURE-ALPHA-200.md` for the full configuration reference.

### Run

```bash
# As a daemon (background, REST API on port 9097)
GITMSYNCD_DSN='dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432' \
GITMSYNCD_DB_USER='gitmsyncd' \
GITMSYNCD_DB_PASS='gitmsyncd' \
  perl bin/gitmsyncd.pl

# Web dashboard
open http://127.0.0.1:9097
```

### One-shot sync (CLI)

```bash
perl bin/gitmsyncd.pl --once --verbose
```

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   GitHub     │     │   GitLab    │     │  Self-hosted │
│  (account 1) │     │  (account 2)│     │  (Gitea etc) │
└──────┬───────┘     └──────┬──────┘     └──────┬───────┘
       │                    │                    │
       └────────────┬───────┘────────────────────┘
                    │
            ┌───────▼────────┐
            │  gitmsyncd     │
            │  sync engine   │
            │  (Perl daemon) │
            ├────────────────┤
            │  PostgreSQL    │
            │  sync state    │
            ├────────────────┤
            │  REST API      │
            │  Web dashboard │
            └────────────────┘
```

See `docs/ARCHITECTURE-ALPHA-200.md` for the full design document.

## CI Integration

Multiple CI mode configurations are included:

| Mode | File | Description |
|---|---|---|
| Strict gate | `.gitlab-ci.strict-gate.yml` | All tests must pass before sync |
| Balanced | `.gitlab-ci.balanced.yml` | Tests run in parallel with sync |
| Fully open | `.gitlab-ci.fully-open.yml` | Sync always runs, tests are advisory |
| Adoption mode | `.gitlab-ci.adoption-mode.yml` | For onboarding new repos gradually |

## Documentation

- `docs/ARCHITECTURE-ALPHA-200.md` — full architecture and design
- `docs/ALPHA-100-CAPABILITIES.md` — legacy baseline capabilities
- `docs/TODO-ALPHA-100-vs-ALPHA-200.md` — migration roadmap
- `docs/SYNC-SCOPE-MIN-MAX.md` — sync scope configuration
- `docs/issues/` — tracked design issues and RFCs

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Author

**DEC-LLC** (Diwan Enterprise Consulting LLC)
[dec-llc.biz](https://dec-llc.biz) · [info@decllc.biz](mailto:info@decllc.biz)
