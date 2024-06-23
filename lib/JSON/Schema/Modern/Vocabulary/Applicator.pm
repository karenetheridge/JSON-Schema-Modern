use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Applicator;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Applicator vocabulary

our $VERSION = '0.587';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 0.026 qw(signatures args_array_with_signatures);
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use List::Util 1.45 qw(any uniqstr);
use Ref::Util 0.100 'is_plain_arrayref';
use Sub::Install;
use JSON::Schema::Modern::Utilities qw(is_type jsonp E A assert_keyword_type assert_pattern true is_elements_unique);
use JSON::Schema::Modern::Vocabulary::Unevaluated;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/applicator' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/applicator' => 'draft2020-12';
}

sub evaluation_order { 3 }

# the keyword order is arbitrary, except:
# - if must be evaluated before then, else
# - items must be evaluated before additionalItems
# - in-place applicators (allOf, anyOf, oneOf, not, if/then/else, dependentSchemas) and items,
#   additionalItems must be evaluated before unevaluatedItems (in the Unevaluated vocabulary)
# - properties and patternProperties must be evaluated before additionalProperties
# - in-place applicators and properties, patternProperties, additionalProperties must be evaluated
#   before unevaluatedProperties (in the Unevaluated vocabulary)
# - contains must be evaluated before maxContains, minContains (implemented here, rather than in the Validation vocabulary)
sub keywords ($class, $spec_version) {
  return (
    qw(allOf anyOf oneOf not if then else),
    $spec_version eq 'draft7' ? 'dependencies' : 'dependentSchemas',
    $spec_version !~ qr/^draft(7|2019-09)$/ ? 'prefixItems' : (),
    'items',
    $spec_version =~ qr/^draft(7|2019-09)$/ ? 'additionalItems' : (),
    'contains', $spec_version ne 'draft7' ? qw(maxContains minContains) : (),
    qw(properties patternProperties additionalProperties propertyNames),
    $spec_version eq 'draft2019-09' ? qw(unevaluatedItems unevaluatedProperties) : (),
  );
}

# in draft2019-09, the unevaluated keywords were part of the Applicator vocabulary
foreach my $phase (qw(traverse eval)) {
  foreach my $type (qw(Items Properties)) {
    my $method = '_'.$phase.'_keyword_unevaluated'.$type;
    Sub::Install::install_sub({
      as   => $method,
      code => sub {
        shift;
        JSON::Schema::Modern::Vocabulary::Unevaluated->$method(@_);
      }
    }),
  }
}

sub _traverse_keyword_allOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_allOf ($class, $data, $schema, $state) {
  my @invalid;
  foreach my $idx (0 .. $schema->{allOf}->$#*) {
    if ($class->eval($data, $schema->{allOf}[$idx], +{ %$state,
        schema_path => $state->{schema_path}.'/allOf/'.$idx })) {
    }
    else {
      push @invalid, $idx;
      last if $state->{short_circuit};
    }
  }

  return 1 if @invalid == 0;

  my $pl = @invalid > 1;
  return E($state, 'subschema%s %s %s not valid', $pl?'s':'', join(', ', @invalid), $pl?'are':'is');
}

sub _traverse_keyword_anyOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_anyOf ($class, $data, $schema, $state) {
  my $valid = 0;
  my @errors;
  foreach my $idx (0 .. $schema->{anyOf}->$#*) {
    next if not $class->eval($data, $schema->{anyOf}[$idx],
      +{ %$state, errors => \@errors, schema_path => $state->{schema_path}.'/anyOf/'.$idx });
    ++$valid;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  push $state->{errors}->@*, @errors;
  return E($state, 'no subschemas are valid');
}

sub _traverse_keyword_oneOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_oneOf ($class, $data, $schema, $state) {
  my (@valid, @errors);
  foreach my $idx (0 .. $schema->{oneOf}->$#*) {
    next if not $class->eval($data, $schema->{oneOf}[$idx],
      +{ %$state, errors => \@errors, schema_path => $state->{schema_path}.'/oneOf/'.$idx });
    push @valid, $idx;
    last if @valid > 1 and $state->{short_circuit};
  }

  return 1 if @valid == 1;

  if (not @valid) {
    push $state->{errors}->@*, @errors;
    return E($state, 'no subschemas are valid');
  }
  else {
    return E($state, 'multiple subschemas are valid: '.join(', ', @valid));
  }
}

sub _traverse_keyword_not { shift->traverse_subschema(@_) }

sub _eval_keyword_not ($class, $data, $schema, $state) {
  return 1 if not $class->eval($data, $schema->{not},
    +{ %$state, schema_path => $state->{schema_path}.'/not',
      short_circuit_suggested => 1, # errors do not propagate upward from this subschema
      collect_annotations => 0,     # nor do annotations
      errors => [] });

  return E($state, 'subschema is valid');
}

sub _traverse_keyword_if { shift->traverse_subschema(@_) }
sub _traverse_keyword_then { shift->traverse_subschema(@_) }
sub _traverse_keyword_else { shift->traverse_subschema(@_) }

sub _eval_keyword_if ($class, $data, $schema, $state) {
  return 1 if not exists $schema->{then} and not exists $schema->{else}
    and not $state->{collect_annotations};
  my $keyword = $class->eval($data, $schema->{if},
     +{ %$state, schema_path => $state->{schema_path}.'/if',
        short_circuit_suggested => !$state->{collect_annotations},
        errors => [],
      })
    ? 'then' : 'else';

  return 1 if not exists $schema->{$keyword};
  return 1 if $class->eval($data, $schema->{$keyword},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$keyword });
  return E({ %$state, keyword => $keyword }, 'subschema is not valid');
}

