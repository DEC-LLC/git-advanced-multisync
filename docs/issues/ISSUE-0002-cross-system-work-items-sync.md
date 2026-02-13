# ISSUE-0002: Cross-System Work Item Sync (Issues/PRs/MRs)

Status: Open
Priority: High
Target: Alpha-200

## Problem
Current automation mirrors Git refs only (branches/tags/commits). Work items (issues, pull requests, merge requests, comments, reviews, approvals) are not continuously synchronized.

## Goals
- Keep repository sync and work-item sync decoupled but coordinated.
- Preserve traceability between GitHub and GitLab work items.
- Avoid destructive or duplicate replay in either direction.

## Non-goals (alpha-200)
- Full-fidelity, lossless 1:1 mapping of every platform-specific field.
- Syncing all historical events for every item by default.

## Required alpha-200 outcomes
- Bi-directional issue sync baseline with mapping table and idempotency keys.
- PR <-> MR link model with status rollup fields.
- Comment sync with loop-prevention marker.
- Configurable sync modes per repo: off, minimal, standard, full.

## Initial tasks
- [ ] Add DB tables for work-item mapping and event checkpoints.
- [ ] Add adapters for GitHub Issues/PR API and GitLab Issues/MR API.
- [ ] Add policy to map labels/milestones/assignees with fallback rules.
- [ ] Add backfill mode and incremental poll/webhook mode.
- [ ] Add conflict policy (last-writer-wins with audit log) for mutable fields.
