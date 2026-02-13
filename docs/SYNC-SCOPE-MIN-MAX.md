# Sync Scope: Minimum vs Maximum (Alpha-200)

Date: 2026-02-13

## Why this document
We need a practical scope for cross-system synchronization beyond Git refs, while avoiding unnecessary use of bulk import/export workflows unless they provide clear operational value.

## Baseline fact pattern from current platform capabilities
- GitLab repository mirroring is for branches/tags/commits, not continuous issue/PR synchronization.
- GitLab GitHub importer can migrate many work-item objects (issues, pull requests, comments, events, reviews, labels, milestones, wiki, attachments), but it is migration-oriented.
- GitLab project import/export is strong for migration/backups and relation-level re-import, but excludes several operational items (for example CI/CD variables, registry images, job traces/artifacts, webhooks, encrypted tokens).

## Minimum sync scope (recommended starting point)
- Git refs: branches/tags/commits (already implemented).
- Issues:
  - title, body, state(open/closed), labels, milestones, assignees
  - top-level comments
- PR/MR linkage:
  - reference link and state rollup (open/closed/merged)
  - basic review summary state only (no deep inline-thread parity at first)

Benefits:
- Fastest path to useful collaboration continuity.
- Lower risk of rewrite/loop bugs.
- Smallest operational overhead.

## Maximum sync scope (later phase)
- Everything in minimum scope plus:
  - PR review threads and inline diff comments
  - review approvals/requested reviewers
  - release metadata and release notes mapping
  - wiki page sync
  - attachment transfer and pointer rewriting
  - full event timeline sync with cursor checkpoints

Risks:
- Higher API volume and edge-case complexity.
- More conflict cases across divergent data models.
- Larger QA matrix and operational support burden.

## When import/export is worth using
Use import/export workflows when one of these is true:
- Initial one-time migration/backfill of large history.
- Disaster recovery restore.
- Bulk relation replay for drift correction.

## When to avoid import/export (prefer live sync engine)
- Day-to-day collaboration sync.
- Low-latency bi-directional updates.
- Per-repo policy-driven selective sync.

## Proposed policy
- Default: live API/webhook incremental sync for ongoing operations.
- Optional: import/export only for bootstrap, recovery, or targeted backfill.
- Every import/export run must be recorded as a maintenance event in audit logs.
