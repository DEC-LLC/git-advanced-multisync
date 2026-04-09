#!/usr/bin/env perl
# t/03-api-health.t — Web API smoke tests using Test::Mojo
#
# These tests require:
#   1. Test::Mojo (from Mojolicious)
#   2. A PostgreSQL test database
#
# Set GITMSYNCD_TEST_DSN, GITMSYNCD_TEST_DB_USER, GITMSYNCD_TEST_DB_PASS
# to run against a real database. Otherwise the test is skipped.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

# Check prerequisites
eval { require Test::Mojo; 1 }
    or plan skip_all => 'Test::Mojo not available (install Mojolicious)';

eval { require DBI; 1 }
    or plan skip_all => 'DBI not available';

# Try to connect to test database
my $dsn  = $ENV{GITMSYNCD_TEST_DSN}     || 'dbi:Pg:dbname=gitmsyncd_test;host=127.0.0.1;port=5432';
my $user = $ENV{GITMSYNCD_TEST_DB_USER} || 'gitmsyncd';
my $pass = $ENV{GITMSYNCD_TEST_DB_PASS} || 'gitmsyncd';

my $test_dbh = eval { DBI->connect($dsn, $user, $pass, { RaiseError => 1, PrintError => 0 }) };
unless ($test_dbh) {
    plan skip_all => "Test database not available ($dsn): " . (DBI->errstr || 'unknown error');
}
$test_dbh->disconnect;

# Point the app at the test database and disable worker auto-start
$ENV{GITMSYNCD_DSN}           = $dsn;
$ENV{GITMSYNCD_DB_USER}       = $user;
$ENV{GITMSYNCD_DB_PASS}       = $pass;
$ENV{GITMSYNCD_NO_AUTOSTART}  = 1;

plan tests => 8;

# Load the app module — Mojolicious::Lite exports app() into Gitmsyncd::App
require Gitmsyncd::App;

# Call start() to register all routes (but don't call app->start which
# would launch the server). We call Gitmsyncd::App::start() which sets
# up helpers, routes, etc. However, start() ends with app->start('daemon',...)
# which would block. Instead, we grab the app object directly — the routes
# are registered at compile time by Mojolicious::Lite when the module loads.
#
# Gitmsyncd::App uses Mojolicious::Lite, so the routes inside start()
# are only registered when start() is called. We need a way to register
# routes without launching the daemon. Since the app->start() call at the
# end of start() would launch the server, we'll monkey-patch it.
{
    no warnings 'redefine';
    # Temporarily make app->start() a no-op so it registers routes but
    # doesn't launch the daemon
    my $mojo_app = Gitmsyncd::App::app();
    my $original_start = \&Mojolicious::start;
    local *Mojolicious::start = sub { return $_[0] };
    Gitmsyncd::App::start();
    # Restore
    *Mojolicious::start = $original_start;

    my $t = Test::Mojo->new($mojo_app);

    # ── Health endpoint (public, no auth) ──────────────────────────
    $t->get_ok('/api/health')
      ->status_is(200)
      ->json_is('/status' => 'ok');

    # ── Login page (public) ────────────────────────────────────────
    $t->get_ok('/login')
      ->status_is(200);

    # ── POST /api/providers without auth returns 401 ───────────────
    $t->post_ok('/api/providers', json => { name => 'test' })
      ->status_is(401)
      ->json_has('/error');
}
