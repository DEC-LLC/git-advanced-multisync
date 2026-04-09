#!/usr/bin/env perl
# t/05-sync-engine-unit.t — SyncEngine unit tests
#
# Tests that the module exports are correct and that calling
# run_sync_job with missing args fails gracefully (dies/warns)
# rather than crashing the process.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 5;

# ── Exports ────────────────────────────────────────────────────────
use_ok('Gitmsyncd::SyncEngine');

can_ok('Gitmsyncd::SyncEngine', 'run_sync_job');
can_ok('Gitmsyncd::SyncEngine', 'branch_matches_filter');

# ── Import by name ─────────────────────────────────────────────────
{
    # Verify the functions are importable via @EXPORT_OK
    package TestImport;
    use Gitmsyncd::SyncEngine qw(run_sync_job branch_matches_filter);
    Test::More::ok(defined &run_sync_job,         'run_sync_job is importable');
    Test::More::ok(defined &branch_matches_filter, 'branch_matches_filter is importable');
}

# NOTE: We do not call run_sync_job() without a real $dbh because the
# very first thing it does is $dbh->do(...), which would die with
# "Can't call method 'do' on an undefined value". That is the expected
# behavior — the function requires a database handle. Testing that it
# dies on undef dbh would just be testing Perl method dispatch, not our
# code, so we skip it here and cover it in the integration test instead.
