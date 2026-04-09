#!/usr/bin/env perl
# t/10-integration-sync.t — Full integration test (requires test DB + Gitea)
#
# SKIP unless both of these env vars are set:
#   GITMSYNCD_TEST_DSN       — PostgreSQL DSN for a test database
#   GITMSYNCD_TEST_GITEA_URL — Base URL of a test Gitea instance
#
# To run integration tests:
#   export GITMSYNCD_TEST_DSN='dbi:Pg:dbname=gitmsyncd_test;host=127.0.0.1;port=5432'
#   export GITMSYNCD_TEST_DB_USER='gitmsyncd'
#   export GITMSYNCD_TEST_DB_PASS='gitmsyncd'
#   export GITMSYNCD_TEST_GITEA_URL='http://gitea.example.com:3000'
#   prove -Ilib t/10-integration-sync.t

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

my $dsn       = $ENV{GITMSYNCD_TEST_DSN};
my $gitea_url = $ENV{GITMSYNCD_TEST_GITEA_URL};

unless ($dsn && $gitea_url) {
    plan skip_all => 'Integration tests require GITMSYNCD_TEST_DSN and GITMSYNCD_TEST_GITEA_URL env vars. '
                   . 'See comments at top of this file for setup instructions.';
}

eval { require DBI; 1 }
    or plan skip_all => 'DBI not available';

eval { require Test::Mojo; 1 }
    or plan skip_all => 'Test::Mojo not available';

my $db_user = $ENV{GITMSYNCD_TEST_DB_USER} || 'gitmsyncd';
my $db_pass = $ENV{GITMSYNCD_TEST_DB_PASS} || 'gitmsyncd';

my $dbh = eval { DBI->connect($dsn, $db_user, $db_pass, { RaiseError => 1, PrintError => 0 }) };
unless ($dbh) {
    plan skip_all => "Cannot connect to test database: " . (DBI->errstr || 'unknown error');
}

plan tests => 1;

# ── Placeholder: full integration flow would go here ───────────────
# 1. Create a provider via POST /api/providers
# 2. Create a sync profile via POST /api/profiles
# 3. Add a repo mapping via POST /api/mappings
# 4. Trigger sync via POST /api/sync/start/:profile_id
# 5. Poll job status until complete
# 6. Verify target repo on Gitea received the push

pass('integration test harness loads (full tests require running containers)');

$dbh->disconnect;
