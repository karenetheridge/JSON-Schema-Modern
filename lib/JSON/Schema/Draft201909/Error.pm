use strict;
use warnings;
package JSON::Schema::Draft201909::Error;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Holds a single JSON Schema error

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use MooX::TypeTiny;
use Types::Standard 'Str';

# these are json pointers
has [ qw(keyword_location keyword_absolute_location instance_location) ] => ( is => 'ro', isa => Str );
has error => ( is => 'ro', isa => Str );  # needs to handle stringables - e.g. Mojo::Exception

# need a hashref of error types => strings

sub TO_JSON ($self) {
  return +{
    instanceLocation => $self->instance_location,
    keywordLocation => $self->keyword_location,
    $self->$self->absolute_keyword_location eq $self->keyword_location ? ()
      : absoluteKeywordLocation => $self->absolute_keyword_location,
    error => $self->error,  # TODO: allow localization
  };
}

1;
__END__

=pod

=head1 SYNOPSIS

    use JSON::Schema::Draft201909::Error;

    ...

=head1 DESCRIPTION

...

=head1 METHODS

=head2 foo

...

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Draft201909>

=cut
