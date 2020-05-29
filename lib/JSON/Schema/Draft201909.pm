use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.003';

no if "$]" >= 5.031009, feature => 'indirect';
use feature 'current_sub';
use JSON::MaybeXS 1.004001 'is_bool';
use Syntax::Keyword::Try 0.11;
use Carp 'croak';
use List::Util 1.33 qw(any pairs);
use Mojo::JSON::Pointer;
use Mojo::URL;
use Safe::Isa;
use Moo;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(Bool Int HasMethods Enum InstanceOf HashRef Dict);
use JSON::Schema::Draft201909::Error;
use JSON::Schema::Draft201909::Result;
use namespace::clean;

has output_format => (
  is => 'ro',
  isa => Enum[qw(flag basic detailed verbose)],
  default => 'basic',
);

has short_circuit => (
  is => 'ro',
  isa => Bool,
  lazy => 1,
  default => sub { $_[0]->output_format eq 'flag' },
);

has max_traversal_depth => (
  is => 'ro',
  isa => Int,
  default => 50,
);

has _resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      # see JSON::MaybeXS::is_bool
      ref => InstanceOf[qw(JSON::XS::Boolean Cpanel::JSON::XS::Boolean JSON::PP::Boolean)]|HashRef,
      canonical_uri => InstanceOf['Mojo::URL'],
    ]],
  handles_via => 'Hash',
  handles => {
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _resource_index => 'elements',
  },
  lazy => 1,
  default => sub { {} },
);

before _add_resources => sub {
  my $self = shift;
  foreach my $pair (pairs @_) {
    my ($key, $value) = @$pair;
    if (my $existing = $self->_get_resource($key)) {
      croak 'a schema resource is already indexed with uri "'.$key.'"'
        # we allow overwriting canonical_uri = '' to allow for ad hoc evaluation of
        # schemas that lack all identifiers altogether
        if ($key ne '' and $existing->{canonical_uri} ne '')
          and $existing->{ref} != $value->{ref}
            or $existing->{canonical_uri} ne $value->{canonical_uri};
    }

    croak sprintf('canonical_uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($value->{canonical_uri}->fragment // '') =~ m{^[^/]};
  }
};

has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { JSON::MaybeXS->new(allow_nonref => 1, utf8 => 1) },
);

sub evaluate_json_string {
  my ($self, $json_data, $schema) = @_;
  my $data;
  try {
    $data = $self->_json_decoder->decode($json_data)
  }
  catch {
    return JSON::Schema::Draft201909::Result->new(
      output_format => $self->output_format,
      result => 0,
      errors => [
        JSON::Schema::Draft201909::Error->new(
          instance_location => '',
          keyword_location => '',
          error => $@,
        )
      ],
    );
  }

  return $self->evaluate($data, $schema);
}

sub evaluate {
  my ($self, $data, $schema) = @_;

  $self->_find_all_identifiers($schema);

  my $state = {
    base_uri => Mojo::URL->new,                   # TODO: will be set by a global attribute
    short_circuit => $self->short_circuit,
    depth => 0,
    data_path => '',
    traversed_schema_path => '',  # the accumulated path up to the last $ref traversal
    absolute_schema_uri => undef, # the absolute path of the last traversed $ref; always a Mojo::URL
    schema_path => '',            # the rest of the path, since the last traversed $ref
    errors => [],
  };

  my $result;
  try {
    $result = $self->_eval($data, $schema, $state);
  }
  catch {
    if ($@->$_isa('JSON::Schema::Draft201909::Error')) {
      push @{$state->{errors}}, $@;
    }
    else {
      E($state, 'EXCEPTION: '.$@);
    }

    $result = 0;
  }

  return JSON::Schema::Draft201909::Result->new(
    output_format => $self->output_format,
    result => $result,
    errors => $state->{errors},
  );
}

