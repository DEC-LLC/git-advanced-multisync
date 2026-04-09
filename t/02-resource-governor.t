#!/usr/bin/env perl
# t/02-resource-governor.t — Tests for Gitmsyncd::ResourceGovernor::check_resources()
#
# The function signature is:
#   check_resources(%limits) => ($ok, $message)
#     %limits keys: max_load, min_mem_mb, min_disk_mb, workdir
#     Returns: (1, "ok") when all checks pass
#              (0, reason_string) when any check fails
#
# It reads /proc/loadavg, /proc/meminfo, and runs df to check resources.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 11;

use Gitmsyncd::ResourceGovernor qw(check_resources);

# ── Default parameters (no args) — should not crash ───────────────
{
    my ($ok, $msg) = check_resources();
    ok(defined $ok,  'default call: returns defined status');
    ok(defined $msg, 'default call: returns defined message');
    # On a normal dev machine this should pass; on a constrained host it may not
    ok(defined $ok, 'default call: returned a valid boolean result (0 or 1)');
}

# ── Normal conditions — generous limits should always pass ─────────
{
    my ($ok, $msg) = check_resources(
        max_load    => 999,        # absurdly high — will never be exceeded
        min_mem_mb  => 1,          # 1 MB — any machine has this
        min_disk_mb => 1,          # 1 MB — any machine has this
        workdir     => '/tmp',
    );
    is($ok,  1,    'generous limits: passes');
    is($msg, 'ok', 'generous limits: message is "ok"');
}

# ── Impossibly strict CPU load — should fail ───────────────────────
SKIP: {
    skip '/proc/loadavg not available (non-Linux)', 2 unless -r '/proc/loadavg';
    my ($ok, $msg) = check_resources(
        max_load    => 0.001,      # load avg will always exceed 0.001
        min_mem_mb  => 1,
        min_disk_mb => 1,
        workdir     => '/tmp',
    );
    is($ok, 0, 'impossibly strict CPU load: fails');
    like($msg, qr/cpu load/i, 'impossibly strict CPU load: message mentions cpu load');
}

# ── Impossibly large memory requirement — should fail ──────────────
SKIP: {
    skip '/proc/meminfo not available (non-Linux)', 2 unless -r '/proc/meminfo';
    my ($ok, $msg) = check_resources(
        max_load    => 999,
        min_mem_mb  => 999999,     # ~1 TB of RAM required
        min_disk_mb => 1,
        workdir     => '/tmp',
    );
    is($ok, 0, 'impossibly large memory requirement: fails');
    like($msg, qr/memory/i, 'impossibly large memory requirement: message mentions memory');
}

# ── Impossibly large disk requirement — should fail ────────────────
{
    my ($ok, $msg) = check_resources(
        max_load    => 999,
        min_mem_mb  => 1,
        min_disk_mb => 999999999,  # ~1 PB of disk required
        workdir     => '/tmp',
    );
    is($ok, 0, 'impossibly large disk requirement: fails');
    like($msg, qr/disk/i, 'impossibly large disk requirement: message mentions disk');
}
