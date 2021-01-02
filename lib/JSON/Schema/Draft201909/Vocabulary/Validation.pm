use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Validation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Draft 2019-09 Validation vocabulary

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use List::Util 'any';
use Ref::Util 0.100 'is_plain_arrayref';
use JSON::Schema::Draft201909::Utilities qw(is_type is_equal is_elements_unique E assert_keyword_type assert_pattern);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/validation' }

sub keywords {
  qw(type enum const
    multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
    maxLength minLength pattern
    maxItems minItems uniqueItems
    minContains maxContains
    maxProperties minProperties required dependentRequired);
}

sub _traverse_keyword_type {
  my ($self, $schema, $state) = @_;

  if (is_plain_arrayref($schema->{type})) {
    foreach my $type (@{$schema->{type}}) {
      return E($state, 'unrecognized type "%s"', $type//'<null>')
        if not any { ($type//'') eq $_ } qw(null boolean object array string number integer);
    }
    return E($state, '"type" values are not unique') if not is_elements_unique($schema->{type});
  }
  else {
    return E($state, 'unrecognized type "%s"', $schema->{type}//'<null>')
      if not any { ($schema->{type}//'') eq $_ } qw(null boolean object array string number integer);
  }
}

sub _eval_keyword_type {
  my ($self, $data, $schema, $state) = @_;

  if (is_plain_arrayref($schema->{type})) {
    foreach my $type (@{$schema->{type}}) {
      return 1 if is_type($type, $data);
    }
    return E($state, 'wrong type (expected one of %s)', join(', ', @{$schema->{type}}));
  }
  else {
    return 1 if is_type($schema->{type}, $data);
    return E($state, 'wrong type (expected %s)', $schema->{type});
  }
}

sub _traverse_keyword_enum {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '"enum" values are not unique') if not is_elements_unique($schema->{enum});
}

sub _eval_keyword_enum {
  my ($self, $data, $schema, $state) = @_;

  my @s; my $idx = 0;
  return 1 if any { is_equal($data, $_, $s[$idx++] = {}) } @{$schema->{enum}};

  return E($state, 'value does not match'
    .(!(grep $_->{path}, @s) ? ''
      : ' (differences start '.join(', ', map 'from #'.$_.' at "'.$s[$_]->{path}.'"', 0..$#s).')'));
}

sub _eval_keyword_const {
  my ($self, $data, $schema, $state) = @_;

  return 1 if is_equal($data, $schema->{const}, my $s = {});
  return E($state, 'value does not match'
    .($s->{path} ? ' (differences start at "'.$s->{path}.'")' : ''));
}

sub _traverse_keyword_multipleOf {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'number');
  return E($state, 'multipleOf value is not a positive number') if $schema->{multipleOf} <= 0;
}

sub _eval_keyword_multipleOf {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);

  my $quotient = $data / $schema->{multipleOf};
  return 1 if int($quotient) == $quotient and $quotient !~ /^-?Inf$/i;
  return E($state, 'value is not a multiple of %g', $schema->{multipleOf});
}

sub _traverse_keyword_maximum { goto \&_assert_number }

sub _eval_keyword_maximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  return 1 if $data <= $schema->{maximum};
  return E($state, 'value is larger than %g', $schema->{maximum});
}

sub _traverse_keyword_exclusiveMaximum { goto \&_assert_number }

sub _eval_keyword_exclusiveMaximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  return 1 if $data < $schema->{exclusiveMaximum};
  return E($state, 'value is equal to or larger than %g', $schema->{exclusiveMaximum});
}

sub _traverse_keyword_minimum { goto \&_assert_number }

sub _eval_keyword_minimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  return 1 if $data >= $schema->{minimum};
  return E($state, 'value is smaller than %g', $schema->{minimum});
}

sub _traverse_keyword_exclusiveMinimum { goto \&_assert_number }

sub _eval_keyword_exclusiveMinimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  return 1 if $data > $schema->{exclusiveMinimum};
  return E($state, 'value is equal to or smaller than %g', $schema->{exclusiveMinimum});
}

sub _traverse_keyword_maxLength { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

sub _traverse_keyword_minLength { goto \&_assert_non_negative_integer }

sub _eval_keyword_minLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _traverse_keyword_pattern {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  assert_pattern($state, $schema->{pattern});
}

sub _eval_keyword_pattern {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);

  return 1 if $data =~ m/$schema->{pattern}/;
  return E($state, 'pattern does not match');
}

sub _traverse_keyword_maxItems { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);

  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'more than %d item%s', $schema->{maxItems}, $schema->{maxItems} > 1 ? 's' : '');
}

sub _traverse_keyword_minItems { goto \&_assert_non_negative_integer }

sub _eval_keyword_minItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  return 1 if @$data >= $schema->{minItems};
  return E($state, 'fewer than %d item%s', $schema->{minItems}, $schema->{minItems} > 1 ? 's' : '');
}

sub _traverse_keyword_uniqueItems {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'boolean');
}

sub _eval_keyword_uniqueItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  return 1 if not $schema->{uniqueItems};
  return 1 if is_elements_unique($data, my $equal_indices = []);
  return E($state, 'items at indices %d and %d are not unique', @$equal_indices);
}

# Note: no effort is made to check if the 'contains' keyword has been disabled via its vocabulary.
sub _traverse_keyword_minContains { goto \&_assert_non_negative_integer }
sub _traverse_keyword_maxContains { goto \&_assert_non_negative_integer }

sub _traverse_keyword_maxProperties { goto \&_assert_non_negative_integer }

sub _eval_keyword_maxProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'more than %d propert%s', $schema->{maxProperties},
    $schema->{maxProperties} > 1 ? 'ies' : 'y');
}

sub _traverse_keyword_minProperties { goto \&_assert_non_negative_integer }

sub _eval_keyword_minProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'fewer than %d propert%s', $schema->{minProperties},
    $schema->{minProperties} > 1 ? 'ies' : 'y');
}

sub _traverse_keyword_required {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'array');
  return E($state, '"required" element is not a string')
    if any { !is_type('string', $_) } @{$schema->{required}};
  return E($state, '"required" values are not unique') if not is_elements_unique($schema->{required});
}

sub _eval_keyword_required {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my @missing = grep !exists $data->{$_}, @{$schema->{required}};
  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
}

sub _traverse_keyword_dependentRequired {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'object');
  return E($state, '"dependentRequired" property is not an array')
    if any { !is_type('array', $schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};
  return E($state, '"dependentRequired" property element is not a string')
    if any { !is_type('string', $_) } map @$_, values %{$schema->{dependentRequired}};
  return E($state, '"dependentRequired" property elements are not unique')
    if any { !is_elements_unique($schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};
}

sub _eval_keyword_dependentRequired {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my @missing = grep
    +(exists $data->{$_} && any { !exists $data->{$_} } @{ $schema->{dependentRequired}{$_} }),
    keys %{$schema->{dependentRequired}};

  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', sort @missing));
}

sub _assert_number {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'number');
}

sub _assert_non_negative_integer {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'integer');
  return E($state, '%s value is not a non-negative integer', $state->{keyword})
    if $schema->{$state->{keyword}} < 0;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2019-09 "Validation" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/validation> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.6>.

=cut
