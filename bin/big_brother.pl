#!/usr/bin/env perl

use utf8;
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use Coro;
use Coro::AnyEvent;
use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::Jira::Pool;
use AnyEvent::Jira::Issue;
use AnyEvent::Jira::User;
use Data::Dumper;
use HTTP::Date;
use Time::Local;
use YAML;
use POSIX qw/strftime/;
use JSON::XS;

my $config = YAML::LoadFile("$FindBin::Bin/../config.yaml");
my $slack_jira_users = $config->{slack_jira_users};
my $jira_slack_users = { reverse %$slack_jira_users };
my $jira_users_info_cache = {};

my $boss_report_headers = {
    vacations => "Сотрудник в отпуске",
    empty_report => "Ничего не происходит",
    deployed_and_done => "Разложенные и закрытые таски",
    deployed_but_not_done => "Таски разложенны, но не закрыты",
    will_be_deployed_but_done => "Таски закрыты, но будут раскладываться",
    will_be_deployed => "Поедет в бой в ближайшей раскладке",
    done_but_not_deployed => "Таски закрыты без раскадки",
    deployed_but_not_done_long_time => "Таски разложены, но не закрыты длительное время",
    will_be_deployed_long_time => "Таски не попадающие в раскладку длительное время",
    develop_no_reports => "Таски в работе, но без отчета!",
    develop_with_reports => "Отчеты по таскам в работе",
    nothing_in_develop => "Нет ни одного таска в работе!",
};

my $self_report_headers = {
    empty_report => "Все хорошо! Ты молодец!",
    deployed_but_not_done => "Таски разложенны, но не закрыты",
    will_be_deployed_but_done => "Таски закрыты, но будут раскладываться.\nВозможно их стоит перевести в Deploy?",
    will_be_deployed => "Поедет в бой в ближайшей раскладке",
    deployed_but_not_done_long_time => "Таски разложены, но не закрыты длительное время.\nЕсли ты чего то ждешь по задаче, то переведи ее в Awaiting.\nЕсли продолжаешь работать, то в Develope.",
    will_be_deployed_long_time => "Таски не попадающие в раскладку длительное время.\nМожет пора замержится в master?",
    develop_no_reports => "Таски в работе, но без отчета!\nНе забывай оставлять в конце рабочего дня в таске комментарий с кратким описанием, что было сделано по таску.\nКомметарий должен начинаться с префикса RPT.",
    nothing_in_develop => "Нет ни одного таска в работе!\nНе забывай переводить таски в Develop!",
};

my $task_process_handlers = {
    New => \&process_develop_task,
    DevReady => \&process_develop_task,
    Awaiting => \&process_develop_task,
    Develop => \&process_develop_task,
    Deploy => \&process_deploy_task,
    Done => \&process_done_task,
};

my $now = time;
if(is_holiday($now)) {
    warn "Today is holiday!\n";
    exit;
}
my $previous_work_day_delta = previous_work_day_delta($now);

my $jira_auth = { token_secret => $config->{jira}{token_secret}, token => $config->{jira}{token} };
AnyEvent::Jira::Pool->instance()->init_connection({
    rsa_private_key => $config->{jira}{rsa_private_key},
    rsa_public_key  => $config->{jira}{rsa_public_key},
    user_agent      => "Jira bot test script (adVentures)",
    auth_callback   => "https://jirabot.my.cloud.devmail.ru",
    url             => "https://jira.mail.ru",
    consumer_key    => $config->{jira}{consumer_key},
});

my %users = ();
for my $report_to (keys %{$config->{boss_reports}}) {
    for my $user (@{$config->{boss_reports}{$report_to}}) {
        $users{$user} = 1;
    }
}
for my $user (@{$config->{self_reports}}) {
    $users{$user} = 1;
}
my $users = [ keys %users ];

my $reports = make_reports_by_users($users);
for my $report_to (keys %{$config->{boss_reports}}) {
    my $user_info = get_jira_user_info($report_to);
    next if $user_info && $user_info->{vacations};

    warn "Send boss reports to '$report_to'\n";
    for my $user (@{$config->{boss_reports}{$report_to}}) {
        my $user_info = get_jira_user_info($user);
        warn "Send boss report by '$user' to '$report_to'\n";
        send_boss_report_by_user($jira_slack_users->{$report_to}, $user, $reports->{$user}, vacations => $user_info ? $user_info->{vacations} : 0);
    }
}
for my $report_to (@{$config->{self_reports}}) {
    warn "Send self report to '$report_to'\n";
    my $user_info = get_jira_user_info($report_to);
    next if $user_info && $user_info->{vacations};
    send_self_report($jira_slack_users->{$report_to}, $reports->{$report_to});
}

