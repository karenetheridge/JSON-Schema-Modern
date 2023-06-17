use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Validation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Validation vocabulary

our $VERSION = '0.569';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use List::Util 'any';
use Ref::Util 0.100 'is_plain_arrayref';
use if "$]" >= 5.022, POSIX => 'isinf';
use JSON::Schema::Modern::Utilities qw(is_type get_type is_equal is_elements_unique E assert_keyword_type assert_pattern jsonp sprintf_num);
use Math::BigFloat;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/validation' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/validation' => 'draft2020-12';
}

sub evaluation_order { 1 }

sub keywords ($self, $spec_version) {
  return (
    qw(type enum const
      multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
      maxLength minLength pattern
      maxItems minItems uniqueItems),
    $spec_version ne 'draft7' ? qw(maxContains minContains) : (),
    qw(maxProperties minProperties required),
    $spec_version ne 'draft7' ? 'dependentRequired' : (),
  );
}

sub _traverse_keyword_type ($self, $schema, $state) {
  if (is_plain_arrayref($schema->{type})) {
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

sub _eval_keyword_type ($self, $data, $schema, $state) {
  my $type = get_type($data);
  if (is_plain_arrayref($schema->{type})) {
    return 1 if any {
      $type eq $_ or ($_ eq 'number' and $type eq 'integer')
        or ($_ eq 'boolean' and $state->{scalarref_booleans} and $type eq 'reference to SCALAR')
    } $schema->{type}->@*;
    return E($state, 'got %s, not one of %s', $type, join(', ', $schema->{type}->@*));
  }
  else {
    return 1 if $type eq $schema->{type} or ($schema->{type} eq 'number' and $type eq 'integer')
      or ($schema->{type} eq 'boolean' and $state->{scalarref_booleans} and $type eq 'reference to SCALAR');
    return E($state, 'got %s, not %s', $type, $schema->{type});
  }
}

sub _traverse_keyword_enum ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'array');
  return 1;
}

sub _eval_keyword_enum ($self, $data, $schema, $state) {
  my @s; my $idx = 0;
  my %s = ( scalarref_booleans => $state->{scalarref_booleans} );
  return 1 if any { is_equal($data, $_, $s[$idx++] = {%s}) } $schema->{enum}->@*;
  return E($state, 'value does not match'
    .(!(grep $_->{path}, @s) ? ''
      : ' (differences start '.join(', ', map 'from item #'.$_.' at "'.$s[$_]->{path}.'"', 0..$#s).')'));
}

sub _traverse_keyword_const { 1 }

sub _eval_keyword_const ($self, $data, $schema, $state) {
  my %s = ( scalarref_booleans => $state->{scalarref_booleans} );
  return 1 if is_equal($data, $schema->{const}, my $s = { scalarref_booleans => $state->{scalarref_booleans} });
  return E($state, 'value does not match'
    .($s->{path} ? ' (differences start at "'.$s->{path}.'")' : ''));
}

sub _traverse_keyword_multipleOf ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'number');
  return E($state, 'multipleOf value is not a positive number') if $schema->{multipleOf} <= 0;
  return 1;
}

sub _eval_keyword_multipleOf ($self, $data, $schema, $state) {
  return 1 if not is_type('number', $data);

  # if either value is a float, use the bignum library for the calculation for an accurate remainder
  if (ref($data) =~ /^Math::Big(?:Int|Float)$/
      or ref($schema->{multipleOf}) =~ /^Math::Big(?:Int|Float)$/
      or get_type($data) eq 'number' or get_type($schema->{multipleOf}) eq 'number') {
    $data = ref($data) =~ /^Math::Big(?:Int|Float)$/ ? $data->copy : Math::BigFloat->new($data);
    my $divisor = ref($schema->{multipleOf}) =~ /^Math::Big(?:Int|Float)$/ ? $schema->{multipleOf} : Math::BigFloat->new($schema->{multipleOf});
    my ($quotient, $remainder) = $data->bdiv($divisor);
    return E($state, 'overflow while calculating quotient') if $quotient->is_inf;
    return 1 if $remainder == 0;
  }
  else {
    my $quotient = $data / $schema->{multipleOf};
    return E($state, 'overflow while calculating quotient')
      if "$]" >= 5.022 ? isinf($quotient) : $quotient =~ /^-?Inf$/i;
    return 1 if int($quotient) == $quotient;
  }

  return E($state, 'value is not a multiple of %s', sprintf_num($schema->{multipleOf}));
}

sub _traverse_keyword_maximum { goto \&_assert_number }

sub _eval_keyword_maximum ($self, $data, $schema, $state) {
  return 1 if not is_type('number', $data);
  return 1 if $data <= $schema->{maximum};
  return E($state, 'value is larger than %s', sprintf_num($schema->{maximum}));
}

sub _traverse_keyword_exclusiveMaximum { goto \&_assert_number }

sub _eval_keyword_exclusiveMaximum ($self, $data, $schema, $state) {
  return 1 if not is_type('number', $data);
  return 1 if $data < $schema->{exclusiveMaximum};
  return E($state, 'value is equal to or larger than %s', sprintf_num($schema->{exclusiveMaximum}));
}

sub _traverse_keyword_minimum { goto \&_assert_number }

sub _eval_keyword_minimum ($self, $data, $schema, $state) {
  return 1 if not is_type('number', $data);
  return 1 if $data >= $schema->{minimum};
  return E($state, 'value is smaller than %s', sprintf_num($schema->{minimum}));
}

sub _traverse_keyword_exclusiveMinimum { goto \&_assert_number }

sub _eval_keyword_exclusiveMinimum ($self, $data, $schema, $state) {
  return 1 if not is_type('number', $data);
  return 1 if $data > $schema->{exclusiveMinimum};
  return E($state, 'value is equal to or smaller than %s', sprintf_num($schema->{exclusiveMinimum}));
}

sub _traverse_keyword_maxLength { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxLength ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);
  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

sub _traverse_keyword_minLength { goto \&_assert_non_negative_integer }

sub _eval_keyword_minLength ($self, $data, $schema, $state) {

  return 1 if not is_type('string', $data);
  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _traverse_keyword_pattern ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_pattern($state, $schema->{pattern});
  return 1;
}

sub _eval_keyword_pattern ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);

  return 1 if $data =~ m/(?:$schema->{pattern})/;
  return E($state, 'pattern does not match');
}

