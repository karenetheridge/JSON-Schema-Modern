use strict;
use warnings;
package JSON::Schema::Modern::Result;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains the result of a JSON Schema evaluation

our $VERSION = '0.628';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use MooX::TypeTiny;
use Types::Standard qw(ArrayRef InstanceOf Enum Bool Str Maybe Tuple);
use Types::Common::Numeric 'PositiveInt';
use JSON::Schema::Modern::Annotation;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Utilities qw(true false);
use JSON::PP ();
use List::Util 1.45 'uniq';
use if "$]" < 5.041010, 'List::Util' => qw(any all);
use if "$]" >= 5.041010, experimental => qw(keyword_any keyword_all);
use Carp 'croak';
use builtin::compat qw(refaddr blessed);
use Safe::Isa;
use namespace::clean;

use overload
  'bool'  => sub {
    croak 'boolean overload is deprecated and could be removed anytime after 2026-02-01';
    $_[0]->valid;
  },
  '&'     => \&combine,
  '""' => sub { $_[0]->stringify },
  fallback => 1;

has valid => (
  is => 'ro',
  isa => Bool|InstanceOf('JSON::PP::true')|InstanceOf('JSON::PP::false'),
  coerce => sub { $_[0] ? true : false }, # might be JSON::PP::* or builtin::* booleans
  lazy => 1,
  default => sub ($self) { $self->error_count == 0 },
);
sub result { goto \&valid } # backcompat only

has exception => (
  is => 'ro',
  isa => Bool,
  lazy => 1,
  default => sub ($self) { any { $_->exception or $_->error =~ /^EXCEPTION: / } $self->errors },
);

