package BigBrother::MessageBuilder;

use strict;
use warnings;
use utf8;

use POSIX qw/strftime/;

use BigBrother::Config;
use BigBrother::Const;

my $config = BigBrother::Config->instance();

sub MAX_BLOCK_TEXT_LEN() { 2000 }
sub MAX_BLOCKS_COUNT()   { 40 }
sub BLOCK_DIVIDER()      { +{ type => 'divider' } }

my $boss_daily_report_headers = {
    REPORT_KEY_VACATIONS() => "Сотрудник в отпуске",
    REPORT_KEY_EMPTY() => "Ничего не происходит",
    REPORT_KEY_DEPLOYED_AND_DONE() => "Разложенные и закрытые таски",
    REPORT_KEY_DEPLOYED_BUT_NOT_DONE() => "Таски разложенны, но не закрыты",
    REPORT_KEY_WILL_BE_DEPLOYED_BUT_DONE() => "Таски закрыты, но будут раскладываться",
    REPORT_KEY_WILL_BE_DEPLOYED() => "Поедет в бой в ближайшей раскладке",
    REPORT_KEY_DONE_BUT_NOT_DEPLOYED() => "Таски закрыты без раскадки",
    REPORT_KEY_DEPLOYED_BUT_NOT_DONE_LONG_TIME() => "Таски разложены, но не закрыты длительное время",
    REPORT_KEY_WILL_BE_DEPLOYED_LONG_TIME() => "Таски не попадающие в раскладку длительное время",
    REPORT_KEY_NOTHING_IN_DEVELOP() => "Нет ни одного таска в работе!",
    REPORT_KEY_DEVELOP() => "Задачи в работе",
    REPORT_KEY_DEVELOPED_LONG_TIME() => "Задачи в работе без изменений длительное время",
};

my $self_daily_report_headers = {
    REPORT_KEY_EMPTY() => "Идеальная Jira! Ты молодец!",
    REPORT_KEY_DEPLOYED_BUT_NOT_DONE() => "Таски разложенны, но не закрыты",
    REPORT_KEY_WILL_BE_DEPLOYED_BUT_DONE() => "Таски закрыты, но будут раскладываться.\nВозможно их стоит перевести в Deploy?",
    REPORT_KEY_WILL_BE_DEPLOYED() => "Поедет в бой в ближайшей раскладке",
    REPORT_KEY_DEPLOYED_BUT_NOT_DONE_LONG_TIME() => "Таски разложены, но не закрыты длительное время.\nЕсли ты чего то ждешь по задаче, то переведи ее в Awaiting.\nЕсли продолжаешь работать, то в Develope.",
    REPORT_KEY_WILL_BE_DEPLOYED_LONG_TIME() => "Таски не попадающие в раскладку длительное время.\nМожет пора замержится в master?",
    REPORT_KEY_NOTHING_IN_DEVELOP() => "Нет ни одного таска в работе!\nНе забывай переводить таски в Develop!\n",
    REPORT_KEY_DEVELOPED_LONG_TIME() => "Задачи в работе без изменений длительное время.\nЕсли по задачам не ведется работа, то переведи их из Develop. Если же работы ведутся, то не забывай периодически оставлять комментарии.",
};

my $broadcast_weekly_report_headers = {
    REPORT_KEY_EMPTY() => "Ничего не происходило =(",
    REPORT_KEY_WITH_REPORTS() => "Задачи с отчетами",
    REPORT_KEY_WILL_BE_DEPLOYED() => "Поедут в бой на следующей неделе",
    REPORT_KEY_DONE() => "Завершенные задачи",
    REPORT_KEY_VACATIONS() => "Чилит в отпуске",
};


