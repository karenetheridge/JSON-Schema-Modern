use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Validation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use List::Util 'any';
use Ref::Util 0.100 'is_plain_arrayref';
use Syntax::Keyword::Try 0.11;
use JSON::Schema::Draft201909::Utilities qw(is_type is_equal is_elements_unique E abort assert_keyword_type);
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
    maxProperties minProperties required dependentRequired);
}

sub _eval_keyword_type {
  my ($self, $data, $schema, $state) = @_;

  foreach my $type (is_plain_arrayref($schema->{type}) ? @{$schema->{type}} : $schema->{type}) {
    abort($state, 'unrecognized type "%s"', $type)
      if not any { $type eq $_ } qw(null boolean object array string number integer);
    return 1 if is_type($type, $data);
  }

  return E($state, 'wrong type (expected %s)',
    is_plain_arrayref($schema->{type}) ? ('one of '.join(', ', @{$schema->{type}})) : $schema->{type});
}

sub _eval_keyword_enum {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'array');

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

sub _eval_keyword_multipleOf {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');
  abort($state, 'multipleOf value is not a positive number') if $schema->{multipleOf} <= 0;

  my $quotient = $data / $schema->{multipleOf};
  return 1 if int($quotient) == $quotient;
  return E($state, 'value is not a multiple of %g', $schema->{multipleOf});
}

sub _eval_keyword_maximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data <= $schema->{maximum};
  return E($state, 'value is larger than %g', $schema->{maximum});
}

sub _eval_keyword_exclusiveMaximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data < $schema->{exclusiveMaximum};
  return E($state, 'value is equal to or larger than %g', $schema->{exclusiveMaximum});
}

sub _eval_keyword_minimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data >= $schema->{minimum};
  return E($state, 'value is smaller than %g', $schema->{minimum});
}

sub _eval_keyword_exclusiveMinimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data > $schema->{exclusiveMinimum};
  return E($state, 'value is equal to or smaller than %g', $schema->{exclusiveMinimum});
}

sub _eval_keyword_maxLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'maxLength value is not a non-negative integer') if $schema->{maxLength} < 0;

  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

sub _eval_keyword_minLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minLength value is not a non-negative integer') if $schema->{minLength} < 0;

  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _eval_keyword_pattern {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  assert_keyword_type($state, $schema, 'string');

  try {
    return 1 if $data =~ m/$schema->{pattern}/;
    return E($state, 'pattern does not match');
  }
  catch {
    abort($state, $@);
  };
}

sub _eval_keyword_maxItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'maxItems value is not a non-negative integer') if $schema->{maxItems} < 0;

  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'more than %d item%s', $schema->{maxItems}, $schema->{maxItems} > 1 ? 's' : '');
}

sub _eval_keyword_minItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minItems value is not a non-negative integer') if $schema->{minItems} < 0;

  return 1 if @$data >= $schema->{minItems};
  return E($state, 'fewer than %d item%s', $schema->{minItems}, $schema->{minItems} > 1 ? 's' : '');
}

sub _eval_keyword_uniqueItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  assert_keyword_type($state, $schema, 'boolean');

  return 1 if not $schema->{uniqueItems};
  return 1 if is_elements_unique($data, my $equal_indices = []);
  return E($state, 'items at indices %d and %d are not unique', @$equal_indices);
}

sub _eval_keyword_maxProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'maxProperties value is not a non-negative integer')
    if $schema->{maxProperties} < 0;

  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'more than %d propert%s', $schema->{maxProperties},
    $schema->{maxProperties} > 1 ? 'ies' : 'y');
}

sub _eval_keyword_minProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minProperties value is not a non-negative integer')
    if $schema->{minProperties} < 0;

  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'fewer than %d propert%s', $schema->{minProperties},
    $schema->{minProperties} > 1 ? 'ies' : 'y');
}

sub _eval_keyword_required {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  assert_keyword_type($state, $schema, 'array');
  abort($state, '"required" element is not a string')
    if any { !is_type('string', $_) } @{$schema->{required}};

  my @missing = grep !exists $data->{$_}, @{$schema->{required}};
  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
}

sub _eval_keyword_dependentRequired {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');
  abort($state, '"dependentRequired" property is not an array')
    if any { !is_type('array', $schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};
  abort($state, '"dependentRequired" property elements are not unique')
    if any { !is_elements_unique($schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};

  my @missing = grep
    +(exists $data->{$_} && any { !exists $data->{$_} } @{ $schema->{dependentRequired}{$_} }),
    keys %{$schema->{dependentRequired}};

  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', sort @missing));
}

1;
__END__

=pod

=for Pod::Coverage keywords

=cut
