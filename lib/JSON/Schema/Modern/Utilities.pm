use strict;
use warnings;
package JSON::Schema::Modern::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Internal utilities for JSON::Schema::Modern

our $VERSION = '0.541';

use 5.020;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use B;
use Carp 'croak';
use JSON::MaybeXS 1.004001 'is_bool';
use Ref::Util 0.100 qw(is_ref is_plain_arrayref is_plain_hashref);
use Scalar::Util 'blessed';
use Storable 'dclone';
use Feature::Compat::Try;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Annotation;
use namespace::clean;

use Exporter 'import';

our @EXPORT_OK = qw(
  is_type
  get_type
  is_equal
  is_elements_unique
  jsonp
  unjsonp
  local_annotations
  canonical_uri
  E
  A
  abort
  assert_keyword_exists
  assert_keyword_type
  assert_pattern
  assert_uri_reference
  assert_uri
  annotate_self
  sprintf_num
  true
  false
);

use JSON::PP ();
use constant { true => JSON::PP::true, false => JSON::PP::false };

sub is_type ($type, $value) {
  if ($type eq 'null') {
    return !(defined $value);
  }
  if ($type eq 'boolean') {
    return is_bool($value);
  }
  if ($type eq 'object') {
    return is_plain_hashref($value);
  }
  if ($type eq 'array') {
    return is_plain_arrayref($value);
  }

  if ($type eq 'string' or $type eq 'number' or $type eq 'integer') {
    return 0 if not defined $value;
    my $flags = B::svref_2object(\$value)->FLAGS;

    if ($type eq 'string') {
      return !is_ref($value) && $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'number') {
      return ref($value) =~ /^Math::Big(?:Int|Float)$/
        || !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'integer') {
      return ref($value) =~ /^Math::Big(?:Int|Float)$/ && $value->is_int
        || !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK)) && int($value) == $value;
    }
  }

  if ($type =~ /^reference to (.+)$/) {
    return !blessed($value) && ref($value) eq $1;
  }

  return ref($value) eq $type;
}

sub get_type ($value) {
  return 'null' if not defined $value;
  return 'object' if is_plain_hashref($value);
  return 'array' if is_plain_arrayref($value);
  return 'boolean' if is_bool($value);

  return ref($value) =~ /^Math::Big(?:Int|Float)$/ ? ($value->is_int ? 'integer' : 'number')
      : (blessed($value) ? '' : 'reference to ').ref($value)
    if is_ref($value);

  my $flags = B::svref_2object(\$value)->FLAGS;
  return 'string' if $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
  return int($value) == $value ? 'integer' : 'number'
    if !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));

  croak sprintf('ambiguous type for %s',
    JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 0, allow_bignum => 1, convert_blessed => 1)->encode($value));
}

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.2.2
# if provided with a state hashref with a 'path' key, any differences are recorded within
sub is_equal ($x, $y, $state = undef) {
  $state->{path} //= '';

  my @types = map get_type($_), $x, $y;

  if ($state->{scalarref_booleans}) {
    ($x, $types[0]) = (0+!!$$x, 'boolean') if $types[0] eq 'reference to SCALAR';
    ($y, $types[1]) = (0+!!$$y, 'boolean') if $types[1] eq 'reference to SCALAR';
  }

  return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  return $x eq $y if $types[0] eq 'string';
  return $x == $y if grep $types[0] eq $_, qw(boolean number integer);

  my $path = $state->{path};
  if ($types[0] eq 'object') {
    return 0 if keys %$x != keys %$y;
    return 0 if not is_equal([ sort keys %$x ], [ sort keys %$y ]);
    foreach my $property (sort keys %$x) {
      $state->{path} = jsonp($path, $property);
      return 0 if not is_equal($x->{$property}, $y->{$property}, $state);
    }
    return 1;
  }

  if ($types[0] eq 'array') {
    return 0 if @$x != @$y;
    foreach my $idx (0 .. $x->$#*) {
      $state->{path} = $path.'/'.$idx;
      return 0 if not is_equal($x->[$idx], $y->[$idx], $state);
    }
    return 1;
  }

  return 0; # should never get here
}