sub _eval {
  my ($self, $data, $schema, $state) = @_;

  $state = { %$state };     # changes to $state should only affect subschemas, not parents
  delete $state->{keyword};

  abort($state, 'maximum traversal depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = $self->_get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  abort($state, 'unrecognized schema type "%s"', $schema_type) if $schema_type ne 'object';

  my $result = 1;

  foreach my $keyword (
    # CORE KEYWORDS
    qw($schema $id $anchor $ref $recursiveRef $recursiveAnchor $vocabulary $comment $defs),
    # VALIDATOR KEYWORDS
    qw(type enum const
      multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
      maxLength minLength pattern
      maxItems minItems uniqueItems
      maxProperties minProperties required dependentRequired),
    # APPLICATOR KEYWORDS
    qw(allOf anyOf oneOf not if dependentSchemas
      items unevaluatedItems contains
      properties patternProperties additionalProperties unevaluatedProperties propertyNames),
  ) {
    next if not exists $schema->{$keyword};

    $state->{keyword} = $keyword;
    my $method = '_eval_keyword_'.($keyword =~ s/^\$//r);
    abort($state, 'unsupported keyword "%s"', $keyword) if not $self->can($method);
    $result = 0 if not $self->$method($data, $schema, $state);

    return 0 if not $result and $state->{short_circuit};
  }

  return $result;
}

sub _eval_keyword_comment {
  my ($self, $data, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'string');
  # we do nothing with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_defs {
  my ($self, $data, $schema, $state) = @_;

  my $type = $self->_get_type($schema->{'$defs'});
  abort($state, '$defs value is not an object or boolean')
    if $type ne 'object' and $type ne 'boolean';

  # we do nothing directly with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_schema {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');
  abort($state, 'custom $schema references are not yet supported')
    if $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';

  return 1;
}

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$id'})->base($state->{base_uri})->to_abs;
  abort($state, '%s cannot have a non-empty fragment', $schema->{'$id'}) if length $uri->fragment;

  $state->{base_uri} = $uri;
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{absolute_schema_uri} = $uri->clone;
  $state->{schema_path} = '';

  return 1;
}

sub _eval_keyword_anchor {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  if ($schema->{'$anchor'} !~ /^[A-Za-z][A-Za-z0-9_:.-]+$/) {
    $self->_remove_resource($state->{base_uri}->clone->fragment($schema->{'$anchor'}));
    abort($state, '%s does not match required syntax', $schema->{'$anchor'});
  }

  # we already indexed this uri, so there is nothing more to do.
  # we explicitly do NOT set $state->{absolute_schema_uri}.
  return 1;
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$ref'})->base($state->{base_uri})->to_abs;

  my $fragment = $uri->fragment // '';
  my ($subschema, $absolute_uri);
  # TODO: this will get less ugly when we move to actual document objects
  if (not length($fragment) or $fragment =~ m{^/}) {
    my $base = $uri->clone->fragment(undef);
    my $document = Mojo::JSON::Pointer->new(($self->_get_resource($base) // {})->{ref});
    $subschema = $document->get($fragment);
    $absolute_uri = $uri;
  }
  else {
    if (my $resource = $self->_get_resource($uri)) {
      $subschema = $resource->{ref};
      $absolute_uri = $resource->{canonical_uri}->clone;  # this is *not* the anchor-containing URI
    }
  }

  abort($state, 'unable to find resource %s', $uri) if not defined $subschema;

  return $self->_eval($data, $subschema,
    +{ %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$ref',
      absolute_schema_uri => $absolute_uri,
      schema_path => '',
    });
}

sub _eval_keyword_type {
  my ($self, $data, $schema, $state) = @_;

  foreach my $type (ref $schema->{type} eq 'ARRAY' ? @{$schema->{type}} : $schema->{type}) {
    abort($state, 'unrecognized type "%s"', $type)
      if not any { $type eq $_ } qw(null boolean object array string number integer);
    return 1 if $self->_is_type($type, $data);
  }

  return E($state, 'wrong type (expected %s)',
    ref $schema->{type} eq 'ARRAY' ? ('one of '.join(', ', @{$schema->{type}})) : $schema->{type});
}

sub _eval_keyword_enum {
  my ($self, $data, $schema, $state) = @_;

  my @s; my $idx = 0;
  return 1 if any { $self->_is_equal($data, $_, $s[$idx++] = {}) } @{$schema->{enum}};

  return E($state, 'value does not match'
    .(!(grep $_->{path}, @s) ? ''
      : ' (differences start '.join(', ', map 'from #'.$_.' at "'.$s[$_]->{path}.'"', 0..$#s).')'));
}

sub _eval_keyword_const {
  my ($self, $data, $schema, $state) = @_;

  return 1 if $self->_is_equal($data, $schema->{const}, my $s = {});
  return E($state, 'value does not match'
    .($s->{path} ? ' (differences start at "'.$s->{path}.'")' : ''));
}

sub _eval_keyword_multipleOf {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');
  abort($state, '%s is not a positive number', $schema->{multipleOf}) if $schema->{multipleOf} <= 0;

  my $quotient = $data / $schema->{multipleOf};
  return 1 if int($quotient) == $quotient;
  return E($state, 'value is not a multiple of %d', $schema->{multipleOf});
}

sub _eval_keyword_maximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data <= $schema->{maximum};
  return E($state, 'value is larger than %d', $schema->{maximum});
}

sub _eval_keyword_exclusiveMaximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data < $schema->{exclusiveMaximum};
  return E($state, 'value is equal to or larger than %d', $schema->{exclusiveMaximum});
}

sub _eval_keyword_minimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data >= $schema->{minimum};
  return E($state, 'value is smaller than %d', $schema->{minimum});
}

sub _eval_keyword_exclusiveMinimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data > $schema->{exclusiveMinimum};
  return E($state, 'value is equal to or smaller than %d', $schema->{exclusiveMinimum});
}

sub _eval_keyword_maxLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{maxLength})
    if $schema->{maxLength} < 0;

  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

sub _eval_keyword_minLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{minLength})
    if $schema->{minLength} < 0;

  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _eval_keyword_pattern {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);

  return 1 if $data =~ qr/$schema->{pattern}/;
  return E($state, 'pattern does not match');
}

