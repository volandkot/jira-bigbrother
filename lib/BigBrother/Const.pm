package BigBrother::Const;

use strict;
use warnings;
use utf8;

use Exporter qw/import/;

use constant LONG_PERIOD => 5 * 24 * 36000;

my @REPORT_TYPES = qw/
    self_daily
    boss_daily
    broadcast_weekly
/;
sub REPORT_TYPES() { @REPORT_TYPES };

my @REPORT_KEYS = qw/
    vacations
    empty
    deployed_and_done
    deployed_but_not_done
    will_be_deployed_but_done
    will_be_deployed
    done_but_not_deployed
    deployed_but_not_done_long_time
    will_be_deployed_long_time
    nothing_in_develop
    develop
    developed_long_time
    with_reports
    done
/;
sub REPORT_KEYS() { @REPORT_KEYS }

our @EXPORT = qw/LONG_PERIOD/;
make_consts('REPORT_TYPE', REPORT_TYPES());
make_consts('REPORT_KEY', REPORT_KEYS());

sub make_consts {
    my ($prefix, @values) = @_;

    for my $value (@values) {
        my $const_name = $prefix.'_'.uc($value);
        no strict 'refs';
        *{__PACKAGE__.'::'.$const_name} = sub () { $value };
        push @EXPORT, $const_name;
    }
}


1;
