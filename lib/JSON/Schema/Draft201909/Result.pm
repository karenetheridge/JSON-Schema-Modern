use strict;
use warnings;
package JSON::Schema::Draft201909::Result;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Holds the results of a JSON Schema evaluation

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use Types::Standard qw(Bool ArrayRef InstanceOf Enum);

has result => ( is => 'ro', isa => Bool );
has errors => ( is => 'ro', isa => ArrayRef[InstanceOf['JSON::Schema::Draft201909::Error']] );
#has annotations => ( is => 'ro', isa => ArrayRef[InstanceOf['JSON::Schema::Draft201909::Annotation']] );
has output_format => ( is -> 'ro', isa => Enum[qw(flag basic detailed verbose)];

# TODO overload:
# bool: ->result
# count: scalar ->result ? ->annotations : ->errors
# stringify: to_json(->TO_JSON)

sub TO_JSON ($self) {
  if ($self->output_format eq 'flag') {
    return +{ valid => $self->result ? true : false };
  }
  if ($self->output_format eq 'basic') {
    return +{
      valid => $self->result
        ? ( valid => true ) #, annotations => [ map $_->TO_JSON, $self->annotations->@* ] )
        : ( valid => false, errors => [ map $_->TO_JSON, $self->errors->@* ] ),
    };
  }

  # TODO: other output formats may require walking the schema again
  # to rebuild the structure. so we may want to hold a reference to the schema Document.

  die 'unsupported output format';
}

1;
__END__

=pod

=head1 SYNOPSIS

    use JSON::Schema::Draft2019::Errors;

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