sub _eval_keyword_maxItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{maxItems})
    if $schema->{maxItems} < 0;

  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'more than %d items', $schema->{maxItems});
}

sub _eval_keyword_minItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{minItems})
    if $schema->{minItems} < 0;

  return 1 if @$data >= $schema->{minItems};
  return E($state, 'fewer than %d items', $schema->{minItems});
}

sub _eval_keyword_uniqueItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);
  assert_keyword_type($state, $schema, 'boolean');

  return 1 if not $schema->{uniqueItems};
  return 1 if $self->_is_elements_unique($data, my $equal_indices = []);
  return E($state, 'items at indices %d and %d are not unique', @$equal_indices);
}

sub _eval_keyword_maxProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{maxProperties})
    if $schema->{maxProperties} < 0;

  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'more than %d properties', $schema->{maxProperties});
}

sub _eval_keyword_minProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, '%s is not a non-negative integer', $schema->{minProperties})
    if $schema->{minProperties} < 0;

  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'fewer than %d properties', $schema->{minProperties});
}

sub _eval_keyword_required {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'array');
  abort($state, '"required" element is not a string')
    if any { !$self->_is_type('string', $_) } @{$schema->{required}};

  my @missing = grep !exists $data->{$_}, @{$schema->{required}};
  return 1 if not @missing;
  return E($state, 'missing propert'.(@missing > 1 ? 'ies' : 'y').': '.join(', ', @missing));
}

sub _eval_keyword_dependentRequired {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');
  abort($state, '"dependentRequired" property is not an array')
    if any { !$self->_is_type('array', $schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};
  abort($state, '"dependentRequired" property elements are not unique')
    if any { !$self->_is_elements_unique($schema->{dependentRequired}{$_}) }
      keys %{$schema->{dependentRequired}};

  my @missing = grep
    +(exists $data->{$_} && any { !exists $data->{$_} } @{ $schema->{dependentRequired}{$_} }),
    keys %{$schema->{dependentRequired}};

  return 1 if not @missing;
  return E($state, 'missing propert'.(@missing > 1 ? 'ies' : 'y').': '.join(', ', @missing));
}

sub _eval_keyword_allOf {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'array');
  abort($state, '"allOf" array is empty') if not @{$schema->{allOf}};

  my @invalid;
  foreach my $idx (0 .. $#{$schema->{allOf}}) {
    next if $self->_eval($data, $schema->{allOf}[$idx],
      +{ %$state, schema_path => $state->{schema_path}.'/allOf/'.$idx });

    push @invalid, $idx;
    last if $state->{short_circuit};
  }

  return 1 if @invalid == 0;
  my $pl = @invalid > 1;
  return E($state, 'subschema'.($pl?'s ':' ').join(', ', @invalid).($pl?' are':' is').' not valid');
}

sub _eval_keyword_anyOf {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'array');
  abort($state, '"anyOf" array is empty') if not @{$schema->{anyOf}};

  my $valid = 0;
  my @errors;
  foreach my $idx (0 .. $#{$schema->{anyOf}}) {
    next if not $self->_eval($data, $schema->{anyOf}[$idx],
      +{ %$state, errors => \@errors, schema_path => $state->{schema_path}.'/anyOf/'.$idx });
    ++$valid;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  push @{$state->{errors}}, @errors;
  return E($state, 'no subschemas are valid');
}