# has errors
# has annotations
# turn hashrefs in _errors or _annotations into blessed objects
has $_.'s' => (
  is => 'bare',
  reader => '__'.$_.'s',
  isa => ArrayRef[InstanceOf['JSON::Schema::Modern::'.ucfirst]],
  lazy => 1,
  default => do {
    my $type = $_;
    sub ($self) {
      return [] if not (($self->{'_'.$type.'s'}//[])->@*);

      # E() and A() in ::Utilities returns an unblessed hashref, which is used to create a real object
      # by its BUILDARGS sub
      return [ map +(('JSON::Schema::Modern::'.ucfirst($type))->new($_)), $self->{'_'.$type.'s'}->@* ];
    };
  },
) foreach qw(error annotation);

sub errors { $_[0]->__errors->@* }
sub error_count { scalar(($_[0]->{errors}//[])->@*) || scalar(($_[0]->{_errors}//[])->@*) }
sub annotations { $_[0]->__annotations->@* }
sub annotation_count { scalar(($_[0]->{annotations}//[])->@*) || scalar(($_[0]->{_annotations}//[])->@*) }

has recommended_response => (
  is => 'rw',
  isa => Maybe[Tuple[PositiveInt, Str]],
  lazy => 1,
  default => sub ($self) {
    return if not $self->errors;

    for my $error ($self->errors) {
      my $pe = $error->recommended_response;
      return $pe if $pe;
    }

    return [ 500, 'Internal Server Error' ] if $self->exception;
    return [ 400, ($self->errors)[0]->stringify ];
  },
);

# strict_basic can only be used with draft2019-09.
use constant OUTPUT_FORMATS => [qw(flag basic strict_basic terse data_only)];

has output_format => (
  is => 'rw',
  isa => Enum(OUTPUT_FORMATS),
  default => 'basic',
);

has formatted_annotations => (
  is => 'ro',
  isa => Bool,
  default => 1,
);

around BUILDARGS => sub ($orig, $class, @args) {
  my $args = $class->$orig(@args);

  # set unblessed hashrefs aside, and defer creation of blessed objects until needed
  $args->{_errors} = delete $args->{errors} if
    exists $args->{errors} and any { !blessed($_) } $args->{errors}->@*;
  $args->{_annotations} = delete $args->{annotations} if
    exists $args->{annotations} and any { !blessed($_) } $args->{annotations}->@*;

  croak 'inconsistent inputs: errors is not empty but valid is true'
    if $args->{valid}
      and (exists $args->{_errors} and $args->{_errors}->@*
        or exists $args->{errors} and $args->{errors}->@*);

  croak 'inconsistent inputs: errors is empty but valid is false'
    if exists $args->{valid} and not $args->{valid}
      and (not exists $args->{_errors} or not $args->{_errors}->@*)
      and (not exists $args->{errors} or not $args->{errors}->@*);

  return $args;
};

sub BUILD ($self, $args) {
  $self->{_errors} = $args->{_errors} if exists $args->{_errors};
  $self->{_annotations} = $args->{_annotations} if exists $args->{_annotations};
}

sub format ($self, $style, $formatted_annotations = undef) {
  $formatted_annotations //= $self->formatted_annotations;

  if ($style eq 'flag') {
    return +{ valid => $self->valid ? true : false };
  }
  elsif ($style eq 'basic') {
    return +{
      valid => $self->valid ? true : false,
      $self->valid
        ? ($formatted_annotations && $self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, $self->errors ]),
    };
  }
  # note: strict_basic will NOT be supported after draft 2019-09!
  elsif ($style eq 'strict_basic') {
    return +{
      valid => ($self->valid ? true : false),
      $self->valid
        ? ($formatted_annotations && $self->annotation_count ? (annotations => [ map _map_uris($_->TO_JSON), $self->annotations ]) : ())
        : (errors => [ map _map_uris($_->TO_JSON), $self->errors ]),
    };
  }
  elsif ($style eq 'terse') {
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

      ++$instance_locations{$_->instance_location} if $keep;
      ++$keyword_locations{$_->keyword_location} if $keep;

      $keep;
    }
    $self->errors;

    die 'uh oh, have no errors left to report' if not $self->valid and not @errors;

    return +{
      valid => $self->valid ? true : false,
      $self->valid
        ? ($formatted_annotations && $self->annotation_count ? (annotations => [ map $_->TO_JSON, $self->annotations ]) : ())
        : (errors => [ map $_->TO_JSON, @errors ]),
    };
  }
  elsif ($style eq 'data_only') {
    return 'valid' if not $self->error_count;
    # Note: this output is going to be confusing when coming from a schema with a 'oneOf', 'not',
    # etc. Perhaps generating the strings with indentation levels, as derived from a nested format,
    # might be more readable.
    return join("\n", uniq(map $_->stringify, $self->errors));
  }

  # TODO: support detailed, verbose ?
  croak 'unsupported output format';
}

sub count { $_[0]->valid ? $_[0]->annotation_count : $_[0]->error_count }

sub combine ($self, $other, $swap) {
  croak 'wrong type for & operation' if not $other->$_isa(__PACKAGE__);

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
    formatted_annotations => $self->formatted_annotations || $other->formatted_annotations,
  );
}

sub stringify ($self) {
  return $self->format('data_only');
}

sub TO_JSON ($self) {
  croak 'cannot produce JSON output for data_only format' if $self->output_format eq 'data_only';
  $self->format($self->output_format);
}

sub dump ($self) {
  my $encoder = JSON::Schema::Modern::_JSON_BACKEND()->new
    ->utf8(0)
    ->convert_blessed(1)
    ->canonical(1)
    ->indent(1)
    ->space_after(1);
  $encoder->indent_length(2) if $encoder->can('indent_length');
  $encoder->encode($self);
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
  say sprintf('got %d %ss', $result, ($result->valid ? 'annotation' : 'error'));

  # use in string context
  say 'full results: ', $result;

  # combine two results into one:
  my $overall_result = $result1 & $result2;

=head1 DESCRIPTION

This object holds the complete results of evaluating a data payload against a JSON Schema using
L<JSON::Schema::Modern>.

=head1 OVERLOADS

The object contains a string overload, which evaluates to a potentially multi-line string
summarizing the errors within (if any); this is intended to be used as a user-oriented error message
that references data locations, but not schema locations.

=for stopwords iff

The object also contains a I<bitwise AND> overload (C<&>), for combining two results into one (the
result is valid iff both inputs are valid; annotations and errors from the second argument are
appended to those of the first in a new Result object).

=head1 CONSTRUCTOR ARGUMENTS

Unless otherwise noted, these are also available as read-only accessors.

=head2 valid

A boolean. Indicates whether validation was successful or failed.

Optional, as it can be calculated from the presence of C<errors> or C<annotations>.

=head2 errors

An array of L<JSON::Schema::Modern::Error> objects.

=head2 annotations

An array of L<JSON::Schema::Modern::Annotation> objects.

=head2 output_format

=for stopwords subschemas

Also available as a read/write accessor.

One of: C<flag>, C<basic>, C<strict_basic>, C<terse>, C<data_only>. Defaults to C<basic>.

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
* C<data_only> returns a string, not a data structure: it contains a list of errors identified only
  by their C<instance_location> and error message (or C<keyword_location>, when the error occurred
  while loading the schema itself). This format is suitable for generating errors when the schema is
  not published, or for describing errors with the schema itself. This is not an official
  specification format and may change slightly over time, as it is tested in production environments.

=head2 formatted_annotations

A boolean flag indicating whether L</format> should include annotations in the output. Defaults to true.

=head2 exception

Indicates that evaluation stopped due to a severe error.

=head2 recommended_response

=for stopwords OpenAPI

A tuple, consisting of C<[ integer, string ]>, indicating the recommended HTTP response code and
string to use for this result (if validating an HTTP request). This could exist for things like a
failed authentication check in OpenAPI validation, in which case it would contain
C<[ 401, 'Unauthorized' ]>.

Only populated when there are errors; when not explicitly set by an evaluator, defaults to
C<< [ 500, 'Internal Server Error' ] >> if any errors indicate an exception, and
C<< [ 400, <first error string> ] >> otherwise. The exact error string is hidden in the case of 500
errors because you should not leak internal issues with your application, but you may also wish to
obfuscate normal validation errors, in which case you should check for C<400> and change the string
to C<'Bad Request'>.

Also available as a read/write accessor.

=head1 METHODS

=for Pod::Coverage BUILD BUILDARGS OUTPUT_FORMATS result stringify annotation_count error_count
true false HAVE_BUILTIN

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

=head2 dump

Returns a JSON string representing the result object, using the requested L</format>, according to
the L<draft2019-09 specification|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>
and the L<draft2020-12 specification|https://json-schema.org/draft/2020-12/json-schema-core#section-12>.

=head1 SERIALIZATION

Results (and their contained errors and annotations) can be serialized in a number of ways.

Results have defined L</output_format>s, which can be generated as nested unblessed hashes/arrays
and are suitable for serializing using a JSON encoder for use in another application. A JSON string of
the result can be obtained directly using L</dump>.

If it is preferable to omit direct references to the schema (for example in an application where the
schema is not published), but still convey some semantic information about the nature of the errors,
stringify the object directly. This also means that result objects can be thrown as exceptions, or
embedded in error messages.

If you are embedding the full result inside another data structure, perhaps to be serialized to JSON
(or another format) later on, use L</TO_JSON> or L</format>.

=cut
