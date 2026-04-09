#!/usr/bin/env perl
# t/00-load.t — Verify all core modules load without error
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 3;

use_ok('Gitmsyncd::SyncEngine');
use_ok('Gitmsyncd::ResourceGovernor');
use_ok('Gitmsyncd::App');
