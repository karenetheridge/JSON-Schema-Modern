use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Applicator;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Draft 2019-09 Applicator vocabulary

our $VERSION = '0.512';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use List::Util 1.45 qw(any uniqstr max);
use Ref::Util 0.100 'is_plain_arrayref';
use JSON::Schema::Draft201909::Utilities qw(is_type jsonp local_annotations E A abort assert_keyword_type assert_pattern true);
use Moo;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/applicator' }

# the keyword order is arbitrary, except:
# - if must be evaluated before then, else
# - items must be evaluated before additionalItems
# - in-place applicators (allOf, anyOf, oneOf, not, if/then/else, dependentSchemas) and items,
#   additionalItems must be evaluated before unevaluatedItems
# - properties and patternProperties must be evaluated before additionalProperties
# - in-place applicators and properties, patternProperties, additionalProperties must be evaluated
#   before unevaluatedProperties
# - contains must be evaluated before maxContains, minContains (in the Validator vocabulary)
sub keywords {
  qw(allOf anyOf oneOf not if then else dependentSchemas
    items additionalItems contains
    properties patternProperties additionalProperties propertyNames
    unevaluatedItems unevaluatedProperties);
}

sub _traverse_keyword_allOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_allOf {
  my ($self, $data, $schema, $state) = @_;

  my @invalid;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $idx (0 .. $#{$schema->{allOf}}) {
    my @annotations = @orig_annotations;
    if ($self->eval($data, $schema->{allOf}[$idx], +{ %$state,
        schema_path => $state->{schema_path}.'/allOf/'.$idx, annotations => \@annotations })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
    }
    else {
      push @invalid, $idx;
      last if $state->{short_circuit};
    }
  }

  if (@invalid == 0) {
    push @{$state->{annotations}}, @new_annotations;
    return 1;
  }

  my $pl = @invalid > 1;
  return E($state, 'subschema%s %s %s not valid', $pl?'s':'', join(', ', @invalid), $pl?'are':'is');
}

sub _traverse_keyword_anyOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_anyOf {
  my ($self, $data, $schema, $state) = @_;

  my $valid = 0;
  my @errors;
  foreach my $idx (0 .. $#{$schema->{anyOf}}) {
    next if not $self->eval($data, $schema->{anyOf}[$idx],
      +{ %$state, errors => \@errors, schema_path => $state->{schema_path}.'/anyOf/'.$idx });
    ++$valid;
    last if $state->{short_circuit};
  }

  return 1 if $valid;
  push @{$state->{errors}}, @errors;
  return E($state, 'no subschemas are valid');
}

sub _traverse_keyword_oneOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_oneOf {
  my ($self, $data, $schema, $state) = @_;

  my (@valid, @errors);
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $idx (0 .. $#{$schema->{oneOf}}) {
    my @annotations = @orig_annotations;
    next if not $self->eval($data, $schema->{oneOf}[$idx],
      +{ %$state, errors => \@errors, annotations => \@annotations,
        schema_path => $state->{schema_path}.'/oneOf/'.$idx });
    push @valid, $idx;
    push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
    last if @valid > 1 and $state->{short_circuit};
  }

  if (@valid == 1) {
    push @{$state->{annotations}}, @new_annotations;
    return 1;
  }
  if (not @valid) {
    push @{$state->{errors}}, @errors;
    return E($state, 'no subschemas are valid');
  }
  else {
    return E($state, 'multiple subschemas are valid: '.join(', ', @valid));
  }
}

sub _traverse_keyword_not { shift->traverse_subschema(@_) }

sub _eval_keyword_not {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->eval($data, $schema->{not},
    +{ %$state, schema_path => $state->{schema_path}.'/not',
      short_circuit => $state->{short_circuit} || !$state->{collect_annotations},
      errors => [], annotations => [ @{$state->{annotations}} ] });

  return E($state, 'subschema is valid');
}

sub _traverse_keyword_if { shift->traverse_subschema(@_) }
sub _traverse_keyword_then { shift->traverse_subschema(@_) }
sub _traverse_keyword_else { shift->traverse_subschema(@_) }

