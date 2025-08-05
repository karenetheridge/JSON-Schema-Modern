use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Validation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Validation vocabulary

our $VERSION = '0.617';

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
use if "$]" < 5.041010, 'List::Util' => 'any';
use if "$]" >= 5.041010, experimental => 'keyword_any';
use Ref::Util 0.100 'is_plain_arrayref';
use Scalar::Util 'looks_like_number';
use JSON::Schema::Modern::Utilities qw(is_type get_type is_bignum is_equal is_elements_unique E assert_keyword_type assert_pattern jsonp sprintf_num);
use Math::BigFloat;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary ($class) {
  'https://json-schema.org/draft/2019-09/vocab/validation' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/validation' => 'draft2020-12';
}

sub evaluation_order ($class) { 1 }

sub keywords ($class, $spec_version) {
  return (
    qw(type enum),
    $spec_version ne 'draft4' ? 'const' : (),
    qw(multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
      maxLength minLength pattern maxItems minItems uniqueItems),
    $spec_version !~ /^draft[467]$/ ? qw(maxContains minContains) : (),
    qw(maxProperties minProperties required),
    $spec_version !~ /^draft[467]$/ ? 'dependentRequired' : (),
  );
}

sub _traverse_keyword_type ($class, $schema, $state) {
  if (is_plain_arrayref($schema->{type})) {
    # Note: this is not actually in the spec, but the restriction exists in the metaschema
    return E($state, 'type array is empty') if not $schema->{type}->@*;

    foreach my $type ($schema->{type}->@*) {
      return E($state, 'unrecognized type "%s"', $type//'<null>')
        if not any { ($type//'') eq $_ } qw(null boolean object array string number integer);
    }
    return E($state, '"type" values are not unique') if not is_elements_unique($schema->{type});
  }
  else {
    return if not assert_keyword_type($state, $schema, 'string');
    return E($state, 'unrecognized type "%s"', $schema->{type}//'<null>')
      if not any { ($schema->{type}//'') eq $_ } qw(null boolean object array string number integer);
  }
  return 1;
}

sub _eval_keyword_type ($class, $data, $schema, $state) {
  my $type = get_type($data, $state->{specification_version} eq 'draft4' ? { legacy_ints => 1 } : ());
  my @want = is_plain_arrayref($schema->{type}) ? $schema->{type}->@* : $schema->{type};

  return 1 if any {
    $type eq $_ or ($_ eq 'number' and $type eq 'integer')
      or ($type eq 'string' and $state->{stringy_numbers} and looks_like_number($data)
          and ($_ eq 'number' or ($_ eq 'integer' and $data == int($data))))
      or ($_ eq 'boolean' and $state->{scalarref_booleans} and $type eq 'reference to SCALAR')
  } @want;

  return E($state, 'got %s, not %s%s', $type, (@want > 1 ? 'one of ' : ''), join(', ', @want));
}

sub _traverse_keyword_enum ($class, $schema, $state) {
  return assert_keyword_type($state, $schema, 'array');
}

sub _eval_keyword_enum ($class, $data, $schema, $state) {
  my @s; my $idx = 0;
  my %s = $state->%{qw(scalarref_booleans stringy_numbers)};
  return 1 if any { is_equal($data, $_, $s[$idx++] = {%s}) } $schema->{enum}->@*;
  return E($state, 'value does not match'
    .(!(grep $_->{path}, @s) ? ''
      : ' ('.join('; ', map "from enum $_ at '$s[$_]->{path}': $s[$_]->{error}", 0..$#s).')'));
}

sub _traverse_keyword_const ($class, $schema, $state) { 1 }

sub _eval_keyword_const ($class, $data, $schema, $state) {
  my %s = $state->%{qw(scalarref_booleans stringy_numbers)};
  return 1 if is_equal($data, $schema->{const}, \%s);
  return E($state, 'value does not match'.($s{path} ? " (at '$s{path}': $s{error})" : ''));
}

sub _traverse_keyword_multipleOf ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'number');
  return E($state, 'multipleOf value is not a positive number') if $schema->{multipleOf} <= 0;
  return 1;
}

sub _eval_keyword_multipleOf ($class, $data, $schema, $state) {
  return 1 if not is_type('number', $data)
    and not ($state->{stringy_numbers} and is_type('string', $data) and looks_like_number($data)
      and do { $data = 0+$data; 1 });

  my $remainder;

  # if either value is a float, use the bignum library for the calculation for an accurate remainder
  if (is_bignum($data) or is_bignum($schema->{multipleOf})
      or get_type($data) eq 'number' or get_type($schema->{multipleOf}) eq 'number') {
    my $dividend = is_bignum($data) ? $data->copy : Math::BigFloat->new($data);
    my $divisor = is_bignum($schema->{multipleOf}) ? $schema->{multipleOf} : Math::BigFloat->new($schema->{multipleOf});
    $remainder = $dividend->bmod($divisor);
  }
  else {
    $remainder = $data % $schema->{multipleOf};
  }

  return 1 if $remainder == 0;
  return E($state, 'value is not a multiple of %s', sprintf_num($schema->{multipleOf}));
}

*_traverse_keyword_maximum = \&_assert_number;

sub _eval_keyword_maximum ($class, $data, $schema, $state) {
  return 1 if not is_type('number', $data)
    and not ($state->{stringy_numbers} and is_type('string', $data) and looks_like_number($data));

  return 1 if 0+$data < $schema->{maximum};
  if ($state->{specification_version} eq 'draft4' and $schema->{exclusiveMaximum}) {
    return E($state, 'value is greater than or equal to %s', sprintf_num($schema->{maximum}));
  }
  else {
    return 1 if 0+$data == $schema->{maximum};
    return E($state, 'value is greater than %s', sprintf_num($schema->{maximum}));
  }
}

sub _traverse_keyword_exclusiveMaximum ($class, $schema, $state) {
  return _assert_number($class, $schema, $state) if $state->{specification_version} ne 'draft4';

  return if not assert_keyword_type($state, $schema, 'boolean');
  return E($state, 'use of exclusiveMaximum requires the presence of maximum')
    if not exists $schema->{maximum};
  return 1;
}

sub _eval_keyword_exclusiveMaximum ($class, $data, $schema, $state) {
  # we do the work in maximum for draft4 so we don't generate multiple errors
  return 1 if $state->{specification_version} eq 'draft4';

  return 1 if not is_type('number', $data)
    and not ($state->{stringy_numbers} and is_type('string', $data) and looks_like_number($data));

  return 1 if 0+$data < $schema->{exclusiveMaximum};
  return E($state, 'value is greater than or equal to %s', sprintf_num($schema->{exclusiveMaximum}));
}

*_traverse_keyword_minimum = \&_assert_number;

sub _eval_keyword_minimum ($class, $data, $schema, $state) {
  return 1 if not is_type('number', $data)
    and not ($state->{stringy_numbers} and is_type('string', $data) and looks_like_number($data));

  return 1 if 0+$data > $schema->{minimum};
  if ($state->{specification_version} eq 'draft4' and $schema->{exclusiveMinimum}) {
    return E($state, 'value is less than or equal to %s', sprintf_num($schema->{minimum}));
  }
  else {
    return 1 if 0+$data == $schema->{minimum};
    return E($state, 'value is less than %s', sprintf_num($schema->{minimum}));
  }
}

sub _traverse_keyword_exclusiveMinimum ($class, $schema, $state) {
  return _assert_number($class, $schema, $state) if $state->{specification_version} ne 'draft4';

  return if not assert_keyword_type($state, $schema, 'boolean');
  return E($state, 'use of exclusiveMinimum requires the presence of minimum')
    if not exists $schema->{minimum};
  return 1;
}

sub _eval_keyword_exclusiveMinimum ($class, $data, $schema, $state) {
  # we do the work in minimum for draft4 so we don't generate multiple errors
  return 1 if $state->{specification_version} eq 'draft4';

  return 1 if not is_type('number', $data)
    and not ($state->{stringy_numbers} and is_type('string', $data) and looks_like_number($data));

  return 1 if 0+$data > $schema->{exclusiveMinimum};
  return E($state, 'value is less than or equal to %s', sprintf_num($schema->{exclusiveMinimum}));
}

*_traverse_keyword_maxLength = \&_assert_non_negative_integer;

sub _eval_keyword_maxLength ($class, $data, $schema, $state) {
  return 1 if not is_type('string', $data);
  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

*_traverse_keyword_minLength = \&_assert_non_negative_integer;

sub _eval_keyword_minLength ($class, $data, $schema, $state) {
  return 1 if not is_type('string', $data);
  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _traverse_keyword_pattern ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_pattern($state, $schema->{pattern});
  return 1;
}

sub _eval_keyword_pattern ($class, $data, $schema, $state) {
  return 1 if not is_type('string', $data);

  return 1 if $data =~ m/(?:$schema->{pattern})/;
  return E($state, 'pattern does not match');
}

*_traverse_keyword_maxItems = \&_assert_non_negative_integer;

sub _eval_keyword_maxItems ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'array has more than %d item%s', $schema->{maxItems}, $schema->{maxItems} > 1 ? 's' : '');
}

*_traverse_keyword_minItems = \&_assert_non_negative_integer;

sub _eval_keyword_minItems ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if @$data >= $schema->{minItems};
  return E($state, 'array has fewer than %d item%s', $schema->{minItems}, $schema->{minItems} > 1 ? 's' : '');
}

sub _traverse_keyword_uniqueItems ($class, $schema, $state) {
  return assert_keyword_type($state, $schema, 'boolean');
}

sub _eval_keyword_uniqueItems ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if not $schema->{uniqueItems};
  return 1 if is_elements_unique($data, my $equal_indices = [], $state);
  return E($state, 'items at indices %d and %d are not unique', @$equal_indices);
}

# The evaluation implementations of maxContains and minContains are in the Applicator vocabulary,
# as 'contains' needs to run first
*_traverse_keyword_maxContains = \&_assert_non_negative_integer;

*_traverse_keyword_minContains = \&_assert_non_negative_integer;

*_traverse_keyword_maxProperties = \&_assert_non_negative_integer;

sub _eval_keyword_maxProperties ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);
  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'object has more than %d propert%s', $schema->{maxProperties},
    $schema->{maxProperties} > 1 ? 'ies' : 'y');
}

*_traverse_keyword_minProperties = \&_assert_non_negative_integer;

sub _eval_keyword_minProperties ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);
  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'object has fewer than %d propert%s', $schema->{minProperties},
    $schema->{minProperties} > 1 ? 'ies' : 'y');
}