exit;

# ===========================

sub make_reports_by_users {
    my ($users) = @_;

    my $reports;
    for my $user (@$users) {
        warn "Make report by '$user'\n";
        my $tasks = get_tasks_by_user($user);

        my %report;
        for my $type (qw/New DevReady Awaiting Develop Deploy Done/) {
            my $tasks = $tasks->{$type} // [];
            for my $task (@$tasks) {
                warn "Process task $type '$task'\n";
                my $task_info = get_task_info($task);
                my $report_data = $task_process_handlers->{$type}->($task_info);
                push @{$report{$report_data->{report_key}}}, {
                    task => $task,
                    summary => $task_info->{fields}{summary},
                    deploy => $report_data->{deploy_link},
                    comments => $report_data->{comments},
                } if $report_data->{report_key};
            }
            if($type eq 'Develop') {
                unless(@$tasks) {
                    $report{nothing_in_develop} = {};
                }
            }
        }
        $reports->{$user} = \%report;
    }
    return $reports;
}

sub get_tasks_by_user {
    my ($user) = @_;
    AnyEvent::Jira::Issue->search({ %$jira_auth, query => {
        jql => qq/project = MOOSIC and assignee = "$user" and ((status in (New, DevReady, Awaiting) and updated > startOfDay(-$previous_work_day_delta)) or (status = Develop) or (status = Deploy) or (status = Done and updated > startOfDay(-$previous_work_day_delta))) ORDER BY updatedDate DESC/,
        maxResults => 100,
    } }, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});

    my %tasks = ();
    for my $issue (@{$resp->{result}{issues}}) {
        my $key    = $issue->{key};
        my $status = $issue->{fields}{status}{name};
        push @{$tasks{$status}}, $key;
    }
    warn Dumper(\%tasks);
    return \%tasks;
}

sub send_boss_report_by_user {
    my ($report_to, $user, $report, %opts) = @_;

    my $send_msg_url = 'https://slack.com/api/chat.postMessage';
    my $headers = {
        'Content-Type' => 'application/x-www-form-urlencoded',
    };

    my $messages = make_boss_report_messages_by_user($user, $report, %opts);
    for my $message (@$messages) {
        my $json = encode_json($message);
        http_post $send_msg_url, "token=$config->{slack}{token}&as_user=true&channel=$report_to&blocks=$json", headers => $headers, Coro::rouse_cb();
        my ($body, $resp_headers) = Coro::rouse_wait();
        warn $body;
    }
}

sub send_self_report {
    my ($report_to, $report) = @_;

    my $send_msg_url = 'https://slack.com/api/chat.postMessage';
    my $headers = {
        'Content-Type' => 'application/x-www-form-urlencoded',
    };

    my $messages = make_self_report_messages($report);
    for my $message (@$messages) {
        my $json = encode_json($message);
        http_post $send_msg_url, "token=$config->{slack}{token}&as_user=true&channel=$report_to&blocks=$json", headers => $headers, Coro::rouse_cb();
        my ($body, $resp_headers) = Coro::rouse_wait();
        warn $body;
    }
}

sub extract_deploy_link {
    my ($task) = @_;
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
    my ($task) = @_;
    my $report_key;
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    my $comments = $task->{fields}{comment}{comments} // [];
    my $assignee = $task->{fields}{assignee}{name};
    my @reports = ();
    for my $c (@$comments) {
        next unless $c->{author}{name} eq $assignee;
        my $comment_created = HTTP::Date::str2time($c->{created});
        next unless $comment_created > time - $previous_work_day_delta * 24 * 3600;
        warn $c->{body};
        my ($report) = $c->{body} =~ /^\s*RPT\s*+(.+)$/s;
        push @reports, $report if $report;
    }
    unless(@reports) {
        $report_key = 'develop_no_reports' if $task->{fields}{status}{name} eq 'Develop';
    } else {
        $report_key = 'develop_with_reports';
    }
    return { report_key => $report_key, comments => \@reports };
}

