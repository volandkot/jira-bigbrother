package BigBrother;

use utf8;
use Mouse;
use EV;
use Coro;
use Coro::AnyEvent;
use HTTP::Date;
use Time::Local;
use Data::Dumper;
use BigBrother::Config;
use BigBrother::Const;
use BigBrother::DateUtils;
use BigBrother::Jira;
use BigBrother::Sender;

my $config = BigBrother::Config->instance();

sub ITER_SLEEP() { 60 }

my @JIRA_STATUSES = qw/New DevReady Awaiting Develop Deploy Done/;

my $daily_task_process_handlers = {
    Develop => \&process_develop_task,
    Deploy => \&process_deploy_task,
    Done => \&process_done_task,
};

sub run {
    my ($class) = @_;

    BigBrother::Jira->init_jira_connect();
    while(1) {
        my $time = time;
        if(BigBrother::DateUtils->is_holiday($time)) {
            warn "Today is holiday\n";
            next;
        }

        my $report_types = $class->get_report_types($time);
        unless(@$report_types) {
            warn "No report types scheduled\n";
            next;
        }

        my $users = $class->get_uniq_users();
        my $reports = $class->make_reports_by_users($users, $time, $report_types);
        BigBrother::Sender->send_reports($reports);
        warn "Done reports: ".(join ", ", @$report_types)."\n";
    } continue {
        Coro::AnyEvent::sleep(ITER_SLEEP());
        $config->reload();
    }
    EV::loop();
}

sub get_report_types {
    my ($class, $time) = @_;

    my @types;
    if($config->schedule->{self_daily_report_time}) {
        if(BigBrother::DateUtils->match_hhmm($time, $config->schedule->{self_daily_report_time})) {
            push @types, REPORT_TYPE_SELF_DAILY();
        }
    }
    if($config->schedule->{boss_daily_report_time}) {
        if(BigBrother::DateUtils->match_hhmm($time, $config->schedule->{boss_daily_report_time})) {
            push @types, REPORT_TYPE_BOSS_DAILY();
        }
    }
    if($config->schedule->{broadcast_weekly_report_time}) {
        if(BigBrother::DateUtils->match_hhmm($time, $config->schedule->{broadcast_weekly_report_time}) && BigBrother::DateUtils->is_last_workday($time)) {
            push @types, REPORT_TYPE_BROADCAST_WEEKLY();
        }
    }
    return \@types;
}

sub get_uniq_users {
    my ($class) = @_;
    my %users = ();
    for my $report_to (keys %{$config->boss_reports}) {
        for my $user (@{$config->boss_reports->{$report_to}}) {
            $users{$user} = 1;
        }
    }
    for my $user (@{$config->self_reports}) {
        $users{$user} = 1;
    }
    return [ sort keys %users ];
}

sub make_reports_by_users {
    my ($class, $users, $time, $report_types) = @_;

    my $reports;
    for my $report_type (@$report_types) {
        for my $user (@$users) {
            my $report;
            if($report_type eq REPORT_TYPE_SELF_DAILY() || $report_type eq REPORT_TYPE_BOSS_DAILY()) {
                $report = $class->make_daily_report_by_user($user, $time);
            } elsif($report_type eq REPORT_TYPE_BROADCAST_WEEKLY()) {
                $report = $class->make_broadcast_weekly_report_by_user($user, $time);
            }
            $reports->{$report_type}{$user} = $report;
        }
    }
    return $reports;
}

sub make_daily_report_by_user {
    my ($class, $user, $time) = @_;

    warn "Make daily report by '$user'\n";
    my $tasks = BigBrother::Jira->get_tasks_by_user($user, [
        { statuses => [qw/New Awaiting DevReady Done/], days_period => BigBrother::DateUtils->previous_workday_delta($time) },
        { statuses => [qw/Develop Deploy/] },
    ]);

    my %report;
    for my $type (@JIRA_STATUSES) {
        my $handler = $daily_task_process_handlers->{$type} or next;
        my $tasks = $tasks->{$type} // [];
        for my $task (@$tasks) {
            warn "Process task $type '$task'\n";
            my $task_info = BigBrother::Jira->get_task_info($task);
            my $report_data = $handler->($class, $task_info, $time);
            push @{$report{$report_data->{report_key}}}, {
                task => $task,
                summary => $task_info->{fields}{summary},
                deploy => $report_data->{deploy_link},
                comments => $report_data->{comments},
            } if $report_data->{report_key};
        }
        if($type eq 'Develop') {
            unless(@$tasks) {
                $report{REPORT_KEY_NOTHING_IN_DEVELOP()} = [];
            }
        }
    }
    return \%report;
}

