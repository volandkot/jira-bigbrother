package BigBrother::Config;

use Mouse;
use YAML;

my $config_filename;
sub import {
    my ($class, $filename) = @_;
    die "Config filename already set as '$config_filename'" if $config_filename && $filename;
    $config_filename = $filename if $filename;
}

my $config;
sub instance { $config // shift->new(@_) }

has _config => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
    trigger => \&_init,
);

has schedule => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
);

has slack => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
);

has jira => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
);

has boss_reports => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
);

has self_reports => (
    init_arg => undef,
    is => 'rw',
    isa => 'ArrayRef',
);

has broadcast_weekly_reports => (
    init_arg => undef,
    is => 'rw',
    isa => 'ArrayRef',
);

has slack_jira_users => (
    init_arg => undef,
    is => 'rw',
    isa => 'HashRef',
);

has _jira_slack_users => (
    init_arg => undef,
    is => 'ro',
    isa => 'HashRef',
    reader => 'jira_slack_users',
    lazy => 1,
    default => sub { +{ reverse %{shift->slack_jira_users} } },
);

has holidays_update_period => (
    init_arg => undef,
    is => 'rw',
    isa => 'Int',
    default => sub { 60 * 60 },
);

sub BUILD {
    my ($self) = @_;
    $self->reload();
    $config = $self;
}

sub _init {
    my ($self) = @_;
    my $config = $self->_config;
    for my $attr ($self->meta->get_attribute_list) {
        next if $attr =~ /^_/;
        $self->$attr($config->{$attr});
    }
}

sub reload {
    my ($self) = @_;
    my $config = YAML::LoadFile($config_filename);
    $self->_config($config);
    warn "Config reloaded\n";
    return $config;
}

no Mouse;
__PACKAGE__->meta->make_immutable();
