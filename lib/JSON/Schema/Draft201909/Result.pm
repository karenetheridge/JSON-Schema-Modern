use strict;
use warnings;
package JSON::Schema::Draft201909::Result;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Holds the results of a JSON Schema evaluation

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use MooX::TypeTiny;
use Types::Standard qw(Bool ArrayRef InstanceOf Enum);
use JSON::MaybeXS 'JSON';

has result => ( is => 'ro', isa => Bool );
has errors => ( is => 'ro', isa => ArrayRef[InstanceOf['JSON::Schema::Draft201909::Error']] );
#has annotations => ( is => 'ro', isa => ArrayRef[InstanceOf['JSON::Schema::Draft201909::Annotation']] );
has output_format => ( is => 'ro', isa => Enum[qw(flag basic detailed verbose)];
has instance_data => ( is => 'ro' );

use overload
  'bool'  => 'result',
  '0+'    => 'count',
  '""'    => 'to_string',
  fallback => 1;

sub count { 0+ ($_[0]->result ? $_[0]->annotations->@* : $_[0]->errors->@*) }
sub to_string { JSON()->new(canonical => 1, allow_nonref => 1)->encode($_[0]->TO_JSON) },

sub format ($self, $style) {
  if ($style eq 'flag') {
    return +{ valid => $self->result ? true : false };
  }
  if ($style eq 'basic') {
    return +{
      valid => $self->result
        ? ( valid => true ) #, annotations => [ map $_->TO_JSON, $self->annotations->@* ] )
        : ( valid => false, errors => [ map $_->TO_JSON, $self->errors->@* ] ),
    };
  }

  # TODO: other output formats may require walking the schema again
  # to rebuild the structure. so we may want to hold a reference to the schema Document.

  # need logic for combining annotations from subschemas.
  # https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.7.7.1.3

  die 'unsupported output format';

}

sub TO_JSON ($self) {
  $self->format($self->output_format);
}

1;
__END__

=pod

=head1 SYNOPSIS

    use JSON::Schema::Draft201909::Errors;

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
