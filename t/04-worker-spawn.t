#!/usr/bin/env perl
# t/04-worker-spawn.t — Verify the worker script compiles cleanly
#
# This does NOT run the worker (which needs a database). It only checks
# that the script parses without syntax errors.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 2;

my $worker_script = "$FindBin::Bin/../bin/gitmsyncd-worker.pl";

# ── Script exists ──────────────────────────────────────────────────
ok(-f $worker_script, 'worker script exists at bin/gitmsyncd-worker.pl');

# ── Script compiles (perl -c) ─────────────────────────────────────
# perl -c only checks syntax, it does not execute the script.
# We add -Ilib so module imports resolve.
my $lib_dir = "$FindBin::Bin/../lib";
my $output = `perl -I"$lib_dir" -c "$worker_script" 2>&1`;
my $rc = $? >> 8;

is($rc, 0, "worker script compiles without errors")
    or diag("perl -c output: $output");