sub _traverse_keyword_dependentSchemas { shift->traverse_object_schemas(@_) }

sub _eval_keyword_dependentSchemas ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependentSchemas}->%*) {
    next if not exists $data->{$property};

    if ($class->eval($data, $schema->{dependentSchemas}{$property},
        +{ %$state, schema_path => jsonp($state->{schema_path}, 'dependentSchemas', $property) })) {
      next;
    }

    $valid = 0;
    last if $state->{short_circuit};
  }

  return E($state, 'not all dependencies are satisfied') if not $valid;
  return 1;
}

sub _traverse_keyword_dependencies ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependencies}->%*) {
    if (is_type('array', $schema->{dependencies}{$property})) {
      # as in dependentRequired

      foreach my $index (0..$schema->{dependencies}{$property}->$#*) {
        $valid = E({ %$state, _schema_path_suffix => [ $property, $index ] }, 'element #%d is not a string', $index)
          if not is_type('string', $schema->{dependencies}{$property}[$index]);
      }

      $valid = E({ %$state, _schema_path_suffix => $property }, 'elements are not unique')
        if not is_elements_unique($schema->{dependencies}{$property});
    }
    else {
      # as in dependentSchemas
      $valid = 0 if not $class->traverse_property_schema($schema, $state, $property);
    }
  }
  return $valid;
}

sub _eval_keyword_dependencies ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  foreach my $property (sort keys $schema->{dependencies}->%*) {
    next if not exists $data->{$property};

    if (is_type('array', $schema->{dependencies}{$property})) {
      # as in dependentRequired
      if (my @missing = grep !exists($data->{$_}), $schema->{dependencies}{$property}->@*) {
        $valid = E({ %$state, _schema_path_suffix => $property },
          'object is missing propert%s: %s', @missing > 1 ? 'ies' : 'y', join(', ', @missing));
      }
    }
    else {
      # as in dependentSchemas
      if ($class->eval($data, $schema->{dependencies}{$property},
          +{ %$state, schema_path => jsonp($state->{schema_path}, 'dependencies', $property) })) {
        next;
      }

      $valid = 0;
      last if $state->{short_circuit};
    }
  }

  return E($state, 'not all dependencies are satisfied') if not $valid;
  return 1;
}

sub _traverse_keyword_prefixItems { shift->traverse_array_schemas(@_) }

sub _eval_keyword_prefixItems { goto \&_eval_keyword__items_array_schemas }

sub _traverse_keyword_items ($class, $schema, $state) {
  if (is_plain_arrayref($schema->{items})) {
    return E($state, 'array form of "items" not supported in %s', $state->{spec_version})
      if $state->{spec_version} !~ /^draft(?:7|2019-09)$/;

    return $class->traverse_array_schemas($schema, $state);
  }

  $class->traverse_subschema($schema, $state);
}

sub _eval_keyword_items ($class, $data, $schema, $state) {
  goto \&_eval_keyword__items_array_schemas if is_plain_arrayref($schema->{items});
  goto \&_eval_keyword__items_schema;
}

sub _traverse_keyword_additionalItems { shift->traverse_subschema(@_) }

sub _eval_keyword_additionalItems ($class, $data, $schema, $state) {
  return 1 if not exists $state->{_last_items_index};
  goto \&_eval_keyword__items_schema;
}