sub _traverse_keyword_maxItems { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxItems ($self, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'more than %d item%s', $schema->{maxItems}, $schema->{maxItems} > 1 ? 's' : '');
}

sub _traverse_keyword_minItems { goto \&_assert_non_negative_integer }

sub _eval_keyword_minItems ($self, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if @$data >= $schema->{minItems};
  return E($state, 'fewer than %d item%s', $schema->{minItems}, $schema->{minItems} > 1 ? 's' : '');
}

sub _traverse_keyword_uniqueItems ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'boolean');
  return 1;
}

sub _eval_keyword_uniqueItems ($self, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if not $schema->{uniqueItems};
  return 1 if is_elements_unique($data, my $equal_indices = []);
  return E($state, 'items at indices %d and %d are not unique', @$equal_indices);
}

# Note: no effort is made to check if the 'contains' keyword has been disabled via its vocabulary.
sub _traverse_keyword_maxContains { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxContains ($self, $data, $schema, $state) {
  return 1 if not exists $state->{_num_contains};
  return 1 if not is_type('array', $data);

  return E($state, 'contains too many matching items')
    if $state->{_num_contains} > $schema->{maxContains};

  return 1;
}

sub _traverse_keyword_minContains { goto \&_assert_non_negative_integer }

sub _eval_keyword_minContains ($self, $data, $schema, $state) {
  return 1 if not exists $state->{_num_contains};
  return 1 if not is_type('array', $data);

  return E($state, 'contains too few matching items')
    if $state->{_num_contains} < $schema->{minContains};

  return 1;
}

sub _traverse_keyword_maxProperties { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxProperties ($self, $data, $schema, $state) {
  return 1 if not is_type('object', $data);
  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'more than %d propert%s', $schema->{maxProperties},
    $schema->{maxProperties} > 1 ? 'ies' : 'y');
}

sub _traverse_keyword_minProperties { goto \&_assert_non_negative_integer }

sub _eval_keyword_minProperties ($self, $data, $schema, $state) {
  return 1 if not is_type('object', $data);
  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'fewer than %d propert%s', $schema->{minProperties},
    $schema->{minProperties} > 1 ? 'ies' : 'y');
}

sub _traverse_keyword_required ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '"required" element is not a string')
    if any { !is_type('string', $_) } $schema->{required}->@*;
  return E($state, '"required" values are not unique') if not is_elements_unique($schema->{required});
  return 1;
}

sub _eval_keyword_required ($self, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my @missing = grep !exists $data->{$_}, $schema->{required}->@*;
  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
}

sub _traverse_keyword_dependentRequired ($self, $schema, $state) {
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

sub _eval_keyword_dependentRequired ($self, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependentRequired}->%*) {
    next if not exists $data->{$property};

    if (my @missing = grep !exists($data->{$_}), $schema->{dependentRequired}{$property}->@*) {
      $valid = E({ %$state, _schema_path_suffix => $property },
        'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
    }
  }

  return 1 if $valid;
  return E($state, 'not all dependencies are satisfied');
}

sub _assert_number ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'number');
  return 1;
}

sub _assert_non_negative_integer ($self, $schema, $state) {
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

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
