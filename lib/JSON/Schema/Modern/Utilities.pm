use strict;
use warnings;
package JSON::Schema::Modern::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Internal utilities for JSON::Schema::Modern

our $VERSION = '0.615';

use 5.020;
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
use B;
use Carp 'croak';
use Ref::Util 0.100 qw(is_ref is_plain_arrayref is_plain_hashref);
use builtin::compat qw(blessed created_as_number);
use Scalar::Util 'looks_like_number';
use Storable 'dclone';
use Feature::Compat::Try;
use Mojo::JSON ();
use JSON::PP ();
use namespace::clean;

use Exporter 'import';

our @EXPORT_OK = qw(
  is_type
  get_type
  is_schema
  is_bignum
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

use constant HAVE_BUILTIN => "$]" >= 5.035010;
use if HAVE_BUILTIN, experimental => 'builtin';

use constant _BUILTIN_BOOLS => 0;
use constant {
  _BUILTIN_BOOLS && HAVE_BUILTIN && eval { +require Storable; Storable->VERSION(3.27); 1 }
      && Mojo::JSON::JSON_XS && eval { Cpanel::JSON::XS->VERSION(4.38); 1 }
    ? ( true => builtin::true, false => builtin::false )
    : ( true => JSON::PP::true, false => JSON::PP::false )
};

# supports the six core types, plus integer (which is also a number)
# we do NOT check stringy_numbers here -- you must do that in the caller
# note that sometimes a value may return true for more than one type, e.g. integer+number,
# or number+string, depending on its internal flags.
# pass { legacy_ints => 1 } in $config to use draft4 integer behaviour
# behaviour is consistent with get_type() (where integers are also numbers).
sub is_type ($type, $value, $config = {}) {
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

    # dualvars with the same string and (stringified) numeric value could be either a string or a
    # number, and before 5.36 we can't tell the difference, so we will answer yes for both.
    # in 5.36+, stringified numbers still get a PV but don't have POK set, whereas
    # numified strings do have POK set, so we can tell which one came first.

    if ($type eq 'string') {
      # like created_as_string, but rejects dualvars with stringwise-unequal string and numeric parts
      return !is_ref($value)
        && !(HAVE_BUILTIN && builtin::is_bool($value))
        && $flags & B::SVf_POK
        && (!($flags & (B::SVf_IOK | B::SVf_NOK))
            || do { no warnings 'numeric'; 0+$value eq $value });
    }

    if ($type eq 'number') {
      # floats in json will always be parsed into Math::BigFloat, when allow_bignum is enabled
      return is_bignum($value) || created_as_number($value);
    }

    if ($type eq 'integer') {
      if ($config->{legacy_ints}) {
        # in draft4, an integer is "A JSON number without a fraction or exponent part.",
        # therefore 2.0 is NOT an integer
        return ref($value) eq 'Math::BigInt'
          || ($flags & B::SVf_IOK) && !($flags & B::SVf_NOK) && created_as_number($value);
      }
      else {
        # note: values that are larger than $Config{ivsize} will be represented as an NV, not IV,
        # therefore they will fail this check -- which is why use of Math::BigInt is recommended
        # if the exact type is important, or loss of any accuracy is unacceptable
        return is_bignum($value) && $value->is_int
          # if dualvar, PV and stringified NV/IV must be identical
          || created_as_number($value) && int($value) == $value;
      }
    }
  }

  if ($type =~ /^reference to (.+)$/) {
    return !blessed($value) && ref($value) eq $1;
  }

  return ref($value) eq $type;
}