# prefixItems (draft 2020-12), array-based items (all drafts)
sub _eval_keyword__items_array_schemas ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if ($state->{_last_items_index}//-1) == $data->$#*;

  my $valid = 1;

  foreach my $idx (0 .. $data->$#*) {
    last if $idx > $schema->{$state->{keyword}}->$#*;
    $state->{_last_items_index} = $idx;

    if (is_type('boolean', $schema->{$state->{keyword}}[$idx])) {
      next if $schema->{$state->{keyword}}[$idx];
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx,
        _schema_path_suffix => $idx, collect_annotations => $state->{collect_annotations} & ~1 },
        'item not permitted');
    }
    elsif ($class->eval($data->[$idx], $schema->{$state->{keyword}}[$idx],
        +{ %$state, data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/'.$state->{keyword}.'/'.$idx,
          collect_annotations => $state->{collect_annotations} & ~1 })) {
      next;
    }

    $valid = 0;
    last if $state->{short_circuit} and not exists $schema->{
        $state->{keyword} eq 'prefixItems' ? 'items'
      : $state->{keyword} eq 'items' ? 'additionalItems' : die
    };
  }

  A($state, $state->{_last_items_index} == $data->$#* ? true : $state->{_last_items_index});
  return E($state, 'not all items are valid') if not $valid;
  return 1;
}

# schema-based items (all drafts), and additionalItems (up to and including draft2019-09)
sub _eval_keyword__items_schema ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);
  return 1 if ($state->{_last_items_index}//-1) == $data->$#*;

  my $valid = 1;

  foreach my $idx (($state->{_last_items_index}//-1)+1 .. $data->$#*) {
    if (is_type('boolean', $schema->{$state->{keyword}})) {
      next if $schema->{$state->{keyword}};
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx },
        '%sitem not permitted',
        exists $schema->{prefixItems} || $state->{keyword} eq 'additionalItems' ? 'additional ' : '');
    }
    else {
      if ($class->eval($data->[$idx], $schema->{$state->{keyword}},
        +{ %$state, data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/'.$state->{keyword},
          collect_annotations => $state->{collect_annotations} & ~1 })) {
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  $state->{_last_items_index} = $data->$#*;

  A($state, true);
  return E($state, 'subschema is not valid against all %sitems',
    $state->{keyword} eq 'additionalItems' ? 'additional ' : '') if not $valid;
  return 1;
}

sub _traverse_keyword_contains { shift->traverse_subschema(@_) }

sub _eval_keyword_contains ($class, $data, $schema, $state) {
  return 1 if not is_type('array', $data);

  $state->{_num_contains} = 0;
  my (@errors, @valid);

  foreach my $idx (0 .. $data->$#*) {
    if ($class->eval($data->[$idx], $schema->{contains},
        +{ %$state, errors => \@errors,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/contains',
          collect_annotations => $state->{collect_annotations} & ~1 })) {
      ++$state->{_num_contains};
      push @valid, $idx;

      last if $state->{short_circuit}
        and (not exists $schema->{maxContains} or $state->{_num_contains} > $schema->{maxContains})
        and ($state->{_num_contains} >= ($schema->{minContains}//1));
    }
  }

  # note: no items contained is only valid when minContains is explicitly 0
  if (not $state->{_num_contains}
      and (($schema->{minContains}//1) > 0 or $state->{spec_version} eq 'draft7')) {
    push $state->{errors}->@*, @errors;
    return E($state, 'subschema is not valid against any item');
  }

  return $state->{spec_version} =~ /^draft(?:7|2019-09)$/ ? 1
    : A($state, @valid == @$data ? true : \@valid);
}

# 'maxContains' and 'minContains' are owned by the Validation vocabulary, but do nothing if the
# Applicator vocabulary is omitted and depend on the result of 'contains', so they are implemented
# here, to be evaluated after 'contains'

sub _traverse_keyword_maxContains { 1 }

sub _eval_keyword_maxContains ($class, $data, $schema, $state) {
  return 1 if not grep $_ eq 'JSON::Schema::Modern::Vocabulary::Validation',
    $state->{vocabularies}->@*;

  return 1 if not exists $state->{_num_contains};
  return 1 if not is_type('array', $data);

  return E($state, 'array contains more than %d matching items', $schema->{maxContains})
    if $state->{_num_contains} > $schema->{maxContains};

  return 1;
}

sub _traverse_keyword_minContains { 1 }

sub _eval_keyword_minContains ($class, $data, $schema, $state) {
  return 1 if not grep $_ eq 'JSON::Schema::Modern::Vocabulary::Validation',
    $state->{vocabularies}->@*;

  return 1 if not exists $state->{_num_contains};
  return 1 if not is_type('array', $data);

  return E($state, 'array contains fewer than %d matching items', $schema->{minContains})
    if $state->{_num_contains} < $schema->{minContains};

  return 1;
}

sub _traverse_keyword_properties { shift->traverse_object_schemas(@_) }

sub _eval_keyword_properties ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @properties;
  foreach my $property (sort keys $schema->{properties}->%*) {
    next if not exists $data->{$property};
    push @properties, $property;

    if (is_type('boolean', $schema->{properties}{$property})) {
      next if $schema->{properties}{$property};
      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property),
        _schema_path_suffix => $property }, 'property not permitted');
    }
    else {
      if ($class->eval($data->{$property}, $schema->{properties}{$property},
          +{ %$state, data_path => jsonp($state->{data_path}, $property),
            schema_path => jsonp($state->{schema_path}, 'properties', $property),
            collect_annotations => $state->{collect_annotations} & ~1 })) {
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  A($state, \@properties);
  return E($state, 'not all properties are valid') if not $valid;
  return 1;
}

sub _traverse_keyword_patternProperties ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys $schema->{patternProperties}->%*) {
    $valid = 0 if not assert_pattern({ %$state, _schema_path_suffix => $property }, $property);
    $valid = 0 if not $class->traverse_property_schema($schema, $state, $property);
  }
  return $valid;
}

sub _eval_keyword_patternProperties ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @properties;
  foreach my $property_pattern (sort keys $schema->{patternProperties}->%*) {
    foreach my $property (sort grep m/(?:$property_pattern)/, keys %$data) {
      push @properties, $property;
      if (is_type('boolean', $schema->{patternProperties}{$property_pattern})) {
        next if $schema->{patternProperties}{$property_pattern};
        $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property),
          _schema_path_suffix => $property_pattern }, 'property not permitted');
      }
      else {
        if ($class->eval($data->{$property}, $schema->{patternProperties}{$property_pattern},
            +{ %$state, data_path => jsonp($state->{data_path}, $property),
              schema_path => jsonp($state->{schema_path}, 'patternProperties', $property_pattern),
              collect_annotations => $state->{collect_annotations} & ~1 })) {
          next;
        }

        $valid = 0;
      }
      last if $state->{short_circuit};
    }
  }

  A($state, [ uniqstr @properties ]);
  return E($state, 'not all properties are valid') if not $valid;
  return 1;
}