sub _eval_keyword_oneOf {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'array');
  abort($state, '"oneOf" array is empty') if not @{$schema->{oneOf}};

  my (@valid, @errors);
  foreach my $idx (0 .. $#{$schema->{oneOf}}) {
    push @valid, $idx if $self->_eval($data, $schema->{oneOf}[$idx],
      +{ %$state, errors => \@errors, schema_path => $state->{schema_path}.'/oneOf/'.$idx });
    last if @valid > 1 and $state->{short_circuit};
  }

  return 1 if @valid == 1;

  if (not @valid) {
    push @{$state->{errors}}, @errors;
    return E($state, 'no subschemas are valid');
  }
  else {
    return E($state, 'multiple subschemas are valid: '.join(', ', @valid));
  }
}

sub _eval_keyword_not {
  my ($self, $data, $schema, $state) = @_;
  return 1 if not $self->_eval($data, $schema->{not},
    +{ %$state, schema_path => $state->{schema_path}.'/not', short_circuit => 1, errors => [] });

  return E($state, 'subschema is valid');
}

sub _eval_keyword_if {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{then} and not exists $schema->{else};
  if ($self->_eval($data, $schema->{if},
      +{ %$state,
        schema_path => $state->{schema_path}.'/if',
        short_circuit => 1, # for now, until annotations are collected
        errors => [],
      })) {
    return 1 if not exists $schema->{then};
    return 1 if $self->_eval($data, $schema->{then},
      +{ %$state, schema_path => $state->{schema_path}.'/then' });
    return E({ %$state, keyword => 'then' }, 'subschema is not valid');
  }
  else {
    return 1 if not exists $schema->{else};
    return 1 if $self->_eval($data, $schema->{else},
      +{ %$state, schema_path => $state->{schema_path}.'/else' });
    return E({ %$state, keyword => 'else' }, 'subschema is not valid');
  }
}

