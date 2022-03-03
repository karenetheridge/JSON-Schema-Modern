use strict;
use warnings;
package JSON::Schema::Modern::Result;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains the result of a JSON Schema evaluation

our $VERSION = '0.548';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use MooX::TypeTiny;
use Types::Standard qw(ArrayRef InstanceOf Enum);
use MooX::HandlesVia;
use JSON::Schema::Modern::Annotation;
use JSON::Schema::Modern::Error;
use JSON::PP ();
use List::Util 1.50 qw(head any);
use Scalar::Util 'refaddr';
use Safe::Isa;
use namespace::clean;

use overload
  'bool'  => sub { $_[0]->valid },
  '&'     => \&combine,
  '0+'    => sub { Scalar::Util::refaddr($_[0]) },
  '""' => sub { $_[0]->stringify },
  fallback => 1;

has valid => (
  is => 'ro',
  isa => InstanceOf['JSON::PP::Boolean'],
  coerce => sub { $_[0] ? JSON::PP::true : JSON::PP::false },
);
sub result { shift->valid } # backcompat only

has exception => (
  is => 'ro',
  isa => InstanceOf['JSON::PP::Boolean'],
  coerce => sub { $_[0] ? JSON::PP::true : JSON::PP::false },
  lazy => 1,
  default => sub { any { $_->exception } $_[0]->errors },
);

has mode => (
  is => 'ro',
  isa => Enum[qw(traverse evaluate)],
  default => 'evaluate',
);

has $_.'s' => (
  is => 'bare',
  isa => ArrayRef[InstanceOf['JSON::Schema::Modern::'.ucfirst]],
  lazy => 1,
  default => sub { [] },
  handles_via => 'Array',
  handles => {
    $_.'s' => 'elements',
    $_.'_count' => 'count',
  },
) foreach qw(error annotation);

# strict_basic can only be used with draft2019-09.
use constant OUTPUT_FORMATS => [qw(flag basic strict_basic detailed verbose terse)];

has output_format => (
  is => 'rw',
  isa => Enum(OUTPUT_FORMATS),
  default => 'basic',
);

sub BUILD ($self, $) {
  warn 'result is false but there are no errors' if not $self->valid and not $self->error_count;
}

sub format ($self, $style) {
  if ($style eq 'flag') {
    return +{ valid => $self->valid };
  }
  elsif ($style eq 'basic') {
    return +{
      valid => $self->valid,
      $self->valid
        ? ($self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, $self->errors ]),
    };
  }
  # note: strict_basic will NOT be supported after draft 2019-09!
  elsif ($style eq 'strict_basic') {
    return +{
      valid => $self->valid,
      $self->valid
        ? ($self->annotation_count ? (annotations => [ map _map_uris($_->TO_JSON), $self->annotations ]) : ())
        : (errors => [ map _map_uris($_->TO_JSON), $self->errors ]),
    };
  }
  elsif ($style eq 'terse') {
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
            and ($keyword ne 'prefixItems' or $error eq 'item not permitted')
            and ($keyword ne 'items' or $error eq 'item not permitted' or $error eq 'additional item not permitted')
            and ($keyword ne 'additionalItems' or $error eq 'additional item not permitted')
            and (not grep $keyword eq $_, qw(properties patternProperties)
              or $error eq 'property not permitted')
            and ($keyword ne 'additionalProperties' or $error eq 'additional property not permitted'))
            and ($keyword ne 'dependentRequired' or $error ne 'not all dependencies are satisfied')
        );

      if ($keep and $keyword and $keyword =~ /^unevaluated(?:Items|Properties)$/) {
        if ($error !~ /"$keyword" keyword present, but/) {
          my $parent_keyword_location = join('/', head(-1, split('/', $_->keyword_location)));
          my $parent_instance_location = join('/', head(-1, split('/', $_->instance_location)));

          $keep = (
            (($keyword eq 'unevaluatedProperties' and $error eq 'additional property not permitted')
              or ($keyword eq 'unevaluatedItems' and $error eq 'additional item not permitted'))
            and not $instance_locations{$_->instance_location}
            and not grep m/^$parent_keyword_location/, keys %keyword_locations
          );
        }
      }

      ++$instance_locations{$_->instance_location} if $keep;
      ++$keyword_locations{$_->keyword_location} if $keep;

      $keep;
    }
    $self->errors;

    die 'uh oh, have no errors left to report' if not $self->valid and not @errors;

    return +{
      valid => $self->valid,
      $self->valid
        ? ($self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, @errors ]),
    };
  }

  die 'unsupported output format';
}

