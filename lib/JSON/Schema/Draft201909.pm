use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.011';

no if "$]" >= 5.031009, feature => 'indirect';
use feature 'fc';
use JSON::MaybeXS 1.004001 'is_bool';
use Syntax::Keyword::Try 0.11;
use Carp qw(croak carp);
use List::Util 1.55 qw(any pairs first uniqint);
use Ref::Util 0.100 qw(is_ref is_plain_arrayref is_plain_hashref is_plain_coderef);
use Mojo::JSON::Pointer;
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use Moo;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef);
use JSON::Schema::Draft201909::Error;
use JSON::Schema::Draft201909::Result;
use JSON::Schema::Draft201909::Document;
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

has validate_formats => (
  is => 'ro',
  isa => Bool,
  default => 0, # as specified by https://json-schema.org/draft/2019-09/schema#/$vocabulary
);

sub BUILD {
  my ($self, $args) = @_;

  if (exists $args->{format_validations}) {
    croak 'format_validations must be a hashref'
      if not is_plain_hashref($args->{format_validations});

    foreach my $format (keys %{$args->{format_validations}}) {
      if (my $existing = $self->_get_format_validation($format)) {
        croak 'overrides to existing format_validations must be coderefs'
          if not is_plain_coderef($args->{format_validations}{$format});
        $self->_set_format_validation($format,
          +{ type => $existing->{type}, sub => $args->{format_validations}{$format} });
      }
      else {
        my $type = Dict[type => Enum[qw(null object array boolean string number integer)], sub => CodeRef];
        croak $type->get_message($args->{format_validations}{$format})
          if not $type->check($args->{format_validations}{$format});

        $self->_set_format_validation($format => $args->{format_validations}{$format});
      }
    }
  }
}