sub _eval_keyword_if {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{then} and not exists $schema->{else}
    and not $state->{collect_annotations};
  my $keyword = $self->eval($data, $schema->{if},
     +{ %$state, schema_path => $state->{schema_path}.'/if',
        short_circuit => $state->{short_circuit} || !$state->{collect_annotations},
        errors => [],
      })
    ? 'then' : 'else';

  return 1 if not exists $schema->{$keyword};
  return 1 if $self->eval($data, $schema->{$keyword},
    +{ %$state, schema_path => $state->{schema_path}.'/'.$keyword });
  return E({ %$state, keyword => $keyword }, 'subschema is not valid');
}

sub _traverse_keyword_dependentSchemas { shift->traverse_object_schemas(@_) }

sub _eval_keyword_dependentSchemas {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $property (sort keys %{$schema->{dependentSchemas}}) {
    next if not exists $data->{$property};

    my @annotations = @orig_annotations;
    if ($self->eval($data, $schema->{dependentSchemas}{$property},
        +{ %$state, annotations => \@annotations,
          schema_path => jsonp($state->{schema_path}, 'dependentSchemas', $property) })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      next;
    }

    $valid = 0;
    last if $state->{short_circuit};
  }

  return E($state, 'not all dependencies are satisfied') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return 1;
}

sub _traverse_keyword_items {
  my ($self, $schema, $state) = @_;

  return $self->traverse_array_schemas($schema, $state) if is_plain_arrayref($schema->{items});
  $self->traverse_subschema($schema, $state);
}

sub _eval_keyword_items {
  my ($self, $data, $schema, $state) = @_;

  goto \&_eval_keyword__items_array_schemas if is_plain_arrayref($schema->{items});

  $state->{_last_items_index} //= -1;
  goto \&_eval_keyword__items_schema;
}

sub _traverse_keyword_additionalItems { shift->traverse_subschema(@_) }

sub _eval_keyword_additionalItems {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $state->{_last_items_index};
  goto \&_eval_keyword__items_schema;
}

# array-based items
sub _eval_keyword__items_array_schemas {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);

  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  my $valid = 1;

  foreach my $idx (0 .. $#{$data}) {
    last if $idx > $#{$schema->{$state->{keyword}}};
    $state->{_last_items_index} = $idx;

    my @annotations = @orig_annotations;
    if (is_type('boolean', $schema->{$state->{keyword}}[$idx])) {
      next if $schema->{$state->{keyword}}[$idx];
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx,
        _schema_path_suffix => $idx }, 'item not permitted');
    }
    elsif ($self->eval($data->[$idx], $schema->{$state->{keyword}}[$idx],
        +{ %$state, annotations => \@annotations,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/'.$state->{keyword}.'/'.$idx })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      next;
    }

    $valid = 0;
    last if $state->{short_circuit} and not exists $schema->{additionalItems};
  }

  return E($state, 'not all items are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, $state->{_last_items_index});
}

# schema-based items and additionalItems
sub _eval_keyword__items_schema {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);
  return 1 if $state->{_last_items_index} == $#{$data};

  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  my $valid = 1;

  foreach my $idx ($state->{_last_items_index}+1 .. $#{$data}) {
    if (is_type('boolean', $schema->{$state->{keyword}})) {
      next if $schema->{$state->{keyword}};
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx },
        '%sitem not permitted', $state->{keyword} eq 'additionalItems' ? 'additional ' : '');
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->eval($data->[$idx], $schema->{$state->{keyword}},
        +{ %$state, annotations => \@annotations,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/'.$state->{keyword} })) {
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  $state->{_last_items_index} = $#{$data};

  return E($state, 'subschema is not valid against all %sitems',
    $state->{keyword} eq 'additionalItems' ? 'additional ' : '') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, true);
}

sub _traverse_keyword_unevaluatedItems {
  my ($self, $schema, $state) = @_;

  $self->traverse_subschema($schema, $state);

  # remember that annotations need to be collected in order to evaluate this keyword
  $state->{configs}{collect_annotations} = 1;
}

sub _eval_keyword_unevaluatedItems {
  my ($self, $data, $schema, $state) = @_;

  abort($state, 'EXCEPTION: "unevaluatedItems" keyword present, but annotation collection is disabled')
    if not $state->{collect_annotations};

  abort($state, 'EXCEPTION: "unevaluatedItems" keyword present, but short_circuit is enabled: results unreliable')
    if $state->{short_circuit};

  return 1 if not is_type('array', $data);

  my @annotations = local_annotations($state);
  my @items_annotations = grep $_->keyword eq 'items', @annotations;
  my @additionalItems_annotations = grep $_->keyword eq 'additionalItems', @annotations;
  my @unevaluatedItems_annotations = grep $_->keyword eq 'unevaluatedItems', @annotations;

  # items, additionalItems or unevaluatedItems already produced a 'true' annotation at this location
  return 1
    if any { is_type('boolean', $_->annotation) && $_->annotation }
      @items_annotations, @additionalItems_annotations, @unevaluatedItems_annotations;

  # otherwise, _eval at every instance item greater than the max of all numeric 'items' annotations
  my $last_index = max(-1, grep is_type('integer', $_), map $_->annotation, @items_annotations);
  return 1 if $last_index == $#{$data};

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $idx ($last_index+1 .. $#{$data}) {
    if (is_type('boolean', $schema->{unevaluatedItems})) {
      next if $schema->{unevaluatedItems};
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx },
          'additional item not permitted')
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->eval($data->[$idx], $schema->{unevaluatedItems},
          +{ %$state, annotations => \@annotations,
            data_path => $state->{data_path}.'/'.$idx,
            schema_path => $state->{schema_path}.'/unevaluatedItems' })) {
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  return E($state, 'subschema is not valid against all additional items') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, true);
}