sub make_broadcast_weekly_report_by_user {
    my ($class, $user, $time) = @_;

    warn "Make weekly report by '$user'\n";
    my $tasks = BigBrother::Jira->get_tasks_by_user($user, [
        { statuses => [qw/New Awaiting DevReady Develop TestReady TestDone Testing Deploy Done/], days_period => BigBrother::DateUtils->previous_workday_before_holiday_delta($time) + 7 },
    ]);

    my %report;
    for my $type (keys %$tasks) {
        my $tasks = $tasks->{$type} // [];
        for my $task (@$tasks) {
            warn "Process task $type '$task'\n";
            my $task_info = BigBrother::Jira->get_task_info($task);

            my $updated = HTTP::Date::str2time($task_info->{fields}{updated});
            my $created = HTTP::Date::str2time($task_info->{fields}{created});
            my $comments = $task_info->{fields}{comment}{comments} // [];
            my $assignee = $task_info->{fields}{assignee}{name};

            my @reports = ();
            for my $c (@$comments) {
                next unless $c->{author}{name} eq $assignee;
                my $comment_created = HTTP::Date::str2time($c->{created});
                next unless $comment_created > time - BigBrother::DateUtils->previous_workday_before_holiday_delta($time) * 24 * 3600;
                my ($report) = $c->{body} =~ /^\s*RPT\s*+(.+)$/s;
                push @reports, $report if $report;
            }
            push @{$report{REPORT_KEY_WITH_REPORTS()}}, {
                task => $task,
                status => $type,
                summary => $task_info->{fields}{summary},
                comments => \@reports,
            } if @reports;

            if($type eq 'Deploy') {
                push @{$report{REPORT_KEY_WILL_BE_DEPLOYED()}}, {
                    task => $task,
                    summary => $task_info->{fields}{summary},
                };
            }
            if($type eq 'Done') {
                if($task_info->{fields}{summary} !~ /Подготовка к раскладке/) {
                    push @{$report{REPORT_KEY_DONE()}}, {
                        task => $task,
                        summary => $task_info->{fields}{summary},
                    };
                }
            }
        }
    }
    return \%report;
}

sub extract_deploy_link {
    my ($class, $task) = @_;
    my $links = $task->{fields}{issuelinks} // [];
    my $deploy_link;
    for my $link (@$links) {
        my $linked_to = $link->{outwardIssue} // $link->{inwardIssue};
        my $link_key = $linked_to->{key};
        my $link_summary = $linked_to->{fields}{summary};
        my $link_type = $linked_to->{fields}{issuetype}{name};
        if($link_key =~ /^MNT-\d+$/ && $link_type eq 'Раскладка') {
            my ($deploy_date_str) = $link_summary =~ / (\d+\.\d+\.\d+)$/;
            if($deploy_date_str) {
                my ($d, $m, $y) = split /\./, $deploy_date_str;
                my $deploy_date = timelocal(0, 0, 0, $d, $m - 1, $y);
                $deploy_link = { task => $link_key, date => $deploy_date } if !$deploy_link || $deploy_link->{date} < $deploy_date;
            }
        }
    }
    return $deploy_link;
}

sub process_develop_task {
    my ($class, $task, $time) = @_;
    my $report_key;
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    if($updated < time - (LONG_PERIOD() + BigBrother::DateUtils->previous_workday_delta(time - LONG_PERIOD()) * 24 * 3600)) {
        $report_key = REPORT_KEY_DEVELOPED_LONG_TIME();
    } else {
        $report_key = REPORT_KEY_DEVELOP();
    }
    return { report_key => $report_key };
}

sub process_deploy_task {
    my ($class, $task, $time) = @_;
    my $report_key;
    my $deploy_link = $class->extract_deploy_link($task);
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    if($deploy_link) {
        my $deploy_date = $deploy_link->{date};
        if($deploy_date < time) {
            if($updated < time - (LONG_PERIOD() + BigBrother::DateUtils->previous_workday_delta(time - LONG_PERIOD()) * 24 * 3600)) {
                $report_key = REPORT_KEY_DEPLOYED_BUT_NOT_DONE_LONG_TIME();
            } else {
                $report_key = REPORT_KEY_DEPLOYED_BUT_NOT_DONE();
            }
        } else {
            $report_key = REPORT_KEY_WILL_BE_DEPLOYED();
        }
    } else {
        if($updated < time - (LONG_PERIOD() + BigBrother::DateUtils->previous_workday_delta(time - LONG_PERIOD()) * 24 * 3600)) {
            $report_key = REPORT_KEY_WILL_BE_DEPLOYED_LONG_TIME();
        } else {
            $report_key = REPORT_KEY_WILL_BE_DEPLOYED();
        }
    }
    return { report_key => $report_key, deploy_link => $deploy_link };
}

sub process_done_task {
    my ($class, $task, $time) = @_;
    return {} if $task->{fields}{summary} =~ /^Подготовка к раскладке/;

    my $report_key;
    my $deploy_link = $class->extract_deploy_link($task);
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    if($deploy_link) {
        my $deploy_date = $deploy_link->{date};
        if($deploy_date < time) {
            $report_key = REPORT_KEY_DEPLOYED_AND_DONE() if $deploy_date > time - BigBrother::DateUtils->previous_workday_delta($time) * 24 * 3600;
        } else {
            $report_key = REPORT_KEY_WILL_BE_DEPLOYED_BUT_DONE();
        }
    } else {
        $report_key = REPORT_KEY_DONE_BUT_NOT_DEPLOYED() if $updated > time - BigBrother::DateUtils->previous_workday_delta($time) * 24 * 3600;
    }
    return { report_key => $report_key, deploy_link => $deploy_link };
}

no Mouse;
__PACKAGE__->meta->make_immutable();