sub _eval_keyword_dependentSchemas {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (keys %{$schema->{dependentSchemas}}) {
    next if not exists $data->{$property}
      or $self->_eval($data, $schema->{dependentSchemas}{$property},
        +{ %$state, schema_path => $state->{schema_path}.'/dependentSchemas/'.$property });

    $valid = 0;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all subschemas are valid');
}

sub _eval_keyword_items {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);

  if (ref $schema->{items} ne 'ARRAY') {
    my $valid = 1;
    foreach my $idx (0 .. $#{$data}) {
      next if $self->_eval($data->[$idx], $schema->{items},
        +{ %$state,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/items',
        });
      $valid = 0;
      last if $state->{short_circuit};
    }

    return 1 if $valid;
    return E($state, 'subschema is not valid against all items');
  }

  abort($state, '"items" array is empty') if not @{$schema->{items}};

  my $last_index = -1;
  my $valid = 1;
  foreach my $idx (0 .. $#{$data}) {
    last if $idx > $#{$schema->{items}};

    $last_index = $idx;
    next if $self->_eval($data->[$idx], $schema->{items}[$idx],
      +{ %$state,
        data_path => $state->{data_path}.'/'.$idx,
        schema_path => $state->{schema_path}.'/items/'.$idx,
      },
    );
    $valid = 0;
    last if $state->{short_circuit} and not exists $schema->{additionalItems};
  }

  E($state, 'a subschema is not valid') if not $valid;
  return $valid if not $valid or not exists $schema->{additionalItems} or $last_index == $#{$data};

  foreach my $idx ($last_index+1 .. $#{$data}) {
    next if $self->_eval($data->[$idx], $schema->{additionalItems},
      +{ %$state,
        data_path => $state->{data_path}.'/'.$idx,
        schema_path => $state->{schema_path}.'/additionalitems',
      });

    $valid = 0;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  return E({ %$state, keyword => 'additionalItems' }, 'subschema is not valid');
}

sub _eval_keyword_unevaluatedItems {
  my ($self, $data, $schema, $state) = @_;

  abort($state, '"unevaluatedItems" keyword present, but annotation collection is not supported');
}

sub _eval_keyword_contains {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);

  my $num_valid = 0;
  my @errors;
  foreach my $idx (0 .. $#{$data}) {
    if ($self->_eval($data->[$idx], $schema->{contains},
        +{ %$state,
          errors => \@errors,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/contains',
        })
    ) {
      ++$num_valid;
      last if $state->{short_circuit}
        and (not exists $schema->{maxContains} or $num_valid > $schema->{maxContains})
        and ($num_valid >= ($schema->{minContains} // 1));
    }
  }

  if (exists $schema->{minContains}) {
    local $state->{keyword} = 'minContains';
    assert_keyword_type($state, $schema, 'integer');
    abort($state, '%s is not a non-negative integer', $schema->{minContains})
      if $schema->{minContains} < 0;
  }

  my $valid = 1;
  # note: no items contained is only valid when minContains=0
  if (not $num_valid and ($schema->{minContains} // 1) > 0) {
    $valid = 0;
    push @{$state->{errors}}, @errors;
    E($state, 'subschema is not valid against any item');
    return 0 if $state->{short_circuit};
  }

  if (exists $schema->{maxContains}) {
    local $state->{keyword} = 'maxContains';
    assert_keyword_type($state, $schema, 'integer');
    abort($state, '%s is not a non-negative integer', $schema->{maxContains})
      if $schema->{maxContains} < 0;

    if ($num_valid > $schema->{maxContains}) {
      $valid = 0;
      E($state, 'contains too many matching items');
      return 0 if $state->{short_circuit};
    }
  }

  if ($num_valid < ($schema->{minContains} // 1)) {
    $valid = 0;
    E({ %$state, keyword => 'minContains' }, 'contains too few matching items');
    return 0 if $state->{short_circuit};
  }

  return $valid;
}

sub _eval_keyword_properties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (keys %{$schema->{properties}}) {
    next if not exists $data->{$property};
    $valid = 0 if not $self->_eval($data->{$property}, $schema->{properties}{$property},
        +{ %$state,
          data_path => $state->{data_path}.'/'.$property,
          schema_path => $state->{schema_path}.'/properties/'.$property,
        });
    last if not $valid and $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all properties are valid');
}

sub _eval_keyword_patternProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property_pattern (keys %{$schema->{patternProperties}}) {
    my @property_matches = grep /$property_pattern/, keys %$data;
    foreach my $property (@property_matches) {
      $valid = 0
        if not $self->_eval($data->{$property}, $schema->{patternProperties}{$property_pattern},
          +{ %$state,
            data_path => $state->{data_path}.'/'.$property,
            schema_path => $state->{schema_path}.'/patternProperties/'.$property_pattern,
          });
      last if not $valid and $state->{short_circuit};
    }
  }

  return 1 if $valid;
  return E($state, 'not all properties are valid');
}

sub _eval_keyword_additionalProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);

  my $valid = 1;
  foreach my $property (keys %$data) {
    next if exists $schema->{properties} and exists $schema->{properties}{$property};
    next if exists $schema->{patternProperties}
      and any { $property =~ /$_/ } keys %{$schema->{patternProperties}};

    if ($self->_is_type('boolean', $schema->{additionalProperties})) {
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$property },
        'additional property not permitted') if not $schema->{additionalProperties};
    }
    else {
      $valid = 0 if not $self->_eval($data->{$property}, $schema->{additionalProperties},
        +{ %$state,
          data_path => $state->{data_path}.'/'.$property,
          schema_path => $state->{schema_path}.'/additionalProperties',
        });
    }
    last if not $valid and $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all properties are valid');
}

sub _eval_keyword_unevaluatedProperties {
  my ($self, $data, $schema, $state) = @_;

  abort($state, '"unevaluatedProperties" keyword present, but annotation collection is not supported');
}

sub _eval_keyword_propertyNames {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);

  my $valid = 1;
  foreach my $property (keys %$data) {
    $valid = 0 if not $self->_eval($property, $schema->{propertyNames},
      +{ %$state,
        data_path => $state->{data_path}.'/'.$property,
        schema_path => $state->{schema_path}.'/propertyNames',
      });
    last if not $valid and $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all property names are valid');
}