sub _traverse_keyword_contains { shift->traverse_subschema(@_) }

sub _eval_keyword_contains {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);

  $state->{_num_contains} = 0;
  my @orig_annotations = @{$state->{annotations}};
  my (@errors, @new_annotations);
  foreach my $idx (0 .. $#{$data}) {
    my @annotations = @orig_annotations;
    if ($self->eval($data->[$idx], $schema->{contains},
        +{ %$state, errors => \@errors, annotations => \@annotations,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/contains' })) {
      ++$state->{_num_contains};
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];

      last if $state->{short_circuit}
        and (not exists $schema->{maxContains} or $state->{_num_contains} > $schema->{maxContains})
        and ($state->{_num_contains} >= ($schema->{minContains}//1));
    }
  }

  # note: no items contained is only valid when minContains is explicitly 0
  if (not $state->{_num_contains} and ($schema->{minContains}//1) > 0) {
    push @{$state->{errors}}, @errors;
    return E($state, 'subschema is not valid against any item');
  }

  push @{$state->{annotations}}, @new_annotations;
  return 1;
}

sub _traverse_keyword_properties { shift->traverse_object_schemas(@_) }

sub _eval_keyword_properties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my (@valid_properties, @new_annotations);
  foreach my $property (sort keys %{$schema->{properties}}) {
    next if not exists $data->{$property};

    if (is_type('boolean', $schema->{properties}{$property})) {
      if ($schema->{properties}{$property}) {
        push @valid_properties, $property;
        next;
      }

      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property),
        _schema_path_suffix => $property }, 'property not permitted');
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->eval($data->{$property}, $schema->{properties}{$property},
          +{ %$state, annotations => \@annotations,
            data_path => jsonp($state->{data_path}, $property),
            schema_path => jsonp($state->{schema_path}, 'properties', $property) })) {
        push @valid_properties, $property;
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  return E($state, 'not all properties are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, \@valid_properties);
}

sub _traverse_keyword_patternProperties {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'object');

  foreach my $property (sort keys %{$schema->{patternProperties}}) {
    return if not assert_pattern({ %$state, _schema_path_suffix => $property }, $property);
    $self->traverse_property_schema($schema, $state, $property);
  }
}

sub _eval_keyword_patternProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my (@valid_properties, @new_annotations);
  foreach my $property_pattern (sort keys %{$schema->{patternProperties}}) {
    foreach my $property (sort grep m/$property_pattern/, keys %$data) {
      if (is_type('boolean', $schema->{patternProperties}{$property_pattern})) {
        if ($schema->{patternProperties}{$property_pattern}) {
          push @valid_properties, $property;
          next;
        }

        $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property),
          _schema_path_suffix => $property_pattern }, 'property not permitted');
      }
      else {
        my @annotations = @orig_annotations;
        if ($self->eval($data->{$property}, $schema->{patternProperties}{$property_pattern},
            +{ %$state, annotations => \@annotations,
              data_path => jsonp($state->{data_path}, $property),
              schema_path => jsonp($state->{schema_path}, 'patternProperties', $property_pattern) })) {
          push @valid_properties, $property;
          push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
          next;
        }

        $valid = 0;
      }
      last if $state->{short_circuit};
    }
  }

  return E($state, 'not all properties are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, [ uniqstr @valid_properties ]);
}