sub make_boss_daily_report_messages_by_user {
    my ($class, $user_info, $report) = @_;

    my $slack_user = '<@'.$config->jira_slack_users->{$user_info->name}.'>';
    my $vacations = $user_info->vacations;
    my @result = ();
    my $date = strftime("%F", localtime(time));
    my @msgs = ( { type => 'section', text => { type => 'mrkdwn', text => "*Отчет по $slack_user ($date)*".($vacations ? " [В отпуске]" : "") } }, BLOCK_DIVIDER() );
    unless($vacations) {
        my $empty = 1;
        if($report->{REPORT_KEY_NOTHING_IN_DEVELOP()}) {
            my $msg = "```".$boss_daily_report_headers->{REPORT_KEY_NOTHING_IN_DEVELOP()}."```";
            push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
            $empty = 0;
        }
TYPES:
        for my $rt (BigBrother::Const::REPORT_KEYS()) {
            next unless $report->{$rt} && @{$report->{$rt}};
            next unless $boss_daily_report_headers->{$rt};
            $empty = 0;
            my $msg = "```".$boss_daily_report_headers->{$rt}."\n\n";
            for my $task (@{$report->{$rt}}) {
                my $new_msg = '';
                $new_msg .= "<https://jira.mail.ru/browse/$task->{task}|$task->{task}>: $task->{summary} ";
                $new_msg .= "[<https://jira.mail.ru/browse/$task->{deploy}{task}|$task->{deploy}{task}>] ".strftime("%F", localtime($task->{deploy}{date})) if $task->{deploy};
                $new_msg .= "\n";
                if($task->{comments} && @{$task->{comments}}) {
                    $new_msg .= join "\n", @{$task->{comments}}, "\n";
                }
                if(length($msg) + length($new_msg) > MAX_BLOCK_TEXT_LEN()) {
                    $msg .= "```";
                    push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
                    if(@msgs >= MAX_BLOCKS_COUNT()) {
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
            if(@msgs >= MAX_BLOCKS_COUNT()) {
                push @result, \@msgs;
                @msgs = ();
                next TYPES;
            }
        }
        if($empty) {
            my $msg = "```".$boss_daily_report_headers->{REPORT_KEY_EMPTY()}."```";
            push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        }
    }
    push @msgs, BLOCK_DIVIDER();
    push @result, \@msgs;
    return \@result;
}

sub make_self_daily_report_messages {
    my ($class, $user_info, $report) = @_;
    my @result = ();
    my $date = strftime("%F", localtime(time));
    my @msgs = ( { type => 'section', text => { type => 'mrkdwn', text => "*Отчет за $date*" } }, BLOCK_DIVIDER());
    my $empty = 1;
    if($report->{REPORT_KEY_NOTHING_IN_DEVELOP()}) {
        my $msg = "```".$self_daily_report_headers->{REPORT_KEY_NOTHING_IN_DEVELOP()}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        $empty = 0;
    }
TYPES:
    for my $rt (BigBrother::Const::REPORT_KEYS()) {
        next unless $report->{$rt} && @{$report->{$rt}};
        next unless $self_daily_report_headers->{$rt};
        $empty = 0;
        my $msg = "```".$self_daily_report_headers->{$rt}."\n\n";
        for my $task (@{$report->{$rt}}) {
            my $new_msg = '';
            $new_msg .= "<https://jira.mail.ru/browse/$task->{task}|$task->{task}>: $task->{summary} ";
            $new_msg .= "[<https://jira.mail.ru/browse/$task->{deploy}{task}|$task->{deploy}{task}>] ".strftime("%F", localtime($task->{deploy}{date})) if $task->{deploy};
            $new_msg .= "\n";
            if($task->{comments} && @{$task->{comments}}) {
                $new_msg .= join "\n", @{$task->{comments}}, "\n";
            }
            if(length($msg) + length($new_msg) > MAX_BLOCK_TEXT_LEN()) {
                $msg .= "```";
                push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
                if(@msgs >= MAX_BLOCKS_COUNT()) {
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
        if(@msgs >= MAX_BLOCKS_COUNT()) {
            push @result, \@msgs;
            @msgs = ();
            next TYPES;
        }
    }
    if($empty) {
        my $msg = "```".$self_daily_report_headers->{REPORT_KEY_EMPTY()}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
    }
    push @msgs, BLOCK_DIVIDER();
    push @result, \@msgs;
    return \@result;
}

sub make_broadcast_weekly_report_title {
    my ($class) = @_;
    my $date = strftime("%F", localtime(time));
    my @msgs = ( { type => 'section', text => { type => 'mrkdwn', text => "*Что мы сделали за прошлую неделю (до $date)*" } }, BLOCK_DIVIDER());
    return [ \@msgs ];
}

sub make_broadcast_weekly_report_messages {
    my ($class, $user_info, $report) = @_;
    my @result = ();
    my $slack_user = '<@'.$config->jira_slack_users->{$user_info->name}.'>';
    my $vacations = $user_info->vacations;
    my $empty = 1;

    my @msgs = ({ type => 'section', text => { type => 'mrkdwn', text => $slack_user } }, BLOCK_DIVIDER());
    if($vacations) {
        my $msg = "```".$broadcast_weekly_report_headers->{REPORT_KEY_VACATIONS()}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
        $empty = 0;
    }
TYPES:
    for my $rt (BigBrother::Const::REPORT_KEYS()) {
        next unless $report->{$rt} && @{$report->{$rt}};
        next unless $broadcast_weekly_report_headers->{$rt};
        $empty = 0;
        my $msg = "```".$broadcast_weekly_report_headers->{$rt}."\n\n";
        for my $task (@{$report->{$rt}}) {
            my $new_msg = "";
            $new_msg .= "<https://jira.mail.ru/browse/$task->{task}|$task->{task}>: $task->{summary} ";
            $new_msg .= "[<https://jira.mail.ru/browse/$task->{deploy}{task}|$task->{deploy}{task}>] ".strftime("%F", localtime($task->{deploy}{date})) if $task->{deploy};
            $new_msg .= "\n";
            if($task->{comments} && @{$task->{comments}}) {
                $new_msg .= join "\n", @{$task->{comments}}, "\n";
            }
            if(length($msg) + length($new_msg) > MAX_BLOCK_TEXT_LEN()) {
                $msg .= "```";
                push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
                if(@msgs >= MAX_BLOCKS_COUNT()) {
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
        if(@msgs >= MAX_BLOCKS_COUNT()) {
            push @result, \@msgs;
            @msgs = ();
            next TYPES;
        }
    }
    if($empty) {
        my $msg = "```".$broadcast_weekly_report_headers->{REPORT_KEY_EMPTY()}."```";
        push @msgs, { type => 'section', text => { type => 'mrkdwn', text => $msg } };
    }
    push @msgs, BLOCK_DIVIDER();
    push @result, \@msgs;
    return \@result;
}

1;