sub _traverse_keyword_additionalProperties { shift->traverse_subschema(@_) }

sub _eval_keyword_additionalProperties ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @properties;
  foreach my $property (sort keys %$data) {
    next if exists $schema->{properties} and exists $schema->{properties}{$property};
    next if exists $schema->{patternProperties}
      and any { $property =~ /(?:$_)/ } keys $schema->{patternProperties}->%*;

    push @properties, $property;
    if (is_type('boolean', $schema->{additionalProperties})) {
      next if $schema->{additionalProperties};
      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property) },
        'additional property not permitted');
    }
    else {
      if ($class->eval($data->{$property}, $schema->{additionalProperties},
          +{ %$state, data_path => jsonp($state->{data_path}, $property),
            schema_path => $state->{schema_path}.'/additionalProperties',
            collect_annotations => $state->{collect_annotations} & ~1 })) {
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  A($state, \@properties);
  return E($state, 'not all additional properties are valid') if not $valid;
  return 1;
}

sub _traverse_keyword_propertyNames { shift->traverse_subschema(@_) }

sub _eval_keyword_propertyNames ($class, $data, $schema, $state) {
  return 1 if not is_type('object', $data);

  my $valid = 1;
  foreach my $property (sort keys %$data) {
    if ($class->eval($property, $schema->{propertyNames},
        +{ %$state, data_path => jsonp($state->{data_path}, $property),
          schema_path => $state->{schema_path}.'/propertyNames',
          collect_annotations => $state->{collect_annotations} & ~1 })) {
      next;
    }

    $valid = 0;
    last if $state->{short_circuit};
  }

  return E($state, 'not all property names are valid') if not $valid;
  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Applicator" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/applicator> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-core.html#section-10>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/applicator> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-02#section-9> (except for the
  C<unevaluatedItems> and C<unevaluatedProperties> keywords, which are implemented in
  L<JSON::Schema::Modern::Vocabulary::Unevaluated>);
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-6>.

=cut
