#!/usr/bin/env perl
# t/01-branch-filter.t — Thorough tests for branch_matches_filter()
#
# The function signature is:
#   branch_matches_filter($branch, $filter) => 1 (match) | 0 (no match)
#
# Behavior:
#   - undef/empty/whitespace-only filter => match everything (return 1)
#   - Filter is a comma-separated list of patterns
#   - Each pattern can contain * which becomes .* (matches anything incl. /)
#   - Patterns are split on /\s*,\s*/ and anchored with ^...$
#   - Empty patterns between commas are skipped (next unless /\S/)

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 30;

use Gitmsyncd::SyncEngine qw(branch_matches_filter);

# ── NULL / empty / whitespace filter => match all ──────────────────
is(branch_matches_filter('main',    undef), 1, 'undef filter matches anything');
is(branch_matches_filter('develop', undef), 1, 'undef filter matches develop');
is(branch_matches_filter('main',    ''),    1, 'empty string filter matches anything');
is(branch_matches_filter('main',    '   '), 1, 'whitespace-only filter matches anything');
is(branch_matches_filter('main',    "\t"),  1, 'tab-only filter matches anything');

# ── Exact match ────────────────────────────────────────────────────
is(branch_matches_filter('main',    'main'),    1, 'exact match: main matches main');
is(branch_matches_filter('develop', 'develop'), 1, 'exact match: develop matches develop');
is(branch_matches_filter('main',    'develop'), 0, 'exact mismatch: main does not match develop');
is(branch_matches_filter('develop', 'main'),    0, 'exact mismatch: develop does not match main');

# ── Comma-separated list ──────────────────────────────────────────
is(branch_matches_filter('main',      'main,develop'), 1, 'comma list: main matches main,develop');
is(branch_matches_filter('develop',   'main,develop'), 1, 'comma list: develop matches main,develop');
is(branch_matches_filter('feature/x', 'main,develop'), 0, 'comma list: feature/x does NOT match main,develop');
is(branch_matches_filter('staging',   'main,develop'), 0, 'comma list: staging does NOT match main,develop');

# ── Glob patterns (* => .*) ───────────────────────────────────────
is(branch_matches_filter('release/v1.0', 'release/*'), 1, 'glob: release/v1.0 matches release/*');
is(branch_matches_filter('release/v2.0', 'release/*'), 1, 'glob: release/v2.0 matches release/*');
is(branch_matches_filter('main',         'release/*'), 0, 'glob: main does NOT match release/*');
is(branch_matches_filter('feature/my-branch', 'feature/*'), 1, 'glob: feature/my-branch matches feature/*');
is(branch_matches_filter('feature/deep/nested', 'feature/*'), 1, 'glob: feature/deep/nested matches feature/* (star matches /)');

# ── Combined patterns ─────────────────────────────────────────────
my $combined = 'main,release/*,hotfix/*';
is(branch_matches_filter('main',          $combined), 1, 'combined: main matches');
is(branch_matches_filter('release/v1.0',  $combined), 1, 'combined: release/v1.0 matches');
is(branch_matches_filter('hotfix/urgent', $combined), 1, 'combined: hotfix/urgent matches');
is(branch_matches_filter('develop',       $combined), 0, 'combined: develop does NOT match');
is(branch_matches_filter('feature/x',     $combined), 0, 'combined: feature/x does NOT match');

# ── Edge cases: whitespace around commas (split handles \s*,\s*) ───
# Note: split(/\s*,\s*/, ...) trims whitespace adjacent to commas,
# but does NOT trim leading whitespace on the first element or trailing
# whitespace on the last element. So "main , develop" works but
# " main , develop " leaves leading/trailing space on the outer patterns.
is(branch_matches_filter('main',    'main , develop'), 1, 'whitespace around comma: main matches');
is(branch_matches_filter('develop', 'main , develop'), 1, 'whitespace around comma: develop matches');

# ── Edge case: empty patterns between commas ───────────────────────
is(branch_matches_filter('main',    'main,,develop'), 1, 'empty between commas: main matches');
is(branch_matches_filter('develop', 'main,,develop'), 1, 'empty between commas: develop matches');
is(branch_matches_filter('other',   'main,,develop'), 0, 'empty between commas: other does NOT match');

# ── Edge case: single star matches everything ──────────────────────
is(branch_matches_filter('anything-at-all', '*'), 1, 'single star matches any branch');

# ── Edge case: partial name is not a match (anchored) ──────────────
is(branch_matches_filter('main-extra', 'main'), 0, 'partial name: main-extra does NOT match exact "main"');