sub _traverse_keyword_additionalProperties { shift->traverse_subschema(@_) }

sub _eval_keyword_additionalProperties {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my (@valid_properties, @new_annotations);
  foreach my $property (sort keys %$data) {
    next if exists $schema->{properties} and exists $schema->{properties}{$property};
    next if exists $schema->{patternProperties}
      and any { $property =~ /$_/ } keys %{$schema->{patternProperties}};

    if (is_type('boolean', $schema->{additionalProperties})) {
      if ($schema->{additionalProperties}) {
        push @valid_properties, $property;
        next;
      }

      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property) },
        'additional property not permitted');
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->eval($data->{$property}, $schema->{additionalProperties},
          +{ %$state, annotations => \@annotations,
            data_path => jsonp($state->{data_path}, $property),
            schema_path => $state->{schema_path}.'/additionalProperties' })) {
        push @valid_properties, $property;
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  return E($state, 'not all additional properties are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, \@valid_properties);
}

sub _traverse_keyword_unevaluatedProperties {
  my ($self, $schema, $state) = @_;

  $self->traverse_subschema($schema, $state);

  # remember that annotations need to be collected in order to evaluate this keyword
  $state->{configs}{collect_annotations} = 1;
}

sub _eval_keyword_unevaluatedProperties {
  my ($self, $data, $schema, $state) = @_;

  abort($state, 'EXCEPTION: "unevaluatedProperties" keyword present, but annotation collection is disabled')
    if not $state->{collect_annotations};

  abort($state, 'EXCEPTION: "unevaluatedProperties" keyword present, but short_circuit is enabled: results unreliable')
    if $state->{short_circuit};

  return 1 if not is_type('object', $data);

  my @evaluated_properties = map {
    my $keyword = $_->keyword;
    (grep $keyword eq $_, qw(properties additionalProperties patternProperties unevaluatedProperties))
      ? @{$_->annotation} : ();
  } local_annotations($state);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my (@valid_properties, @new_annotations);
  foreach my $property (sort keys %$data) {
    next if any { $_ eq $property } @evaluated_properties;

    if (is_type('boolean', $schema->{unevaluatedProperties})) {
      if ($schema->{unevaluatedProperties}) {
        push @valid_properties, $property;
        next;
      }

      $valid = E({ %$state, data_path => jsonp($state->{data_path}, $property) },
        'additional property not permitted');
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->eval($data->{$property}, $schema->{unevaluatedProperties},
          +{ %$state, annotations => \@annotations,
            data_path => jsonp($state->{data_path}, $property),
            schema_path => $state->{schema_path}.'/unevaluatedProperties' })) {
        push @valid_properties, $property;
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
    }
    last if $state->{short_circuit};
  }

  return E($state, 'not all additional properties are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return A($state, \@valid_properties);
}

sub _traverse_keyword_propertyNames { shift->traverse_subschema(@_) }

sub _eval_keyword_propertyNames {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $property (sort keys %$data) {
    my @annotations = @orig_annotations;
    if ($self->eval($property, $schema->{propertyNames},
        +{ %$state, annotations => \@annotations,
          data_path => jsonp($state->{data_path}, $property),
          schema_path => $state->{schema_path}.'/propertyNames' })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      next;
    }

    $valid = 0;
    last if $state->{short_circuit};
  }

  return E($state, 'not all property names are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2019-09 "Applicator" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/applicator> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.9>.

=cut