sub process_deploy_task {
    my ($task) = @_;
    my $report_key;
    my $deploy_link = extract_deploy_link($task);
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    if($deploy_link) {
        my $deploy_date = $deploy_link->{date};
        if($deploy_date < time) {
            if($updated < time - (5 * 24 * 3600 + $previous_work_day_delta * 24 * 3600)) {
                $report_key = 'deployed_but_not_done_long_time';
            } else {
                $report_key = 'deployed_but_not_done';
            }
        } else {
            $report_key = 'will_be_deployed';
        }
    } else {
        if($updated < time - (5 * 24 * 3600 + $previous_work_day_delta * 24 * 3600)) {
            $report_key = 'will_be_deployed_long_time';
        } else {
            $report_key = 'will_be_deployed';
        }
    }
    return { report_key => $report_key, deploy_link => $deploy_link };
}

sub process_done_task {
    my ($task) = @_;
    return {} if $task->{fields}{summary} =~ /^Подготовка к раскладке/;

    my $report_key;
    my $deploy_link = extract_deploy_link($task);
    my $updated = HTTP::Date::str2time($task->{fields}{updated});
    my $created = HTTP::Date::str2time($task->{fields}{created});
    if($deploy_link) {
        my $deploy_date = $deploy_link->{date};
        if($deploy_date < time) {
            $report_key = 'deployed_and_done' if $deploy_date > time - $previous_work_day_delta * 24 * 3600;
        } else {
            $report_key = 'will_be_deployed_but_done';
        }
    } else {
        $report_key = 'done_but_not_deployed' if $updated > time - $previous_work_day_delta * 24 * 3600;
    }
    return { report_key => $report_key, deploy_link => $deploy_link };
}

sub get_task_info {
    my ($task) = @_;
    AnyEvent::Jira::Issue->get($task, $jira_auth, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});
    return $resp->{result};
}

sub get_task_links {
    my ($task) = @_;
    AnyEvent::Jira::Issue->link_list($task, $jira_auth, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});
    return $resp->{result};
}

sub make_boss_report_messages_by_user {
    my ($user, $report, %opts) = @_;
    my $slack_user = '<@'.$jira_slack_users->{$user}.'>';
    my @result = ();
    my $date = strftime("%F", localtime(time));
    my @msgs = ( { type => 'section', text => { type => 'mrkdwn', text => "*Отчет по $slack_user ($date)*".($opts{vacations} ? " [В отпуске]" : "") } }, { type => 'divider' } );
    my $max_block_text_len = 2000;
    my $max_blocks_count = 40;
    unless($opts{vacations}) {
        my $empty = 1;
        if($report->{nothing_in_develop}) {
            my $msg = "```".$boss_report_headers->{nothing_in_develop}."```";
            push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
            $empty = 0;
        }
TYPES:
        for my $rt (qw/deployed_and_done deployed_but_not_done will_be_deployed_but_done will_be_deployed done_but_not_deployed deployed_but_not_done_long_time will_be_deployed_long_time develop_no_reports develop_with_reports/) {
            next unless $report->{$rt} && @{$report->{$rt}};
            $empty = 0;
            my $msg = "```".$boss_report_headers->{$rt}."\n\n";
            for my $task (@{$report->{$rt}}) {
                my $new_msg = '';
                $new_msg .= "<https://jira.mail.ru/browse/$task->{task}|$task->{task}>: $task->{summary} ";
                $new_msg .= "[<https://jira.mail.ru/browse/$task->{deploy}{task}|$task->{deploy}{task}>] ".strftime("%F", localtime($task->{deploy}{date})) if $task->{deploy};
                $new_msg .= "\n";
                if($task->{comments} && @{$task->{comments}}) {
                    $new_msg .= join "\n", @{$task->{comments}}, "\n";
                }
                if(length($msg) + length($new_msg) > $max_block_text_len) {
                    $msg .= "```";
                    push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
                    if(@msgs >= $max_blocks_count) {
                        push @result, \@msgs;
                        @msgs = ();
                        next TYPES;
                    }
                    $msg = "```";
                }
                $msg .= $new_msg;
            }
            $msg .= "```";
            push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
            if(@msgs >= $max_blocks_count) {
                push @result, \@msgs;
                @msgs = ();
                next TYPES;
            }
        }
        if($empty) {
            my $msg = "```".$boss_report_headers->{empty_report}."```";
            push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        }
    }
    push @msgs, { type => 'divider' };
    push @result, \@msgs;
    return \@result;
}

