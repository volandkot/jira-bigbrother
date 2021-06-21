package BigBrother::Sender;

use strict;
use warnings;
use utf8;

use AnyEvent::HTTP;
use Coro;
use JSON::XS;
use Data::Dumper;

use BigBrother::Config;
use BigBrother::Const;
use BigBrother::Jira;
use BigBrother::MessageBuilder;

my $config = BigBrother::Config->instance();

sub SEND_URL() { 'https://slack.com/api/chat.postMessage' }

sub send_reports {
    my ($class, $reports) = @_;
    $class->send_self_daily_reports($reports);
    $class->send_boss_daily_reports($reports);
    $class->send_broadcast_weekly_reports($reports);
}

sub send_boss_daily_reports {
    my ($class, $reports) = @_;
    $reports = $reports->{BigBrother::Const::REPORT_TYPE_BOSS_DAILY()};
    return unless $reports;


    for my $report_to (keys %{$config->boss_reports}) {
        my $user_info = BigBrother::Jira->get_jira_user_info($report_to);
        next if $user_info && $user_info->vacations;

        warn "Send boss daily reports to '$report_to'\n";
        for my $user (@{$config->boss_reports->{$report_to}}) {
            my $user_info = BigBrother::Jira->get_jira_user_info($user);
            warn "Send boss daily report by '$user' to '$report_to'\n";
            my $messages = BigBrother::MessageBuilder->make_boss_daily_report_messages_by_user($user_info, $reports->{$user});
            $class->_send($config->jira_slack_users->{$report_to}, $_) for @$messages;
        }
    }
}

sub send_self_daily_reports {
    my ($class, $reports) = @_;
    $reports = $reports->{BigBrother::Const::REPORT_TYPE_SELF_DAILY()};
    return unless $reports;

    for my $report_to (@{$config->self_reports}) {
        warn "Send self daily report to '$report_to'\n";
        my $user_info = BigBrother::Jira->get_jira_user_info($report_to);
        next if $user_info && $user_info->vacations;
        my $messages = BigBrother::MessageBuilder->make_self_daily_report_messages($user_info, $reports->{$report_to});
        $class->_send($config->jira_slack_users->{$report_to}, $_) for @$messages;
    }
}

sub send_broadcast_weekly_reports {
    my ($class, $reports) = @_;
    $reports = $reports->{BigBrother::Const::REPORT_TYPE_BROADCAST_WEEKLY()};
    return unless $reports;

    for my $report_to (@{$config->broadcast_weekly_reports}) {
        warn "Send broadcast weekly report to '$report_to'\n";
        my $messages = BigBrother::MessageBuilder->make_broadcast_weekly_report_title();
        $class->_send($report_to, $_) for @$messages;

        for my $user (sort keys %$reports) {
            my $user_info = BigBrother::Jira->get_jira_user_info($user);
            warn "Send broadcast weekly report by '$user' to '$report_to'\n";
            my $messages = BigBrother::MessageBuilder->make_broadcast_weekly_report_messages($user_info, $reports->{$user});
            $class->_send($report_to, $_) for @$messages;
        }
    }
}

sub _send {
    my ($class, $report_to, $message) = @_;

    my $headers = {
        'Content-Type' => 'application/x-www-form-urlencoded',
    };

    my $json = encode_json($message);
    my $token = $config->slack->{token};
    http_post SEND_URL(), "token=$token&as_user=true&channel=$report_to&blocks=$json", headers => $headers, Coro::rouse_cb();
    my ($body, $resp_headers) = Coro::rouse_wait();
    if($resp_headers->{Status} !~ /^2/) {
        warn Dumper($resp_headers);
        warn $body;
    }
}


1;
