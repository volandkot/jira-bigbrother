#!/usr/bin/env perl

use utf8;
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

my $CONFIG_FILE;
BEGIN {
    $CONFIG_FILE = $ARGV[0] || "$FindBin::Bin/../config.yaml";
    $SIG{__WARN__} = sub { warn sprintf("[ %5d %s ] %s", $$, "".localtime(), join "", @_) };
};

use BigBrother::Config $CONFIG_FILE;
use BigBrother;

BigBrother->run();

