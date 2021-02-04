use strict;
use warnings;
package JSON::Schema::Draft201909::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Internal utilities for JSON::Schema::Draft201909

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use B;
use Carp 'croak';
use JSON::MaybeXS 1.004001 'is_bool';
use Ref::Util 0.100 qw(is_ref is_plain_arrayref is_plain_hashref);
use Feature::Compat::Try;
use Storable 'dclone';
use strictures 2;
use JSON::Schema::Draft201909::Error;
use JSON::Schema::Draft201909::Annotation;
use namespace::clean;

use Exporter 'import';

our @EXPORT_OK = qw(
  is_type
  get_type
  is_equal
  is_elements_unique
  jsonp
  local_annotations
  canonical_schema_uri
  E
  A
  abort
  assert_keyword_type
  assert_pattern
  assert_uri_ref
  annotate_self
  true
  false
);

use JSON::PP ();
use constant { true => JSON::PP::true, false => JSON::PP::false };

sub is_type {
  my ($type, $value) = @_;

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
    return 0 if not defined $value or is_ref($value);
    my $flags = B::svref_2object(\$value)->FLAGS;

    if ($type eq 'string') {
      return $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'number') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'integer') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK))
        && int($value) == $value;
    }
  }

  croak sprintf('unknown type "%s"', $type);
}

# only the core six types are reported (integers are numbers)
# use is_type('integer') to differentiate numbers from integers.
sub get_type {
  my ($value) = @_;

  return 'null' if not defined $value;
  return 'object' if is_plain_hashref($value);
  return 'array' if is_plain_arrayref($value);
  return 'boolean' if is_bool($value);

  croak sprintf('unsupported reference type %s', ref $value) if is_ref($value);

  my $flags = B::svref_2object(\$value)->FLAGS;
  return 'string' if $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
  return 'number' if !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));

  croak sprintf('ambiguous type for %s',
    JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 0)->encode($value));
}

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.4.2.3
sub is_equal {
  my ($x, $y, $state) = @_;
  $state->{path} //= '';

  my @types = map get_type($_), $x, $y;
  return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  return $x eq $y if $types[0] eq 'string';
  return $x == $y if $types[0] eq 'boolean' or $types[0] eq 'number';

  my $path = $state->{path};
  if ($types[0] eq 'object') {
    return 0 if keys %$x != keys %$y;
    return 0 if not is_equal([ sort keys %$x ], [ sort keys %$y ]);
    foreach my $property (keys %$x) {
      $state->{path} = jsonp($path, $property);
      return 0 if not is_equal($x->{$property}, $y->{$property}, $state);
    }
    return 1;
  }

  if ($types[0] eq 'array') {
    return 0 if @$x != @$y;
    foreach my $idx (0 .. $#{$x}) {
      $state->{path} = $path.'/'.$idx;
      return 0 if not is_equal($x->[$idx], $y->[$idx], $state);
    }
    return 1;
  }

  return 0; # should never get here
}

# checks array elements for uniqueness. short-circuits on first pair of matching elements
# if second arrayref is provided, it is populated with the indices of identical items
sub is_elements_unique {
  my ($array, $equal_indices) = @_;
  foreach my $idx0 (0 .. $#{$array}-1) {
    foreach my $idx1 ($idx0+1 .. $#{$array}) {
      if (is_equal($array->[$idx0], $array->[$idx1])) {
        push @$equal_indices, $idx0, $idx1 if defined $equal_indices;
        return 0;
      }
    }
  }
  return 1;
}

# shorthand for creating and appending json pointers
sub jsonp {
  return join('/', shift, map s/~/~0/gr =~ s!/!~1!gr, grep defined, @_);
}

# get all annotations produced for the current instance data location
sub local_annotations {
  my ($state) = @_;
  grep $_->instance_location eq $state->{data_path}, @{$state->{annotations}};
}

