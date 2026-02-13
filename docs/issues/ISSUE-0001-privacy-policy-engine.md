# ISSUE-0001: Privacy Policy Engine (Private-by-default)

Status: Open
Priority: High
Target: Alpha-200

## Problem
Current alpha-100 scripts can mirror correctly, but policy enforcement is distributed in env/script usage and not centrally managed/audited.

## Required behavior
- Default deny any sync path that would expose private content to a non-private destination.
- Permit exceptions only through explicit per-repo override records.
- Record who/when/why override was approved.
- Keep internal GitLab repos private by default.

## Acceptance criteria
- A sync attempt to a public destination is blocked unless an approved override exists.
- API returns deterministic policy decision with reason code.
- UI shows policy status per mapping.
- Policy decision is stored in DB audit log.

## Notes
A visibility check on 2026-02-13 shows most repos private, with at least one public GitHub repo (`mvdiwan/kasm-registry`), so policy controls must handle mixed visibility safely.