sub add_schema {
  my $self = shift;
  die 'insufficient arguments' if @_ < 1;

  my $uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $uri->fragment;

  if (not @_) {
    # TODO: resolve $uri against $self->base_uri
    my ($schema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
    return if not defined $schema or not defined wantarray;
    return $self->_get_resource($canonical_uri->fragment(undef))->{document};
  }

  my $document = $_[0]->$_isa('JSON::Schema::Draft201909::Document') ? shift
    : JSON::Schema::Draft201909::Document->new(schema => shift, $uri ? (canonical_uri => $uri) : ());

  if (not grep $_->{document} == $document, $self->_resource_values) {
    my $schema_content = $document->serialized_schema
      // $document->serialized_schema($self->_json_decoder->encode($document->schema));

    if (my $existing_doc = first {
          my $existing_content = $_->serialized_schema
            // $_->serialized_schema($self->_json_decoder->encode($_->schema));
          $existing_content eq $schema_content
        } uniqint map $_->{document}, $self->_resource_values) {
      # we already have this schema content in another document object.
      $document = $existing_doc;
    }
    else {
      $self->_add_resources(map +($_->[0] => +{ %{$_->[1]}, document => $document }),
        $document->_resource_pairs);
    }
  }

  if ("$uri") {
    $document->_add_resources($uri, { path => '', canonical_uri => $document->canonical_uri });
    $self->_add_resources($uri => { path => '', canonical_uri => $document->canonical_uri, document => $document });
  }

  return $document;
}

sub evaluate_json_string {
  my ($self, $json_data, $schema) = @_;
  die 'insufficient arguments' if @_ < 3;

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
  my ($self, $data, $schema_reference) = @_;
  die 'insufficient arguments' if @_ < 3;

  my $base_uri = Mojo::URL->new;  # TODO: will be set by a global attribute

  my $state = {
    short_circuit => $self->short_circuit,
    depth => 0,
    data_path => '',
    traversed_schema_path => '',        # the accumulated path up to the last $ref traversal
    canonical_schema_uri => $base_uri,  # the canonical path of the last traversed $ref
    schema_path => '',                  # the rest of the path, since the last traversed $ref
    errors => [],
  };

  my $result;
  try {
    my ($schema, $canonical_uri);

    if (not is_ref($schema_reference) or $schema_reference->$_isa('Mojo::URL')) {
      # TODO: resolve $uri against base_uri
      ($schema, $canonical_uri) = $self->_fetch_schema_from_uri($schema_reference);
    }
    else {
      my $document = $self->add_schema($schema_reference);
      ($schema, $canonical_uri) = map $document->$_, qw(schema canonical_uri);
    }

    abort($state, 'unable to find resource %s', $schema_reference) if not defined $schema;

    $state->{canonical_schema_uri} = $canonical_uri;
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

sub get {
  my ($self, $uri) = @_;
  die 'insufficient arguments' if @_ < 2;

  my ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
  $subschema = dclone($subschema) if is_ref($subschema);
  return !defined $subschema ? () : wantarray ? ($subschema, $canonical_uri) : $subschema;
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

sub _eval {
  my ($self, $data, $schema, $state) = @_;

  $state = { %$state };     # changes to $state should only affect subschemas, not parents
  delete $state->{keyword};

  abort($state, 'maximum traversal depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = $self->_get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  my $result = 1;

  foreach my $keyword (
    # CORE KEYWORDS
    qw($id $schema $anchor $recursiveAnchor $ref $recursiveRef $vocabulary $comment $defs),
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
    # FORMAT VOCABULARY
    qw(format),
    # DISCONTINUED KEYWORDS
    qw(definitions dependencies),
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

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$id'});
  $uri = $uri->base($state->{canonical_schema_uri})->to_abs if not $uri->is_abs;
  abort($state, '$id value "%s" cannot have a non-empty fragment', $schema->{'$id'})
    if length $uri->fragment;

  $uri->fragment(undef);
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{canonical_schema_uri} = $uri;
  $state->{schema_path} = '';

  return 1;
}

sub _eval_keyword_schema {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  abort($state, '$schema can only appear at the schema resource root')
    if length($state->{schema_path});

  abort($state, 'custom $schema references are not yet supported')
    if $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';

  return 1;
}

sub _eval_keyword_anchor {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  if ($schema->{'$anchor'} !~ /^[A-Za-z][A-Za-z0-9_:.-]+$/) {
    abort($state, '$anchor value "%s" does not match required syntax', $schema->{'$anchor'});
  }

  # we already indexed this uri, so there is nothing more to do.
  # we explicitly do NOT set $state->{canonical_schema_uri}.
  return 1;
}

sub _eval_keyword_recursiveAnchor {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'boolean');
  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  my $uri = $state->{canonical_schema_uri} ? $state->{canonical_schema_uri}->clone : Mojo::URL->new;
  abort($state, '"$recursiveAnchor" keyword used without "$id"') if length $uri->fragment;

  $state->{recursive_anchor_uri} = $uri;
  return 1;
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$ref'});
  $uri = $uri->base($state->{canonical_schema_uri})->to_abs if not $uri->is_abs;
  my ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
  abort($state, 'unable to find resource %s', $uri) if not defined $subschema;

  return $self->_eval($data, $subschema,
    +{ %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$ref',
      canonical_schema_uri => $canonical_uri, # note: maybe not canonical yet until $id is processed
      schema_path => '',
    });
}

sub _eval_keyword_recursiveRef {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $target_uri = Mojo::URL->new($schema->{'$recursiveRef'});
  $target_uri = $target_uri->base($state->{canonical_schema_uri})->to_abs if not $target_uri->is_abs;
  my ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($target_uri);
  abort($state, 'unable to find resource %s', $target_uri) if not defined $subschema;

  if ($self->_is_type('boolean', $subschema->{'$recursiveAnchor'})
      and $subschema->{'$recursiveAnchor'}) {
    my $uri = Mojo::URL->new($schema->{'$recursiveRef'});
    my $base = $state->{recursive_anchor_uri} // $state->{canonical_schema_uri};
    $uri = $uri->base($base)->to_abs if not $uri->is_abs;

    abort($state, 'cannot resolve a $recursiveRef with a non-empty fragment against a $recursiveAnchor location with a canonical URI containing a fragment')
      if $schema->{'$recursiveRef'} ne '#' and length $base->fragment;

    ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
    abort($state, 'unable to find resource %s', $uri) if not defined $subschema;
  }

  return $self->_eval($data, $subschema,
    +{ %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$recursiveRef',
      canonical_schema_uri => $canonical_uri, # note: maybe not canonical yet until $id is processed
      schema_path => '',
    });
}

sub _eval_keyword_vocabulary {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'object');

  # we do nothing with this keyword yet. When we know we are in a metaschema,
  # we can scan the URIs included here and either abort if a vocabulary is enabled that we do not
  # understand, or turn on and off certain keyword behaviours based on the boolean values seen.

  return 1;
}

sub _eval_keyword_comment {
  my ($self, $data, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'string');
  # we do nothing with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_defs {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'object');

  # we do nothing directly with this keyword, including not collecting its value for annotations.
  return 1;
}

sub _eval_keyword_type {
  my ($self, $data, $schema, $state) = @_;

  foreach my $type (is_plain_arrayref($schema->{type}) ? @{$schema->{type}} : $schema->{type}) {
    abort($state, 'unrecognized type "%s"', $type)
      if not any { $type eq $_ } qw(null boolean object array string number integer);
    return 1 if $self->_is_type($type, $data);
  }

  return E($state, 'wrong type (expected %s)',
    is_plain_arrayref($schema->{type}) ? ('one of '.join(', ', @{$schema->{type}})) : $schema->{type});
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
  abort($state, 'multipleOf value is not a positive number') if $schema->{multipleOf} <= 0;

  my $quotient = $data / $schema->{multipleOf};
  return 1 if int($quotient) == $quotient;
  return E($state, 'value is not a multiple of %g', $schema->{multipleOf});
}

sub _eval_keyword_maximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data <= $schema->{maximum};
  return E($state, 'value is larger than %g', $schema->{maximum});
}

sub _eval_keyword_exclusiveMaximum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data < $schema->{exclusiveMaximum};
  return E($state, 'value is equal to or larger than %g', $schema->{exclusiveMaximum});
}

sub _eval_keyword_minimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data >= $schema->{minimum};
  return E($state, 'value is smaller than %g', $schema->{minimum});
}

sub _eval_keyword_exclusiveMinimum {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('number', $data);
  assert_keyword_type($state, $schema, 'number');

  return 1 if $data > $schema->{exclusiveMinimum};
  return E($state, 'value is equal to or smaller than %g', $schema->{exclusiveMinimum});
}

sub _eval_keyword_maxLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'maxLength value is not a non-negative integer') if $schema->{maxLength} < 0;

  return 1 if length($data) <= $schema->{maxLength};
  return E($state, 'length is greater than %d', $schema->{maxLength});
}