# checks array elements for uniqueness. short-circuits on first pair of matching elements
# if second arrayref is provided, it is populated with the indices of identical items
sub is_elements_unique ($array, $equal_indices = undef) {
  foreach my $idx0 (0 .. $array->$#*-1) {
    foreach my $idx1 ($idx0+1 .. $array->$#*) {
      if (is_equal($array->[$idx0], $array->[$idx1], { scalarref_booleans => 1 })) {
        push @$equal_indices, $idx0, $idx1 if defined $equal_indices;
        return 0;
      }
    }
  }
  return 1;
}

# shorthand for creating and appending json pointers
sub jsonp {
  return join('/', shift, map s/~/~0/gr =~ s!/!~1!gr, map +(is_plain_arrayref($_) ? @$_ : $_), grep defined, @_);
}

# splits a json pointer apart into its path segments
sub unjsonp ($path) {
  return map s!~0!~!gr =~ s!~1!/!gr, split m!/!, $path;
}

# get all annotations produced for the current instance data location (that are visible to this
# schema location)
sub local_annotations ($state) {
  grep $_->instance_location eq $state->{data_path}, $state->{annotations}->@*;
}

# shorthand for finding the canonical uri of the present schema location
sub canonical_uri ($state, @extra_path) {
  splice(@extra_path, -1, 1, $extra_path[-1]->@*) if @extra_path and is_plain_arrayref($extra_path[-1]);
  my $uri = $state->{initial_schema_uri}->clone;
  $uri->fragment(($uri->fragment//'').jsonp($state->{schema_path}, @extra_path));
  $uri->fragment(undef) if not length($uri->fragment);
  $uri;
}

# shorthand for creating error objects
# uses these keys from $state:
# - initial_schema_uri
# - keyword
# - data_path
# - traversed_schema_path
# - schema_path
# - _schema_path_suffix
# - errors
sub E ($state, $error_string, @args) {
  croak 'E called in void context' if not defined wantarray;

  # sometimes the keyword shouldn't be at the very end of the schema path
  my $uri = canonical_uri($state, $state->{keyword}, $state->{_schema_path_suffix});

  my $keyword_location = $state->{traversed_schema_path}
    .jsonp($state->{schema_path}, $state->{keyword}, delete $state->{_schema_path_suffix});

  undef $uri if $uri eq '' and $keyword_location eq ''
    or ($uri->fragment // '') eq $keyword_location and $uri->clone->fragment(undef) eq '';

  push $state->{errors}->@*, JSON::Schema::Modern::Error->new(
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    defined $uri ? ( absolute_keyword_location => $uri ) : (),
    error => @args ? sprintf($error_string, @args) : $error_string,
    $state->{exception} ? ( exception => $state->{exception} ) : (),
  );

  return 0;
}

# shorthand for creating annotations
# uses these keys from $state:
# - initial_schema_uri
# - keyword
# - data_path
# - traversed_schema_path
# - schema_path
# - _schema_path_suffix
# - annotations
# - collect_annotations
sub A ($state, $annotation) {
  return 1 if not $state->{collect_annotations};

  my $uri = canonical_uri($state, $state->{keyword}, $state->{_schema_path_suffix});

  my $keyword_location = $state->{traversed_schema_path}
    .jsonp($state->{schema_path}, $state->{keyword}, delete $state->{_schema_path_suffix});

  undef $uri if $uri eq '' and $keyword_location eq ''
    or ($uri->fragment // '') eq $keyword_location and $uri->clone->fragment(undef) eq '';

  push $state->{annotations}->@*, JSON::Schema::Modern::Annotation->new(
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    defined $uri ? ( absolute_keyword_location => $uri ) : (),
    annotation => $annotation,
    $state->{_unknown} ? ( unknown => 1 ) : (),
  );

  return 1;
}

# creates an error object, but also aborts evaluation immediately
# only this error is returned, because other errors on the stack might not actually be "real"
# errors (consider if we were in the middle of evaluating a "not" or "if").
# Therefore this is only appropriate during the evaluation phase, not the traverse phase.
sub abort ($state, $error_string, @args) {
  ()= E($state, $error_string, @args);
  my $error = pop $state->{errors}->@*;
  $error->exception(1);
  die $error;
}

sub assert_keyword_exists ($state, $schema) {
  croak 'assert_keyword_exists called in void context' if not defined wantarray;
  return E($state, '%s keyword is required', $state->{keyword}) if not exists $schema->{$state->{keyword}};
  return 1;
}

sub assert_keyword_type ($state, $schema, $type) {
  croak 'assert_keyword_type called in void context' if not defined wantarray;
  my $value = $schema->{$state->{keyword}};
  my $thing = 'value';
  ($value, $thing) = is_plain_hashref($value) ? ($value->{$state->{_schema_path_suffix}}, 'value at "'.$state->{_schema_path_suffix}.'"')
      : is_plain_arrayref($value) ? ($value->[$state->{_schema_path_suffix}], 'item '.$state->{_schema_path_suffix})
      : die 'unknown type'
    if exists $state->{_schema_path_suffix};
  return 1 if is_type($type, $value);
  E($state, '%s %s is not a%s %s', $state->{keyword}, $thing, ($type =~ /^[aeiou]/ ? 'n' : ''), $type);
}

sub assert_pattern ($state, $pattern) {
  croak 'assert_pattern called in void context' if not defined wantarray;
  try {
    local $SIG{__WARN__} = sub { die @_ };
    qr/$pattern/;
  }
  catch ($e) { return E($state, $e); };
  return 1;
}

# this is only suitable for checking URIs within schemas themselves
sub assert_uri_reference ($state, $schema) {
  croak 'assert_uri_reference called in void context' if not defined wantarray;

  my $string = $schema->{$state->{keyword}};
  return E($state, '%s value is not a valid URI reference', $state->{keyword})
    # see also uri-reference format sub
    if fc(Mojo::URL->new($string)->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/
      or $string =~ /#/
        and $string !~ m{#$}                          # empty fragment
        and $string !~ m{#[A-Za-z][A-Za-z0-9_:.-]*$}  # plain-name fragment
        and $string !~ m{#/(?:[^~]|~[01])*$};         # json pointer fragment

  return 1;
}

# this is only suitable for checking URIs within schemas themselves
sub assert_uri ($state, $schema, $override = undef) {
  croak 'assert_uri called in void context' if not defined wantarray;

  my $string = $override // $schema->{$state->{keyword}};
  my $uri = Mojo::URL->new($string);

  return E($state, '"%s" is not a valid URI', $string)
    # see also uri format sub
    if fc($uri->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/
      or not $uri->is_abs
      or $string =~ /#/
        and $string !~ m{#$}                          # empty fragment
        and $string !~ m{#[A-Za-z][A-Za-z0-9_:.-]*$}  # plain-name fragment
        and $string !~ m{#/(?:[^~]|~[01])*$};         # json pointer fragment

  return 1;
}

# produces an annotation whose value is the same as that of the current keyword
sub annotate_self ($state, $schema) {
  A($state, is_ref($schema->{$state->{keyword}}) ? dclone($schema->{$state->{keyword}})
    : $schema->{$state->{keyword}});
}

sub sprintf_num ($value) {
  # use original value as stored in the NV, without losing precision
  ref($value) =~ /^Math::Big(?:Int|Float)$/ ? $value->bstr : sprintf('%s', $value);
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern::Utilities qw(func1 func2..);

=head1 DESCRIPTION

This class contains internal utilities to be used by L<JSON::Schema::Modern>.

=for Pod::Coverage is_type get_type is_equal is_elements_unique jsonp unjsonp local_annotations
canonical_uri E A abort assert_keyword_exists assert_keyword_type assert_pattern assert_uri_reference assert_uri
annotate_self sprintf_num

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