sub count { $_[0]->valid ? $_[0]->annotation_count : $_[0]->error_count }

sub combine ($self, $other, $swap) {
  die 'wrong type for & operation' if not $other->$_isa(__PACKAGE__);

  return $self if refaddr($other) == refaddr($self);

  return ref($self)->new(
    valid => $self->valid && $other->valid,
    annotations => [
      $self->annotations,
      $other->annotations,
    ],
    errors => [
      $self->errors,
      $other->errors,
    ],
    output_format => $self->output_format,
  );
}

sub stringify ($self) {
  $self->error_count
    ? ($self->mode eq 'traverse'
        ? join("\n", map +('at \''.$_->keyword_location.'\': '.$_->error), $self->errors)
        : join("\n", map +('at \''.$_->instance_location.'\': '.$_->error), $self->errors)
    ) : 'valid'
}

sub TO_JSON ($self) {
  $self->format($self->output_format);
}

# turns the JSON pointers in instance_location, keyword_location  into a URI fragments,
# for strict draft-201909 adherence
sub _map_uris ($data) {
  return +{
    %$data,
    map +($_ => Mojo::URL->new->fragment($data->{$_})->to_string),
      qw(instanceLocation keywordLocation),
  };
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern;
  my $js = JSON::Schema::Modern->new;
  my $result = $js->evaluate($data, $schema);
  my @errors = $result->errors;

  my $result_data_encoded = encode_json($result); # calls TO_JSON

  # use in numeric and boolean context
  say sprintf('got %d %ss', $result, ($result ? 'annotation' : 'error'));

  # use in string context
  say 'full results: ', $result;

  # combine two results into one:
  my $overall_result = $result1 & $result2;

=head1 DESCRIPTION

This object holds the complete results of evaluating a data payload against a JSON Schema using
L<JSON::Schema::Modern>.

=head1 OVERLOADS

The object contains a I<boolean> overload, which evaluates to the value of L</valid>, so you can
use the result of L<JSON::Schema::Modern/evaluate> in boolean context.

=for stopwords iff

The object also contains a I<bitwise AND> overload (C<&>), for combining two results into one (the
result is valid iff both inputs are valid; annotations and errors from the second argument are
appended to those of the first).

=head1 ATTRIBUTES

=head2 valid

A boolean. Indicates whether validation was successful or failed.

=head2 mode

Indicates whether the result was produced during the C<traverse> or C<evaluate> phase of execution.

=head2 errors

Returns an array of L<JSON::Schema::Modern::Error> objects.

=head2 annotations

Returns an array of L<JSON::Schema::Modern::Annotation> objects.

=head2 output_format

=for stopwords subschemas

One of: C<flag>, C<basic>, C<strict_basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>.

=for :list
* C<flag> returns just the result of the evaluation: either C<{"valid": true}> or C<{"valid": false}>.
* C<basic> adds the list of C<errors> or C<annotations> to the boolean evaluation result.
C<instance_location> and C<keyword_location> are always included, as JSON pointers, describing the
path to the evaluation location; C<absolute_keyword_location> is added (as a resolved URI) whenever
it is known and different from C<keyword_location>.
* C<strict_basic> is like C<basic> but follows the draft-2019-09 specification precisely, including
replicating an error fixed in the next draft, in that C<instance_location> and C<keyword_location>
values are provided as fragment-only URI references rather than JSON pointers.
* C<terse> is not described in any specification; it is like C<basic>, but omits some redundant
errors (for example the one for the C<allOf> keyword that is added when any of the subschemas under
C<allOf> failed evaluation).

=head1 METHODS

=for Pod::Coverage BUILD OUTPUT_FORMATS result stringify

=head2 format

Returns a data structure suitable for serialization; requires one argument specifying the output
format to use, which corresponds to the formats documented in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4>. The only supported
formats at this time are C<flag>, C<basic>, C<strict_basic>, and C<terse>.

=head2 TO_JSON

Calls L</format> with the style configured in L</output_format>.

=head2 count

Returns the number of annotations when the result is true, or the number of errors when the result
is false.

=head2 combine

When provided with another result object, returns a new object with the combination of all results.
See C<&> at L</OVERLOADS>.

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