sub _eval_keyword_minLength {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minLength value is not a non-negative integer') if $schema->{minLength} < 0;

  return 1 if length($data) >= $schema->{minLength};
  return E($state, 'length is less than %d', $schema->{minLength});
}

sub _eval_keyword_pattern {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('string', $data);
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

  return 1 if not $self->_is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'maxItems value is not a non-negative integer') if $schema->{maxItems} < 0;

  return 1 if @$data <= $schema->{maxItems};
  return E($state, 'more than %d item%s', $schema->{maxItems}, $schema->{maxItems} > 1 ? 's' : '');
}

sub _eval_keyword_minItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minItems value is not a non-negative integer') if $schema->{minItems} < 0;

  return 1 if @$data >= $schema->{minItems};
  return E($state, 'fewer than %d item%s', $schema->{minItems}, $schema->{minItems} > 1 ? 's' : '');
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
  abort($state, 'maxProperties value is not a non-negative integer')
    if $schema->{maxProperties} < 0;

  return 1 if keys %$data <= $schema->{maxProperties};
  return E($state, 'more than %d propert%s', $schema->{maxProperties},
    $schema->{maxProperties} > 1 ? 'ies' : 'y');
}

sub _eval_keyword_minProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'integer');
  abort($state, 'minProperties value is not a non-negative integer')
    if $schema->{minProperties} < 0;

  return 1 if keys %$data >= $schema->{minProperties};
  return E($state, 'fewer than %d propert%s', $schema->{minProperties},
    $schema->{minProperties} > 1 ? 'ies' : 'y');
}