# shorthand for finding the canonical uri of the present schema location
sub canonical_schema_uri {
  my ($state, @extra_path) = @_;

  my $uri = $state->{canonical_schema_uri}->clone;
  $uri->fragment(($uri->fragment//'').jsonp($state->{schema_path}, @extra_path));
  $uri->fragment(undef) if not length($uri->fragment);
  $uri;
}

# shorthand for creating error objects
sub E {
  my ($state, $error_string, @args) = @_;

  # sometimes the keyword shouldn't be at the very end of the schema path
  my $uri = canonical_schema_uri($state, $state->{keyword}, $state->{_schema_path_suffix});

  my $keyword_location = $state->{traversed_schema_path}
    .jsonp($state->{schema_path}, $state->{keyword}, delete $state->{_schema_path_suffix});

  undef $uri if $uri eq '' and $keyword_location eq ''
    or ($uri->fragment // '') eq $keyword_location and $uri->clone->fragment(undef) eq '';

  push @{$state->{errors}}, JSON::Schema::Draft201909::Error->new(
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    defined $uri ? ( absolute_keyword_location => $uri ) : (),
    error => @args ? sprintf($error_string, @args) : $error_string,
  );

  return 0;
}

# shorthand for creating annotations
sub A {
  my ($state, $annotation) = @_;
  return 1 if not $state->{collect_annotations};

  my $uri = canonical_schema_uri($state, $state->{keyword}, $state->{_schema_path_suffix});

  my $keyword_location = $state->{traversed_schema_path}
    .jsonp($state->{schema_path}, $state->{keyword}, delete $state->{_schema_path_suffix});

  undef $uri if $uri eq '' and $keyword_location eq ''
    or ($uri->fragment // '') eq $keyword_location and $uri->clone->fragment(undef) eq '';

  push @{$state->{annotations}}, JSON::Schema::Draft201909::Annotation->new(
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    defined $uri ? ( absolute_keyword_location => $uri ) : (),
    annotation => $annotation,
  );

  return 1;
}

# creates an error object, but also aborts evaluation immediately
# only this error is returned, because other errors on the stack might not actually be "real"
# errors (consider if we were in the middle of evaluating a "not" or "if")
sub abort {
  my ($state, $error_string, @args) = @_;
  E($state, 'EXCEPTION: '.$error_string, @args);
  die pop @{$state->{errors}};
}

sub assert_keyword_type {
  my ($state, $schema, $type) = @_;
  return 1 if is_type($type, $schema->{$state->{keyword}});
  E($state, '%s value is not a%s %s', $state->{keyword}, ($type =~ /^[aeiou]/ ? 'n' : ''), $type);
}

sub assert_pattern {
  my ($state, $pattern) = @_;
  try { qr/$pattern/; }
  catch ($e) { return E($state, $e); };
  return 1;
}

sub assert_uri_ref {
  my ($state, $schema) = @_;

  # for now, we just check for fragment validity
  my $ref = $schema->{$state->{keyword}};
  return 1 if $ref !~ /#/
    or $ref =~ /#$/                           # empty fragment
    or $ref =~ m{#[A-Za-z][-A-Za-z0-9.:_]*$}  # plain-name fragment
    or $ref =~ m{#/(?:[^~]|~[01])*$};         # json pointer fragment
  E($state, '%s value is not a valid schema reference', $state->{keyword});
}

# produces an annotation whose value is the same as that of the current keyword
sub annotate_self {
  my ($state, $schema) = @_;
  A($state, is_ref($schema->{$state->{keyword}}) ? dclone($schema->{$state->{keyword}})
    : $schema->{$state->{keyword}});
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Draft201909::Utilities qw(func1 func2..);

=head1 DESCRIPTION

This class contains internal utilities to be used by L<JSON::Schema::Draft201909>.

=for Pod::Coverage is_type get_type is_equal is_elements_unique jsonp local_annotations
canonical_schema_uri E A abort assert_keyword_type assert_pattern assert_uri_ref annotate_self

=cut
