#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Syncd::App;

my $app = Syncd::App->new();
$app->start();
