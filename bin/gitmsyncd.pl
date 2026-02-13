#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Gitmsyncd::App;

my $app = Gitmsyncd::App->new();
$app->start();