# returns one of the six core types, plus integer
# we do NOT check stringy_numbers here -- you must do that in the caller
# pass { legacy_ints => 1 } in $config to use draft4 integer behaviour
# behaviour is consistent with is_type().
sub get_type ($value, $config = {}) {
  return 'object' if is_plain_hashref($value);
  return 'boolean' if is_bool($value);
  return 'null' if not defined $value;
  return 'array' if is_plain_arrayref($value);

  # floats in json will always be parsed into Math::BigFloat, when allow_bignum is enabled
  if (is_ref($value)) {
    my $ref = ref($value);
    return $ref eq 'Math::BigInt' ? 'integer'
      : $ref eq 'Math::BigFloat' ? (!$config->{legacy_ints} && $value->is_int ? 'integer' : 'number')
      : (defined blessed($value) ? '' : 'reference to ').$ref;
  }

  my $flags = B::svref_2object(\$value)->FLAGS;

  # dualvars with the same string and (stringified) numeric value could be either a string or a
  # number, and before 5.36 we can't tell the difference, so we choose number because it has been
  # evaluated as a number already.
  # in 5.36+, stringified numbers still get a PV but don't have POK set, whereas
  # numified strings do have POK set, so we can tell which one came first.

  # like created_as_string, but rejects dualvars with stringwise-unequal string and numeric parts
  return 'string'
    if $flags & B::SVf_POK
      && (!($flags & (B::SVf_IOK | B::SVf_NOK))
        || do { no warnings 'numeric'; 0+$value eq $value });

  if ($config->{legacy_ints}) {
    # in draft4, an integer is "A JSON number without a fraction or exponent part.",
    # therefore 2.0 is NOT an integer
    return ($flags & B::SVf_IOK) && !($flags & B::SVf_NOK) ? 'integer' : 'number'
      if created_as_number($value);
  }
  else {
    # note: values that are larger than $Config{ivsize} will be represented as an NV, not IV,
    # therefore they will fail this check -- which is why use of Math::BigInt is recommended
    # if the exact type is important, or loss of any accuracy is unacceptable
    return int($value) == $value ? 'integer' : 'number' if created_as_number($value);
  }

  # this might be a scalar with POK|IOK or POK|NOK set
  return 'ambiguous type';
}

# lifted from JSON::MaybeXS
# note: unlike builtin::compat::is_bool on older perls, we do not accept
# dualvar(0,"") or dualvar(1,"1") because JSON::PP and Cpanel::JSON::XS
# do not encode these as booleans.
sub is_bool ($value) {
  HAVE_BUILTIN and builtin::is_bool($value)
  or
  !!blessed($value)
    and ($value->isa('JSON::PP::Boolean')
      or $value->isa('Cpanel::JSON::XS::Boolean')
      or $value->isa('JSON::XS::Boolean'));
}

sub is_schema ($value) {
  is_plain_hashref($value) || is_bool($value);
}

sub is_bignum ($value) {
  ref($value) =~ /^Math::Big(?:Int|Float)$/;
}

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.2.2
# $state hashref supports the following fields:
# - stringy_numbers (input): strings will also be compared numerically
# - path (output): location of the first difference
# - error (output): description of the difference
sub is_equal ($x, $y, $state = {}) {
  $state->{path} //= '';

  my @types = map get_type($_), $x, $y;

  $state->{error} = 'ambiguous type encountered', return 0
    if grep $types[$_] eq 'ambiguous type', 0..1;

  if ($state->{scalarref_booleans}) {
    ($x, $types[0]) = (0+!!$$x, 'boolean') if $types[0] eq 'reference to SCALAR';
    ($y, $types[1]) = (0+!!$$y, 'boolean') if $types[1] eq 'reference to SCALAR';
  }

  if ($state->{stringy_numbers}) {
    ($x, $types[0]) = (0+$x, int(0+$x) == $x ? 'integer' : 'number')
      if $types[0] eq 'string' and looks_like_number($x);

    ($y, $types[1]) = (0+$y, int(0+$y) == $y ? 'integer' : 'number')
      if $types[1] eq 'string' and looks_like_number($y);
  }

  $state->{error} = "wrong type: $types[0] vs $types[1]", return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  ($x eq $y and return 1), $state->{error} = 'strings not equal', return 0
    if $types[0] eq 'string';
  ($x == $y and return 1), $state->{error} = "$types[0]s not equal", return 0
    if grep $types[0] eq $_, qw(boolean number integer);

  my $path = $state->{path};
  if ($types[0] eq 'object') {
    $state->{error} = 'property count differs: '.keys(%$x).' vs '.keys(%$y), return 0
      if keys %$x != keys %$y;

    if (not is_equal(my $arr_x = [ sort keys %$x ], my $arr_y = [ sort keys %$y ], my $s={})) {
      my $pos = substr($s->{path}, 1);
      $state->{error} = 'property names differ starting at position '.$pos.' ("'.$arr_x->[$pos].'" vs "'.$arr_y->[$pos].'")';
      return 0;
    }

    foreach my $property (sort keys %$x) {
      $state->{path} = jsonp($path, $property);
      return 0 if not is_equal($x->{$property}, $y->{$property}, $state);
    }

    return 1;
  }

  if ($types[0] eq 'array') {
    $state->{error} = 'element count differs: '.@$x.' vs '.@$y, return 0 if @$x != @$y;
    foreach my $idx (0 .. $x->$#*) {
      $state->{path} = $path.'/'.$idx;
      return 0 if not is_equal($x->[$idx], $y->[$idx], $state);
    }
    return 1;
  }

  $state->{error} = 'uh oh', return 0; # should never get here
}