sub _eval_keyword_required {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'array');
  abort($state, '"required" element is not a string')
    if any { !$self->_is_type('string', $_) } @{$schema->{required}};

  my @missing = grep !exists $data->{$_}, @{$schema->{required}};
  return 1 if not @missing;
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
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
  return E($state, 'missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', sort @missing));
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
  return E($state, 'subschema%s %s %s not valid', $pl?'s':'', join(', ', @invalid), $pl?'are':'is');
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
  my $keyword = $self->_eval($data, $schema->{if},
      +{ %$state,
        schema_path => $state->{schema_path}.'/if',
        short_circuit => 1, # for now, until annotations are collected
        errors => [],
      })
    ? 'then' : 'else';

  return 1 if not exists $schema->{$keyword};
  return 1 if $self->_eval($data, $schema->{$keyword},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$keyword });
  return E({ %$state, keyword => $keyword }, 'subschema is not valid');
}

sub _eval_keyword_dependentSchemas {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('object', $data);
  assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys %{$schema->{dependentSchemas}}) {
    next if not exists $data->{$property}
      or $self->_eval($data, $schema->{dependentSchemas}{$property},
        +{ %$state, schema_path => jsonp($state->{schema_path}, 'dependentSchemas', $property) });

    $valid = 0;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all subschemas are valid');
}

