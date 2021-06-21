package BigBrother::Jira::User;

use utf8;
use Mouse;

has name => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has _display_name => (
    init_arg => 'display_name',
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has active => (
    is => 'ro',
    isa => 'Bool',
    default => 1,
);

has deleted => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
);

has email => (
    is => 'ro',
    isa => 'Maybe[Str]',
);

has vacations => (
    is => 'ro',
    isa => 'Bool',
    lazy => 1,
    default => sub { shift->_display_name =~ /\(В отпуске\)/ },
);

no Mouse;
__PACKAGE__->meta->make_immutable();
