package BigBrother::Jira;

use strict;
use warnings;
use utf8;

use Coro;
use Coro::AnyEvent;
use AnyEvent::Jira::Pool;
use AnyEvent::Jira::Issue;
use AnyEvent::Jira::User;

use BigBrother::Config;
use BigBrother::Jira::User;

my $config = BigBrother::Config->instance();

my $jira_users_info_cache = {};

sub jira_auth { +{ token_secret => $config->jira->{token_secret}, token => $config->jira->{token} } }

sub init_jira_connect {
    AnyEvent::Jira::Pool->instance()->init_connection({
        rsa_private_key => $config->jira->{rsa_private_key},
        rsa_public_key  => $config->jira->{rsa_public_key},
        user_agent      => "Jira bot test script (adVentures)",
        auth_callback   => "https://jirabot.my.cloud.devmail.ru",
        url             => "https://jira.mail.ru",
        consumer_key    => $config->jira->{consumer_key},
    });
}

sub get_tasks_by_user {
    my ($class, $jira_user, $days_periods_by_status) = @_;

    my @filters;
    for my $row (@$days_periods_by_status) {
        my $statuses      = $row->{statuses};
        my $days_period   = $row->{days_period};
        push @filters, sprintf("status in (%s)".(defined $days_period ? " and updated > startOfDay(%d)" : ""), join(", ", @$statuses), (defined $days_period ? 0 - $days_period : ()));
    }
    my $filter = @filters ? "and (".join(" or ", map { "($_)"} @filters ).")" : "";
    my $query = qq/project = MOOSIC and assignee = "$jira_user" $filter ORDER BY updatedDate DESC/;
    AnyEvent::Jira::Issue->search({ %{$class->jira_auth}, query => { jql => $query, maxResults => 100 } }, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->jira->{request_sleep});

    my %tasks = ();
    for my $issue (@{$resp->{result}{issues}}) {
        my $key    = $issue->{key};
        my $status = $issue->{fields}{status}{name};
        push @{$tasks{$status}}, $key;
    }
    return \%tasks;
}

sub get_task_info {
    my ($class, $task) = @_;
    AnyEvent::Jira::Issue->get($task, $class->jira_auth, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});
    return $resp->{result};
}

sub get_task_links {
    my ($class, $task) = @_;
    AnyEvent::Jira::Issue->link_list($task, $class->jira_auth, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});
    return $resp->{result};
}

sub get_jira_user_info {
    my ($class, $jira_user) = @_;
    return $jira_users_info_cache->{$jira_user} if $jira_users_info_cache->{$jira_user};

    AnyEvent::Jira::User->search({ %{$class->jira_auth}, username => $jira_user, project => 'MOOSIC' }, Coro::rouse_cb());
    my $resp = Coro::rouse_wait;
    Coro::AnyEvent::sleep($config->{jira}{request_sleep});

    return undef unless $resp && $resp->{result};
    for my $r (@{$resp->{result}}) {
        if($r->{name} eq $jira_user) {
            $jira_users_info_cache->{$jira_user} = BigBrother::Jira::User->new(
                name => $r->{name},
                display_name => $r->{displayName},
                active => $r->{active},
                deleted => $r->{deleted},
                email => $r->{emailAddress},
            );
            return $jira_users_info_cache->{$jira_user};
        }
    }
    return undef;
}

1;