sub make_self_report_messages {
    my ($report) = @_;
    my @result = ();
    my $date = strftime("%F", localtime(time));
    my @msgs = ( { type => 'section', text => { type => 'mrkdwn', text => "*Отчет за $date*" } }, { type => 'divider' } );
    my $max_block_text_len = 2000;
    my $max_blocks_count = 40;
    my $empty = 1;
    if($report->{nothing_in_develop}) {
        my $msg = "```".$self_report_headers->{nothing_in_develop}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        $empty = 0;
    }
TYPES:
    for my $rt (qw/deployed_but_not_done will_be_deployed_but_done will_be_deployed deployed_but_not_done_long_time will_be_deployed_long_time develop_no_reports/) {
        next unless $report->{$rt} && @{$report->{$rt}};
        $empty = 0;
        my $msg = "```".$self_report_headers->{$rt}."\n\n";
        for my $task (@{$report->{$rt}}) {
            my $new_msg = '';
            $new_msg .= "<https://jira.mail.ru/browse/$task->{task}|$task->{task}>: $task->{summary} ";
            $new_msg .= "[<https://jira.mail.ru/browse/$task->{deploy}{task}|$task->{deploy}{task}>] ".strftime("%F", localtime($task->{deploy}{date})) if $task->{deploy};
            $new_msg .= "\n";
            if($task->{comments} && @{$task->{comments}}) {
                $new_msg .= join "\n", @{$task->{comments}}, "\n";
            }
            if(length($msg) + length($new_msg) > $max_block_text_len) {
                $msg .= "```";
                push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
                if(@msgs >= $max_blocks_count) {
                    push @result, \@msgs;
                    @msgs = ();
                    next TYPES;
                }
                $msg = "```";
            }
            $msg .= $new_msg;
        }
        $msg .= "```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        if(@msgs >= $max_blocks_count) {
            push @result, \@msgs;
            @msgs = ();
            next TYPES;
        }
    }
    if($empty) {
        my $msg = "```".$self_report_headers->{empty_report}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
    }
    push @msgs, { type => 'divider' };
    push @result, \@msgs;
    return \@result;
}

sub get_jira_user_info {
    my ($user) = @_;
    return $jira_users_info_cache->{$user} if $jira_users_info_cache->{$user};

    AnyEvent::Jira::User->search({ %$jira_auth, username => $user, project => 'MOOSIC' }, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});

    return undef unless $resp && $resp->{result};
    for my $r (@{$resp->{result}}) {
        if($r->{name} eq $user) {
            my $vacations = ($r->{displayName} =~ /\(В отпуске\)/) ? 1 : 0;
            my $info = {
                name => $r->{name},
                active => $r->{active},
                deleted => $r->{deleted},
                email => $r->{emailAddress},
                vacations => $vacations,
            };
            $jira_users_info_cache->{$user} = $info;
            return $info;
        }
    }
    return undef;
}

my $calendar_xml;
sub is_holiday {
    my ($time) = @_;
    $time //= time;

    my (undef, undef, undef, $d, $m, $y, $wd) = localtime($time);
    $m++; $y += 1900 if $y < 1900;

    unless($calendar_xml) {
        http_get "https://raw.Githubusercontent.com/xmlcalendar/data/master/ru/$y/calendar.xml", Coro::rouse_cb();
        my ($body, $headers) = Coro::rouse_wait();
        if($headers->{Status} eq '200') {
            $calendar_xml = $body;
        } else {
            return undef;
        }
    }
    my ($type) = $calendar_xml =~ /<day d="0?$m.0?$d" t="(\d+)"/;
    unless(defined $type) {
        return 1 if $wd == 0 or $wd == 6;
    } else {
        return 1 if $type == 1;
    }
    return 0;
}

sub previous_work_day_delta {
    my ($time) = @_;
    $time //= time;

    my $delta = 1;
    while(is_holiday($time - 86400 * $delta)) {
        $delta++;
    }
    return $delta;
}


__END__
AnyEvent::Jira::Issue->get('MOOSIC-3172', $auth, Coro::rouse_cb());
my $resp = Coro::rouse_wait;
warn Dumper($resp->{result}{fields}{comment}{comments});

my $cv = AnyEvent->condvar;
http_post "https://slack.com/api/rtm.connect", "token=$token", headers => $headers, sub {
    my ($body, $headers) = @_;
    warn $body;
    $cv->send;
};
$cv->recv;