sub _traverse_keyword_required ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '"required" array is empty') if $state->{specification_version} eq 'draft4' and not $schema->{required}->@*;
  return E($state, '"required" element is not a string')
    if any { !is_type('string', $_) } $schema->{required}->@*;
  return E($state, '"required" values are not unique') if not is_elements_unique($schema->{required});
  return 1;
}

sub _eval_keyword_required ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my @missing = grep !exists $data->{$_}, $schema->{required}->@*;
  return 1 if not @missing;
  return E($state, 'object is missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
}

sub _traverse_keyword_dependentRequired ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependentRequired}->%*) {
    $valid = E({ %$state, _schema_path_suffix => $property }, 'value is not an array'), next
      if not is_type('array', $schema->{dependentRequired}{$property});

    foreach my $index (0..$schema->{dependentRequired}{$property}->$#*) {
      $valid = E({ %$state, _schema_path_suffix => [ $property, $index ] }, 'element #%d is not a string', $index)
        if not is_type('string', $schema->{dependentRequired}{$property}[$index]);
    }

    $valid = E({ %$state, _schema_path_suffix => $property }, 'elements are not unique')
      if not is_elements_unique($schema->{dependentRequired}{$property});
  }
  return $valid;
}

sub _eval_keyword_dependentRequired ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependentRequired}->%*) {
    next if not exists $data->{$property};

    if (my @missing = grep !exists($data->{$_}), $schema->{dependentRequired}{$property}->@*) {
      $valid = E({ %$state, _schema_path_suffix => $property },
        'object is missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
    }
  }

  return 1 if $valid;
  return E($state, 'not all dependencies are satisfied');
}

sub _assert_number ($class, $schema, $state) {
  return assert_keyword_type($state, $schema, 'number');
}

sub _assert_non_negative_integer ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'integer');
  return E($state, '%s value is not a non-negative integer', $state->{keyword})
    if $schema->{$state->{keyword}} < 0;
  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Validation" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/validation> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-validation.html#section-6>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/validation> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-6>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-6>.
* the equivalent Draft 6 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-06/draft-wright-json-schema-validation-01#rfc.section.6>.
* the equivalent Draft 4 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-04/draft-fge-json-schema-validation-00#rfc.section.5>.

=cut