sub _is_type {
  my (undef, $type, $value) = @_;

  if ($type eq 'null') {
    return !(defined $value);
  }
  if ($type eq 'boolean') {
    return is_bool($value);
  }
  if ($type eq 'object') {
    return ref $value eq 'HASH';
  }
  if ($type eq 'array') {
    return ref $value eq 'ARRAY';
  }

  if ($type eq 'string' or $type eq 'number' or $type eq 'integer') {
    return 0 if not defined $value or ref $value;
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
# use _is_type('integer') to differentiate numbers from integers.
sub _get_type {
  my ($self, $value) = @_;

  return 'null' if not defined $value;
  return 'object' if ref $value eq 'HASH';
  return 'array' if ref $value eq 'ARRAY';
  return 'boolean' if is_bool($value);

  if (not ref $value) {
    my $flags = B::svref_2object(\$value)->FLAGS;
    return 'string' if $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    return 'number' if !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
  }

  croak sprintf('ambiguous type for %s', $self->_json_decoder->encode($value));
}

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.4.2.3
sub _is_equal {
  my ($self, $x, $y, $state) = @_;
  $state->{path} //= '';

  my @types = map $self->_get_type($_), $x, $y;
  return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  return $x eq $y if $types[0] eq 'string';
  return $x == $y if $types[0] eq 'boolean' or $types[0] eq 'number';

  my $path = $state->{path};
  if ($types[0] eq 'object') {
    return 0 if keys %$x != keys %$y;
    return 0 if not $self->_is_equal([ sort keys %$x ], [ sort keys %$y ]);
    foreach my $property (keys %$x) {
      $state->{path} = $path.'/'.$property;
      return 0 if not $self->_is_equal($x->{$property}, $y->{$property}, $state);
    }
    return 1;
  }

  if ($types[0] eq 'array') {
    return 0 if @$x != @$y;
    foreach my $idx (0 .. $#{$x}) {
      $state->{path} = $path.'/'.$idx;
      return 0 if not $self->_is_equal($x->[$idx], $y->[$idx], $state);
    }
    return 1;
  }

  return 0; # should never get here
}

# checks array elements for uniqueness. short-circuits on first pair of matching elements
# if second arrayref is provided, it is populated with the indices of identical items
sub _is_elements_unique {
  my ($self, $array, $equal_indices) = @_;
  foreach my $idx0 (0 .. $#{$array}-1) {
    foreach my $idx1 ($idx0+1 .. $#{$array}) {
      if ($self->_is_equal($array->[$idx0], $array->[$idx1])) {
        push @$equal_indices, $idx0, $idx1 if defined $equal_indices;
        return 0;
      }
    }
  }
  return 1;
}

sub _traverse_for_identifiers {
  my ($data, $canonical_uri) = @_;
  my $uri_fragment = $canonical_uri->fragment // '';
  my %identifiers;
  if (ref $data eq 'ARRAY') {
    return map
      __SUB__->($data->[$_], $canonical_uri->clone->fragment($uri_fragment.'/'.$_)),
      0 .. $#{$data};
  }
  elsif (ref $data eq 'HASH') {
    if (exists $data->{'$id'} and _is_type(undef, 'string', $data->{'$id'})) {
      $canonical_uri = Mojo::URL->new($data->{'$id'})->base($canonical_uri)->to_abs;
      # this might not be a real $id... wait for it to be encountered at runtime before dying
      $identifiers{$canonical_uri} = { ref => $data, canonical_uri => $canonical_uri }
        if not length $canonical_uri->fragment;
    }
    if (exists $data->{'$anchor'} and _is_type(undef, 'string', $data->{'$anchor'})) {
      # we cannot change the canonical uri, or we won't be able to properly identify
      # paths within this resource
      my $uri = Mojo::URL->new->base($canonical_uri)->to_abs->fragment($data->{'$anchor'});
      $identifiers{$uri} = { ref => $data, canonical_uri => $canonical_uri };
    }

    return
      %identifiers,
      map __SUB__->($data->{$_}, $canonical_uri->clone->fragment($uri_fragment.'/'.$_)), keys %$data;
  }

  return ();
}

# traverse a schema document, find all identifiers and add them to the resource index.
# internal only and subject to change!
sub _find_all_identifiers {
  my ($self, $schema) = @_;

  my $base_uri = Mojo::URL->new;  # TODO: $self->base_uri->clone
  my %identifiers = _traverse_for_identifiers($schema, $base_uri);

  $identifiers{''} = { ref => $schema, canonical_uri => $base_uri }
    if not "$base_uri" and ref $schema eq 'HASH' and not exists $schema->{'$id'};

  $self->_add_resources(%identifiers);
}

# shorthand for creating error objects
use namespace::clean 'E';
sub E {
  my ($state, $error_string, @args) = @_;

  my $suffix = $state->{keyword} ? '/'.$state->{keyword} : '';
  push @{$state->{errors}}, JSON::Schema::Draft201909::Error->new(
    instance_location => $state->{data_path},
    keyword_location => $state->{traversed_schema_path}.$state->{schema_path}.$suffix,
    !$state->{absolute_schema_uri} ? () : ( absolute_keyword_location => do {
      my $abs = $state->{absolute_schema_uri}->clone;
      $abs->fragment(($abs->fragment//'').$state->{schema_path}.$suffix);
    } ),
    error => @args ? sprintf($error_string, @args) : $error_string,
  );

  return 0;
}

# creates an error object, but also aborts evaluation immediately
use namespace::clean 'abort';
sub abort {
  my ($state, $error_string, @args) = @_;
  E($state, 'EXCEPTION: '.$error_string, @args);
  die pop @{$state->{errors}};
}

# one common usecase of abort()
use namespace::clean 'assert_keyword_type';
sub assert_keyword_type {
  my ($state, $schema, $type) = @_;
  abort($state, $state->{keyword}.' value is not a%s %s', ($type =~ /^[aeiou]/ ? 'n' : ''), $type)
    if not _is_type(undef, $type, $schema->{$state->{keyword}});
}

1;
__END__

=pod

=for :header
=for stopwords schema subschema metaschema validator evaluator

=head1 SYNOPSIS

  use JSON::Schema::Draft201909;

  $js = JSON::Schema::Draft2019->new;
  $result = $js->evaluate($instance_data, $schema_data);

=head1 DESCRIPTION

This module aims to be a fully-compliant L<JSON Schema|https://json-schema.org/> evaluator and
validator, targeting the currently-latest
L<Draft 2019-09|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>
version of the specification.

=head1 CONFIGURATION OPTIONS

=head2 output_format

One of: C<flag>, C<basic>, C<detailed>, C<verbose>. Defaults to C<basic>. Passed to
L<JSON::Schema::Draft201909::Result/output_format>.

=head2 short_circuit

When true, evaluation will immediately return upon encountering the first validation failure, rather
than continuing to find all errors.

Defaults to true when C<output_format> is C<flag>, and false otherwise.

=head2 max_traversal_depth

The maximum number of levels deep a schema traversal may go, before evaluation is halted. This is to
protect against accidental infinite recursion, such as from two subschemas that each reference each
other. Defaults to 50.

=head1 METHODS

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://tools.ietf.org/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema is in the form of a Perl data structure, representing a JSON Schema
that respects the Draft 2019-09 meta-schema at L<https://json-schema.org/draft/2019-09/schema>.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows (null, boolean, string, number, object, array).

The schema is in the form of a Perl data structure, representing a JSON Schema
that respects the Draft 2019-09 meta-schema at L<https://json-schema.org/draft/2019-09/schema>.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 CAVEATS

=head3 TYPES

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value. However, if a value is
used in another context (for example, a numeric value is concatenated into a string, or a numeric
string is used in an arithmetic operation), additional flags can be added onto the variable causing
it to resemble the other type. This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.
If this turns out to be an issue in real environments, I may have to implement a C<lax_scalars>
option.

For more information, see L<Cpanel::JSON::XS/MAPPING>.

=head2 LIMITATIONS

Until version 1.000 is released, this implementation is not fully specification-compliant.

The minimum extensible JSON Schema implementation requirements involve:

=for :list
* identifying, organizing, and linking schemas (with keywords such as C<$ref>, C<$id>, C<$schema>,
  C<$anchor>, C<$defs>)
* providing an interface to evaluate assertions
* providing an interface to collect annotations
* applying subschemas to instances and combining assertion results and annotation data accordingly.
* support for all vocabularies required by the Draft 2019-09 metaschema,
  L<https://json-schema.org/draft/2019-09/schema>

To date, missing components include most of these. More specifically, features to be added include:

=for :list
* recognition of C<$id>
* loading multiple schema documents, and registration of a schema against a canonical base URI
* collection of annotations
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.7.7>)
* multiple output formats
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* use of C<$recursiveRef> and C<$recursiveAnchor>
* use of plain-name fragments with C<$anchor>

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<RFC8259|https://tools.ietf.org/html/rfc8259>
* L<Test::JSON::Schema::Acceptance>
* L<JSON::Validator>

=cut