# checks array elements for uniqueness. short-circuits on first pair of matching elements
# if second arrayref is provided, it is populated with the indices of identical items
# $state hashref supports the following fields:
# - scalarref_booleans (input): treats \0 and \1 as boolean values
# - stringy_numbers (input): strings will also be compared numerically
sub is_elements_unique ($array, $equal_indices = undef, $state = {}) {
  my %s = $state->%{qw(scalarref_booleans stringy_numbers)};
  foreach my $idx0 (0 .. $array->$#*-1) {
    foreach my $idx1 ($idx0+1 .. $array->$#*) {
      if (is_equal($array->[$idx0], $array->[$idx1], \%s)) {
        push @$equal_indices, $idx0, $idx1 if defined $equal_indices;
        return 0;
      }
    }
  }
  return 1;
}

# shorthand for creating and appending json pointers
# the first argument is an already-encoded json pointer; remaining arguments are path segments to be
# encoded and appended
sub jsonp {
  warn q{first argument to jsonp should be '' or start with '/'} if length($_[0]) and substr($_[0],0,1) ne '/';
  return join('/', shift, map s!~!~0!gr =~ s!/!~1!gr, grep defined, @_);
}

# splits a json pointer apart into its path segments
sub unjsonp {
  warn q{argument to unjsonp should be '' or start with '/'} if length($_[0]) and substr($_[0],0,1) ne '/';
  return map s!~0!~!gr =~ s!~1!/!gr, split m!/!, $_[0];
}

# get all annotations produced for the current instance data location (that are visible to this
# schema location) - remember these are hashrefs, not Annotation objects
sub local_annotations ($state) {
  grep $_->{instance_location} eq $state->{data_path}, $state->{annotations}->@*;
}

