use strict;
use warnings;
package JSON::Schema::Draft201909::Result;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains the result of a JSON Schema evaluation

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Moo;
use strictures 2;
use MooX::TypeTiny;
use Types::Standard qw(ArrayRef InstanceOf Enum);
use MooX::HandlesVia;
use JSON::Schema::Draft201909::Annotation;
use JSON::Schema::Draft201909::Error;
use JSON::PP ();
use List::Util 1.50 'head';
use namespace::clean;

use overload
  'bool'  => sub { $_[0]->result },
  '0+'    => sub { $_[0]->count },
  fallback => 1;

has result => (
  is => 'ro',
  isa => InstanceOf['JSON::PP::Boolean'],
  coerce => sub { $_[0] ? JSON::PP::true : JSON::PP::false },
);

has $_.'s' => (
  is => 'bare',
  isa => ArrayRef[InstanceOf['JSON::Schema::Draft201909::'.ucfirst]],
  lazy => 1,
  default => sub { [] },
  handles_via => 'Array',
  handles => {
    $_.'s' => 'elements',
    $_.'_count' => 'count',
  },
) foreach qw(error annotation);

use constant OUTPUT_FORMATS => [qw(flag basic detailed verbose terse)];

has output_format => (
  is => 'rw',
  isa => Enum(OUTPUT_FORMATS),
  default => 'basic',
);

sub BUILD {
  my $self = shift;
  warn 'result is false but there are no errors' if not $self->result and not $self->error_count;
}

sub format {
  my ($self, $style) = @_;
  if ($style eq 'flag') {
    return +{ valid => $self->result };
  }
  if ($style eq 'basic') {
    return +{
      valid => $self->result,
      $self->result
        ? ($self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, $self->errors ]),
    };
  }
  if ($style eq 'terse') {
    # we can also drop errors for unevaluatedItems, unevaluatedProperties
    # when there is another (non-discarded) error at the same instance location or parent keyword
    # location (indicating that "unevaluated" is actually "unsuccessfully evaluated").
    my (%instance_locations, %keyword_locations);

    my @errors = grep {
      my ($keyword, $error) = ($_->keyword, $_->error);

      my $keep = 0+!!(
        not $keyword
          or (
            not grep $keyword eq $_, qw(allOf anyOf if then else dependentSchemas contains propertyNames)
            and ($keyword ne 'oneOf' or $error ne 'no subschemas are valid')
            and ($keyword ne 'items'    # list form of items (prefixItems)
              or $error eq 'item not permitted' and $_->keyword_location =~ m{/[0-9]+$})
            and ($keyword ne 'additionalItems' or $error eq 'additional item not permitted')
            and (not grep $keyword eq $_, qw(properties patternProperties)
              or $error eq 'property not permitted')
            and ($keyword ne 'additionalProperties' or $error eq 'additional property not permitted'))
        );

        if ($keep and $keyword and $keyword =~ /^unevaluated(?:Items|Properties)$/
            and $error !~ /"$keyword" keyword present, but/) {
          my $parent_keyword_location = join('/', head(-1, split('/', $_->keyword_location)));
          my $parent_instance_location = join('/', head(-1, split('/', $_->instance_location)));

          $keep = (
            (($keyword eq 'unevaluatedProperties' and $error eq 'additional property not permitted')
              or ($keyword eq 'unevaluatedItems' and $error eq 'additional item not permitted'))
            and not $instance_locations{$_->instance_location}
            and not grep m/^$parent_keyword_location/, keys %keyword_locations
          );
        }

      ++$instance_locations{$_->instance_location} if $keep;
      ++$keyword_locations{$_->keyword_location} if $keep;

      $keep;
    }
    $self->errors;

    die 'uh oh, have no errors left to report' if not $self->result and not @errors;

    return +{
      valid => $self->result,
      $self->result
        ? ($self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, @errors ]),
    };
  }

  die 'unsupported output format';
}

sub count { $_[0]->result ? $_[0]->annotation_count : $_[0]->error_count }

sub TO_JSON {
  my $self = shift;
  $self->format($self->output_format);
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Draft201909;
  my $js = JSON::Schema::Draft201909->new;
  my $result = $js->evaluate($data, $schema);
  my @errors = $result->errors;

  my $result_data_encoded = encode_json($result); # calls TO_JSON

  # use in numeric and boolean context
  say sprintf('got %d %ss', $result, ($result ? 'annotation' : 'error'));

  # use in string context
  say 'full results: ', $result;

=head1 DESCRIPTION

This object holds the complete results of evaluating a data payload against a JSON Schema using
L<JSON::Schema::Draft201909>.

=head1 OVERLOADS

The object contains a boolean overload, which evaluates to the value of L</result>, so you can
use the result of L<JSON::Schema::Draft201909/evaluate> in boolean context.

=head1 ATTRIBUTES

=head2 result

A boolean. Indicates whether validation was successful or failed.

=head2 errors

Returns an array of L<JSON::Schema::Draft201909::Error> objects.

=head2 annotations

Returns an array of L<JSON::Schema::Draft201909::Annotation> objects.

=head2 output_format

One of: C<flag>, C<basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>.

=head1 METHODS

=for Pod::Coverage BUILD OUTPUT_FORMATS

=head2 format

Returns a data structure suitable for serialization; requires one argument specifying the output
format to use, which corresponds to the formats documented in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4>. The only supported
formats at this time are C<flag>, C<basic> and C<terse>.

=head2 TO_JSON

Calls L</format> with the style configured in L</output_format>.

=head2 count

Returns the number of annotations when the result is true, or the number of errors when the result
is false.

=cut
