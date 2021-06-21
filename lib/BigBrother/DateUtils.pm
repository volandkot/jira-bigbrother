package BigBrother::DateUtils;

use strict;
use warnings;

use AnyEvent::HTTP;
use Coro;
use Coro::AnyEvent;

use BigBrother::Config;

my $config = BigBrother::Config->instance();

my $last_reload_time;
my $calendar_xml;
sub reload {
    my ($class, $time) = @_;
    $time //= time;

    if(!$last_reload_time || $time - $last_reload_time > $config->holidays_update_period) {
        my (undef, undef, undef, $d, $m, $y, $wd) = localtime($time);
        $m++; $y += 1900 if $y < 1900;

        http_get "https://raw.Githubusercontent.com/xmlcalendar/data/master/ru/$y/calendar.xml", Coro::rouse_cb();
        my ($body, $headers) = Coro::rouse_wait();
        if($headers->{Status} eq '200') {
            $calendar_xml = $body;
            $last_reload_time = $time;
        }
    }
}

sub is_holiday {
    my ($class, $time) = @_;
    $time //= time;
    $class->reload($time);
    return 0 unless $calendar_xml;

    my (undef, undef, undef, $d, $m, $y, $wd) = localtime($time);
    $m++; $y += 1900 if $y < 1900;

    my ($type) = $calendar_xml =~ /<day d="0?$m.0?$d" t="(\d+)"/;
    unless(defined $type) {
        return 1 if $wd == 0 or $wd == 6;
    } else {
        return 1 if $type == 1;
    }
    return 0;
}

sub is_last_workday {
    my ($class, $time) = @_;
    $time //= time;

    my $next_day_time = $time + 86400;
    return !$class->is_holiday($time) && $class->is_holiday($next_day_time);
}

sub match_hhmm {
    my ($class, $time, $hhmm) = @_;
    $time //= time;

    my ($hh, $mm) = split /:/, $hhmm;
    my ($secs, $min, $hour) = localtime($time);
    return $hh == $hour && $mm == $min;
}

sub previous_workday_delta {
    my ($class, $time) = @_;
    $time //= time;

    my $delta = 1;
    while($class->is_holiday($time - 86400 * $delta)) {
        $delta++;
    }
    return $delta;
}

sub previous_workday_before_holiday_delta {
    my ($class, $time) = @_;
    $time //= time;

    my $delta = 1;
    if(!$class->is_holiday($time)) {
        while(!$class->is_holiday($time - 86400 * $delta)) {
            $delta++;
        }
    }
    while($class->is_holiday($time - 86400 * $delta)) {
        $delta++;
    }
    return $delta;
}

1;
