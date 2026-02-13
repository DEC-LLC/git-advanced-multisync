# Memory: git-advanced-multisync Track

Date: 2026-02-13
Scope: Standalone Perl sync engine (`gitmsyncd`) for advanced mapping/policy/work-item sync.

## Current state
- Project name/path: `git-advanced-multisync`
- Current main commit includes warning fix: `cadff51`
- Constructor redefinition warning resolved in:
  - `lib/Gitmsyncd/App.pm`
  - `bin/gitmsyncd.pl`
- Perl deps verified in this environment:
  - Mojolicious 9.35
  - DBI 1.643
  - DBD::Pg 3.18.0

## Core docs
- `README.md`
- `docs/ARCHITECTURE-ALPHA-200.md`
- `docs/TODO-ALPHA-100-vs-ALPHA-200.md`
- `docs/SYNC-SCOPE-MIN-MAX.md`
- `docs/issues/ISSUE-0001-privacy-policy-engine.md`
- `docs/issues/ISSUE-0002-cross-system-work-items-sync.md`

## Alpha-200 priorities
1. Implement `gitmsyncd` worker/scheduler loop and DB migration workflow.
2. Build owner/repo/profile mapping CRUD APIs.
3. Add privacy policy engine (`private-only` default + explicit override metadata).
4. Implement incremental work-item sync (issues/PRs/MRs/comments) with loop prevention.
5. Add minimal UI for mapping + per-repo sync controls + policy status.
6. Add integration tests for ff-only conflict handling and privacy regressions.

## Release/mirroring notes
- GitLab project: `github-mirror/git-advanced-multisync` (private)
- GitHub mirror: `mvdiwan/git-advanced-multisync` (private)
- Auto-mirror path is operational.