sub _eval_keyword_items {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->_is_type('array', $data);

  if (not is_plain_arrayref($schema->{items})) {
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
      });
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
        })) {
      ++$num_valid;
      last if $state->{short_circuit}
        and (not exists $schema->{maxContains} or $num_valid > $schema->{maxContains})
        and ($num_valid >= ($schema->{minContains} // 1));
    }
  }

  if (exists $schema->{minContains}) {
    local $state->{keyword} = 'minContains';
    assert_keyword_type($state, $schema, 'integer');
    abort($state, 'minContains value is not a non-negative integer') if $schema->{minContains} < 0;
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
    abort($state, 'maxContains value is not a non-negative integer') if $schema->{maxContains} < 0;

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
  foreach my $property (sort keys %{$schema->{properties}}) {
    next if not exists $data->{$property};
    $valid = 0 if not $self->_eval($data->{$property}, $schema->{properties}{$property},
        +{ %$state,
          data_path => jsonp($state->{data_path}, $property),
          schema_path => jsonp($state->{schema_path}, 'properties', $property),
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
  foreach my $property_pattern (sort keys %{$schema->{patternProperties}}) {
    my @matched_properties;
    try {
      @matched_properties = grep m/$property_pattern/, keys %$data;
    }
    catch {
      abort({ %$state,
        _schema_path_rest => jsonp($state->{schema_path}, 'patternProperties', $property_pattern) },
      $@);
    };
    foreach my $property (sort @matched_properties) {
      $valid = 0
        if not $self->_eval($data->{$property}, $schema->{patternProperties}{$property_pattern},
          +{ %$state,
            data_path => jsonp($state->{data_path}, $property),
            schema_path => jsonp($state->{schema_path}, 'patternProperties', $property_pattern),
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
  foreach my $property (sort keys %$data) {
    next if exists $schema->{properties} and exists $schema->{properties}{$property};
    next if exists $schema->{patternProperties}
      and any { $property =~ /$_/ } keys %{$schema->{patternProperties}};

    if ($self->_is_type('boolean', $schema->{additionalProperties})) {
      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property) },
        'additional property not permitted') if not $schema->{additionalProperties};
    }
    else {
      $valid = 0 if not $self->_eval($data->{$property}, $schema->{additionalProperties},
        +{ %$state,
          data_path => jsonp($state->{data_path}, $property),
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
  foreach my $property (sort keys %$data) {
    $valid = 0 if not $self->_eval($property, $schema->{propertyNames},
      +{ %$state,
        data_path => jsonp($state->{data_path}, $property),
        schema_path => $state->{schema_path}.'/propertyNames',
      });
    last if not $valid and $state->{short_circuit};
  }

  return 1 if $valid;
  return E($state, 'not all property names are valid');
}

has _format_validations => (
  is => 'bare',
  isa => HashRef[Dict[
      type => Enum[qw(null object array boolean string number integer)],
      sub => CodeRef,
    ]],
  handles_via => 'Hash',
  handles => {
    _get_format_validation => 'get',
    _set_format_validation => 'set',
  },
  lazy => 1,
  default => sub {
    my $is_datetime = sub {
      eval { require Time::Moment; 1 } or return 1;
      eval { Time::Moment->from_string($_[0]) } ? 1 : 0,
    };
    my $is_email = sub {
      eval { require Email::Address::XS; Email::Address::XS->VERSION(1.01); 1 } or return 1;
      Email::Address::XS->parse($_[0])->is_valid;
    };
    my $is_hostname = sub {
      eval { require Data::Validate::Domain; 1 } or return 1;
      Data::Validate::Domain::is_domain($_[0]);
    };
    my $idn_decode = sub {
      eval { require Net::IDN::Encode; 1 } or return $_[0];
      try { return Net::IDN::Encode::domain_to_ascii($_[0]) } catch { return $_[0]; }
    };
    my $is_ipv4 = sub {
      my @o = split(/\./, $_[0], 5);
      @o == 4 && (grep /^[0-9]{1,3}$/, @o) == 4 && (grep $_ < 256, @o) == 4;
    };
    # https://tools.ietf.org/html/rfc3339#appendix-A with some additions for the 2000 version
    my $duration_re = do {
      my $num = qr{[0-9]+(?:[.,][0-9]+)?};
      my $second = qr{${num}S};
      my $minute = qr{${num}M};
      my $hour = qr{${num}H};
      my $time = qr{T(?=[0-9])(?:$hour)?(?:$minute)?(?:$second)?};
      my $day = qr{${num}D};
      my $month = qr{${num}M};
      my $year = qr{${num}Y};
      my $week = qr{${num}W};
      my $date = qr{(?=[0-9])(?:$year)?(?:$month)?(?:$day)?};
      qr{^P(?:(?=.)(?:$date)?(?:$time)?|$week)$};
    };

    +{
      'date-time' => { type => 'string', sub => $is_datetime },
      date => { type => 'string', sub => sub { $is_datetime->($_[0].'T00:00:00Z') } },
      time => { type => 'string', sub => sub { $is_datetime->('2000-01-01T'.$_[0]) } },
      duration => { type => 'string', sub => sub {
        $_[0] =~ $duration_re && $_[0] !~ m{[.,][0-9]+[A-Z].};
      } },
      email => { type => 'string', sub => sub { $is_email->($_[0]) && $_[0] !~ /[^[:ascii:]]/ } },
      'idn-email' => { type => 'string', sub => $is_email },
      hostname => { type => 'string', sub => $is_hostname },
      'idn-hostname' => { type => 'string', sub => sub { $is_hostname->($idn_decode->($_[0])) } },
      ipv4 => { type => 'string', sub => $is_ipv4 },
      ipv6 => { type => 'string', sub => sub {
        ($_[0] =~ /^(?:[[:xdigit:]]{0,4}:){0,7}[[:xdigit:]]{0,4}$/
          || $_[0] =~ /^(?:[[:xdigit:]]{0,4}:){1,6}((?:[0-9]{1,3}\.){3}[0-9]{1,3})$/
              && $is_ipv4->($1))
          && $_[0] !~ /:::/
          && $_[0] !~ /^:[^:]/
          && $_[0] !~ /[^:]:$/
          && do {
            my $double_colons = ()= ($_[0] =~ /::/g);
            my $colon_components = grep length, split(/:+/, $_[0], -1);
            $double_colons < 2 && ($double_colons > 0
              || ($colon_components == 8 && !defined $1)
              || ($colon_components == 7 && defined $1))
          };
      } },
      uri => { type => 'string', sub => sub {
        my $uri = Mojo::URL->new($_[0]);
        fc($uri->to_unsafe_string) eq fc($_[0]) && $uri->is_abs && $_[0] !~ /[^[:ascii:]]/;
      } },
      'uri-reference' => { type => 'string', sub => sub {
        fc(Mojo::URL->new($_[0])->to_unsafe_string) eq fc($_[0]) && $_[0] !~ /[^[:ascii:]]/;
      } },
      iri => { type => 'string', sub => sub { Mojo::URL->new($_[0])->is_abs } },
      'iri-reference' => { type => 'string', sub => sub { 1 } },
      uuid => { type => 'string', sub => sub {
        $_[0] =~ /^[[:xdigit:]]{8}-(?:[[:xdigit:]]{4}-){3}[[:xdigit:]]{12}$/;
      } },
      'uri-template' => { type => 'string', sub => sub { 1 } },
      'json-pointer' => { type => 'string', sub => sub {
        (!length($_[0]) || $_[0] =~ m{^/}) && $_[0] !~ m{~(?![01])};
      } },
      'relative-json-pointer' => { type => 'string', sub => sub {
        $_[0] =~ m{^[0-9]+(?:#$|$|/)} && $_[0] !~ m{~(?![01])};
      } },
      regex => { type => 'string', sub => sub { eval { qr/$_[0]/; 1 } ? 1 : 0 } },
    }
  },
);

sub _eval_keyword_format {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  if ($self->validate_formats and my $spec = $self->_get_format_validation($schema->{format})) {
    return E($state, 'not a%s %s', $schema->{format} =~ /^[aeio]/ ? 'n' : '', $schema->{format})
      if $self->_is_type($spec->{type}, $data) and not $spec->{sub}->($data);
  }

  # TODO: create annotation
  return 1;
}

sub _eval_keyword_definitions {
  carp 'no-longer-supported "definitions" keyword present: this should be rewritten as "$defs"';
  return 1;
}

sub _eval_keyword_dependencies {
  carp 'no-longer-supported "dependencies" keyword present: this should be rewritten as "dependentSchemas" or "dependentRequired"';
  return 1;
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
# use _is_type('integer') to differentiate numbers from integers.
sub _get_type {
  my ($self, $value) = @_;

  return 'null' if not defined $value;
  return 'object' if is_plain_hashref($value);
  return 'array' if is_plain_arrayref($value);
  return 'boolean' if is_bool($value);

  croak sprintf('unsupported reference type %s', ref $value) if is_ref($value);

  my $flags = B::svref_2object(\$value)->FLAGS;
  return 'string' if $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
  return 'number' if !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));

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
      $state->{path} = jsonp($path, $property);
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

has _resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,
      document => InstanceOf['JSON::Schema::Draft201909::Document'],
    ]],
  handles_via => 'Hash',
  handles => {
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _resource_index => 'elements',
    _resource_keys => 'keys',
    _add_resources_unsafe => 'set',
    _resource_values => 'values',
  },
  lazy => 1,
  default => sub { {} },
);


around _add_resources => sub {
  my ($orig, $self) = (shift, shift);

  my @resources;
  foreach my $pair (sort { $a->[0] cmp $b->[0] } pairs @_) {
    my ($key, $value) = @$pair;
    if (my $existing = $self->_get_resource($key)) {
      if ($key eq '') {
        # we allow overwriting canonical_uri = '' to allow for ad hoc evaluation of schemas that
        # lack all identifiers altogether; we drop *all* resources from that document
        $self->_remove_resource(
          grep $self->_get_resource($_)->{document} == $existing->{document}, $self->_resource_keys);
      }
      else {
        next if $existing->{path} eq $value->{path}
          and $existing->{canonical_uri} eq $value->{canonical_uri}
          and $existing->{document} == $value->{document};
        croak 'uri "'.$key.'" conflicts with an existing schema resource';
      }
    }
    elsif ($self->CACHED_METASCHEMAS->{$key}) {
      croak 'uri "'.$key.'" conflicts with an existing meta-schema resource';
    }

    my $fragment = $value->{canonical_uri}->fragment;
    croak sprintf('canonical_uri cannot contain an empty fragment (%s)', $value->{canonical_uri})
      if defined $fragment and $fragment eq '';

    croak sprintf('canonical_uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($fragment // '') =~ m{^[^/]};

    push @resources, $key => $value;
  }

  $self->$orig(@resources) if @resources;
};

use constant CACHED_METASCHEMAS => {
  'https://json-schema.org/draft/2019-09/hyper-schema'        => '2019-09/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/links'               => '2019-09/links.json',
  'https://json-schema.org/draft/2019-09/meta/applicator'     => '2019-09/meta/applicator.json',
  'https://json-schema.org/draft/2019-09/meta/content'        => '2019-09/meta/content.json',
  'https://json-schema.org/draft/2019-09/meta/core'           => '2019-09/meta/core.json',
  'https://json-schema.org/draft/2019-09/meta/format'         => '2019-09/meta/format.json',
  'https://json-schema.org/draft/2019-09/meta/hyper-schema'   => '2019-09/meta/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/meta/meta-data'      => '2019-09/meta/meta-data.json',
  'https://json-schema.org/draft/2019-09/meta/validation'     => '2019-09/meta/validation.json',
  'https://json-schema.org/draft/2019-09/output/hyper-schema' => '2019-09/output/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/output/schema'       => '2019-09/output/schema.json',
  'https://json-schema.org/draft/2019-09/schema'              => '2019-09/schema.json',
};

# returns the same as _get_resource
sub _get_or_load_resource {
  my ($self, $uri) = @_;

  my $resource = $self->_get_resource($uri);
  return $resource if $resource;

  if (my $local_filename = $self->CACHED_METASCHEMAS->{$uri}) {
    my $file = path(dist_dir('JSON-Schema-Draft201909'), $local_filename);
    my $schema = $self->_json_decoder->decode($file->slurp_raw);
    my $document = JSON::Schema::Draft201909::Document->new(schema => $schema);

    # we have already performed the appropriate collision checks, so we bypass them here
    $self->_add_resources_unsafe(
      map +($_->[0] => +{ %{$_->[1]}, document => $document }),
        $document->_resource_pairs
    );

    return $self->_get_resource($uri);
  }

  # TODO:
  # - load from network or disk
  # - handle such resources with $anchor fragments

  return;
};

# returns a schema (which may not be at a document root), and the canonical uri for that schema.
# creates a Document and adds it to the resource index, if not already present.
sub _fetch_schema_from_uri {
  my ($self, $uri) = @_;

  $uri = Mojo::URL->new($uri) if not is_ref($uri);
  my $fragment = $uri->fragment // '';

  my ($subschema, $canonical_uri);
  if (not length($fragment) or $fragment =~ m{^/}) {
    my $base = $uri->clone->fragment(undef);
    if (my $resource = $self->_get_or_load_resource($base)) {
      $subschema = $resource->{document}->get($resource->{path}.$fragment);
      $canonical_uri = $resource->{canonical_uri}->clone->fragment($uri->fragment);
    }
  }
  else {
    if (my $resource = $self->_get_resource($uri)) {
      $subschema = $resource->{document}->get($resource->{path});
      $canonical_uri = $resource->{canonical_uri}->clone; # this is *not* the anchor-containing URI
    }
  }

  return defined $subschema && $canonical_uri ? ($subschema, $canonical_uri) : ();
}

has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 1) },
);

# shorthand for creating and appending json pointers
use namespace::clean 'jsonp';
sub jsonp {
  return join('/', shift, map s/~/~0/gr =~ s!/!~1!gr, @_);
}

# shorthand for creating error objects
use namespace::clean 'E';
sub E {
  my ($state, $error_string, @args) = @_;

  # sometimes the keyword shouldn't be at the very end of the schema path
  my $schema_path = delete $state->{_schema_path_rest}
    // $state->{schema_path}.($state->{keyword} ? '/'.$state->{keyword} : '');

  push @{$state->{errors}}, JSON::Schema::Draft201909::Error->new(
    instance_location => $state->{data_path},
    keyword_location => $state->{traversed_schema_path}.$schema_path,
    !"$state->{canonical_schema_uri}" ? () : ( absolute_keyword_location => do {
      my $uri = $state->{canonical_schema_uri}->clone;
      $uri->fragment(($uri->fragment//'').$schema_path) if $schema_path;
      $uri;
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

  $js = JSON::Schema::Draft2019->new(
    output_format => 'flag',
    ... # other options
  );
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

When true, evaluation will return early in any execution path as soon as the outcome can be
determined, rather than continuing to find all possible errors.

Defaults to true when C<output_format> is C<flag>, and false otherwise.

=head2 max_traversal_depth

The maximum number of levels deep a schema traversal may go, before evaluation is halted. This is to
protect against accidental infinite recursion, such as from two subschemas that each reference each
other. Defaults to 50.

=head2 validate_formats

When true, the C<format> keyword will be treated as an assertion, not merely an annotation. Defaults
to false.

=head2 format_validations

An optional hashref that allows overriding the validation method for formats, or adding new ones.
Overrides to existing formats (see L</Format Validation>)
must be specified in the form of C<< { $format_name => $format_sub } >>, where
the format sub is a coderef that takes one argument and returns a boolean result. New formats must
be specified in the form of C<< { $format_name => { type => $type, sub => $format_sub } } >>,
where the type indicates which of the core JSON Schema types (null, object, array, boolean, string,
number, or integer) the instance value must be for the format validation to be considered.

=head1 METHODS

=for Pod::Coverage BUILD

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://tools.ietf.org/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema must represent a JSON Schema that respects the Draft 2019-09 meta-schema at
L<https://json-schema.org/draft/2019-09/schema>, in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Draft201909::Document> object,
* or a URI string indicating the location where such a schema is located.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema_data);

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows (null, boolean, string, number, object, array).

The schema must represent a JSON Schema that respects the Draft 2019-09 meta-schema at
L<https://json-schema.org/draft/2019-09/schema>, in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Draft201909::Document> object,
* or a URI string indicating the location where such a schema is located.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 add_schema

  $js->add_schema($uri => $schema);
  $js->add_schema($uri => $document);
  $js->add_schema($schema);
  $js->add_schema($document);

Introduces the (unblessed, nested) Perl data structure or L<JSON::Schema::Draft201909::Document>
object, representing a JSON Schema, to the implementation, registering it under the indicated URI if
provided (and if not, C<''> will be used if no other identifier can be found within).

You B<MUST> call C<add_schema> for any external resources that a schema may reference via C<$ref>
before calling L</evaluate>, other than the standard metaschemas which are loaded from a local cache
as needed.

=head2 get

  my $schema = $js->get($uri);
  my ($schema, $canonical_uri) = $js->get($uri);

Fetches the Perl data structure representing the JSON Schema at the indicated URI. When called in
list context, the canonical URI of that location is also returned, as a L<Mojo::URL>. Returns
C<undef> if the schema with that URI has not been loaded (or cached).

=head1 LIMITATIONS

=head2 Types

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value. However, if a value is
used in another context (for example, a numeric value is concatenated into a string, or a numeric
string is used in an arithmetic operation), additional flags can be added onto the variable causing
it to resemble the other type. This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.
If this turns out to be an issue in real environments, I may have to implement a C<lax_scalars>
option.

For more information, see L<Cpanel::JSON::XS/MAPPING>.

=head2 Format Validation

By default, formats are treated only as annotations, not assertions. When L</validate_format> is
true, strings are also checked against the format as specified in the schema. At present the
following formats are supported (use of any other formats than these will evaluate as true):

=for :list
* C<date-time>
* C<date>
* C<time>
* C<duration>
* C<email>
* C<idn-email>
* C<hostname>
* C<idn-hostname>
* C<ipv4>
* C<ipv6>
* C<uri>
* C<uri-reference>
* C<iri>
* C<uuid>
* C<json-pointer>
* C<relative-json-pointer>
* C<regex>

A few optional prerequisites are needed for some of these (if the prerequisite is missing,
validation will always succeed):

=for :list
* C<date-time>, C<date>, and C<time> require L<Time::Moment>
* C<email> and C<idn-email> require L<Email::Address::XS> version 1.01
* C<hostname> and C<idn-hostname> require L<Data::Validate::Domain>
* C<idn-hostname> requires L<Net::IDN::Encode>

=head2 Specification Compliance

Until version 1.000 is released, this implementation is not fully specification-compliant.

To date, missing components (some of which are optional, but still quite useful) include:

=for :list
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* multiple output formats
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* annotation collection (including the "format", "meta-data" and "content" vocabularies)
* examination of the C<$schema> keyword for deviation from the standard metaschema, including
  changes to vocabulary behaviour

=head1 SECURITY CONSIDERATIONS

The C<pattern> and C<patternProperties> keywords, and the C<regex> format validator,
evaluate regular expressions from the schema.
No effort is taken (at this time) to sanitize the regular expressions for embedded code or
potentially pathological constructs that may pose a security risk, either via denial of service
or by allowing exposure to the internals of your application. B<DO NOT USE SCHEMAS FROM UNTRUSTED
SOURCES.>

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://tools.ietf.org/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://tools.ietf.org/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>

=cut