# shorthand for finding the current uri of the present schema location
# ensure that this code is kept consistent with the absolute_keyword_location builder in ResultNode
# Note that this may not be canonical if schema_path has not yet been reset via the processing of a
# local identifier keyword (e.g. '$id').
sub canonical_uri ($state, @extra_path) {
  return $state->{initial_schema_uri} if not @extra_path and not length($state->{schema_path});
  my $uri = $state->{initial_schema_uri}->clone;
  my $fragment = ($uri->fragment//'').(@extra_path ? jsonp($state->{schema_path}, @extra_path) : $state->{schema_path});
  undef $fragment if not length($fragment);
  $uri->fragment($fragment);
  $uri;
}

# shorthand for creating error objects
# uses these keys from $state:
# - initial_schema_uri
# - effective_base_uri (optional)
# - keyword (optional)
# - data_path
# - traversed_schema_path
# - schema_path
# - _schema_path_suffix (optional)
# - errors
# - exception (optional; set by abort())
# - recommended_response (optional)
# - depth
# - traverse (boolean, used for mode)
# returns defined-false, so callers can use 'return;' to differentiate between
# failed-with-no-error from failed-with-error.
sub E ($state, $error_string, @args) {
  croak 'E called in void context' if not defined wantarray;

  # sometimes the keyword shouldn't be at the very end of the schema path
  my $sps = delete $state->{_schema_path_suffix};
  my @schema_path_suffix = defined $sps && is_plain_arrayref($sps) ? $sps->@* : $sps//();

  # we store the absolute uri in unresolved form until needed,
  # and perform the rest of the calculations later.
  my $uri = [ $state->@{qw(initial_schema_uri schema_path)}, $state->{keyword}//(), @schema_path_suffix, $state->{effective_base_uri} ];

  my $keyword_location = $state->{traversed_schema_path}
    .jsonp($state->@{qw(schema_path keyword)}, @schema_path_suffix);

  require JSON::Schema::Modern::Error;
  push $state->{errors}->@*, JSON::Schema::Modern::Error->new(
    depth => $state->{depth} // 0,
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    # we calculate absolute_keyword_location when instantiating the Error object for Result
    _uri => $uri,
    error => @args ? sprintf($error_string, @args) : $error_string,
    exception => $state->{exception},
    ($state->%{recommended_response})x!!$state->{recommended_response},
    mode => $state->{traverse} ? 'traverse' : 'evaluate',
  );

  return 0;
}

# shorthand for creating annotations
# uses these keys from $state:
# - initial_schema_uri
# - keyword (mandatory)
# - data_path
# - traversed_schema_path
# - schema_path
# - _schema_path_suffix (optional)
# - annotations
# - collect_annotations
# - spec_version
# - _unknown (boolean)
# - depth
sub A ($state, $annotation) {
  return 1 if not $state->{collect_annotations};

  # we store the absolute uri in unresolved form until needed,
  # and perform the rest of the calculations later.
  my $uri = [ $state->@{qw(initial_schema_uri schema_path keyword effective_base_uri)} ];

  my $keyword_location = $state->{traversed_schema_path}.jsonp($state->@{qw(schema_path keyword)});

  push $state->{annotations}->@*, {
    depth => $state->{depth} // 0,
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    # we calculate absolute_keyword_location when instantiating the Annotation object for Result
    _uri => $uri,
    annotation => $annotation,
    $state->{_unknown} ? ( unknown => 1 ) : (),
  };

  return 1;
}

# creates an error object, but also aborts evaluation immediately
# only this error is returned, because other errors on the stack might not actually be "real"
# errors (consider if we were in the middle of evaluating a "not" or "if").
# Therefore this is only appropriate during the evaluation phase, not the traverse phase.
sub abort ($state, $error_string, @args) {
  ()= E({ %$state, exception => 1 }, $error_string, @args);
  croak 'abort() called during traverse' if $state->{traverse};
  die pop $state->{errors}->@*;
}

sub assert_keyword_exists ($state, $schema) {
  croak 'assert_keyword_exists called in void context' if not defined wantarray;
  return E($state, '%s keyword is required', $state->{keyword}) if not exists $schema->{$state->{keyword}};
  return 1;
}

sub assert_keyword_type ($state, $schema, $type) {
  croak 'assert_keyword_type called in void context' if not defined wantarray;
  return 1 if is_type($type, $schema->{$state->{keyword}});
  E($state, '%s value is not a%s %s', $state->{keyword}, ($type =~ /^[aeiou]/ ? 'n' : ''), $type);
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
# note that we cannot use $state->{spec_version} to more tightly constrain the plain-name fragment
# syntax, as we could be checking a $ref to a schema using a different version
sub assert_uri_reference ($state, $schema) {
  croak 'assert_uri_reference called in void context' if not defined wantarray;

  my $string = $schema->{$state->{keyword}};
  return E($state, '%s value is not a valid URI reference', $state->{keyword})
    # see also uri-reference format sub
    if fc(Mojo::URL->new($string)->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/            # ascii characters only
      or $string =~ /#/                       # no fragment, except...
        and $string !~ m{#$}                          # allow empty fragment
        and $string !~ m{#[A-Za-z_][A-Za-z0-9_:.-]*$} # allow plain-name fragment, superset of all drafts
        and $string !~ m{#/(?:[^~]|~[01])*$};         # allow json pointer fragment

  return 1;
}

# this is only suitable for checking URIs within schemas themselves,
# which have fragments consisting of plain names (anchors) or json pointers
sub assert_uri ($state, $schema, $override = undef) {
  croak 'assert_uri called in void context' if not defined wantarray;

  my $string = $override // $schema->{$state->{keyword}};
  my $uri = Mojo::URL->new($string);

  return E($state, '"%s" is not a valid URI', $string)
    # see also uri format sub
    if fc($uri->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/            # ascii characters only
      or not $uri->is_abs                     # must have a scheme
      or $string =~ /#/                       # no fragment, except...
        and $string !~ m{#$}                          # empty fragment
        and $string !~ m{#[A-Za-z][A-Za-z0-9_:.-]*$}  # plain-name fragment
        and $string !~ m{#/(?:[^~]|~[01])*$};         # json pointer fragment

  return 1;
}

# produces an annotation whose value is the same as that of the current schema keyword
# makes a copy as this is passed back to the user, who cannot be trusted to not mutate it
sub annotate_self ($state, $schema) {
  A($state, is_ref($schema->{$state->{keyword}}) ? dclone($schema->{$state->{keyword}})
    : $schema->{$state->{keyword}});
}

# use original value as stored in the NV, without losing precision
sub sprintf_num ($value) {
  is_bignum($value) ? $value->bstr : sprintf('%s', $value);
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern::Utilities qw(func1 func2..);

=head1 DESCRIPTION

This class contains internal utilities to be used by L<JSON::Schema::Modern>.

=for Pod::Coverage is_type get_type is_bignum is_bool is_schema is_equal is_elements_unique jsonp unjsonp local_annotations
canonical_uri E A abort assert_keyword_exists assert_keyword_type assert_pattern assert_uri_reference assert_uri
annotate_self sprintf_num HAVE_BUILTIN true false

=cut
