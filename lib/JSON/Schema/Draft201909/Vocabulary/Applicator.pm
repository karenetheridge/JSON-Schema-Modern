use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Applicator;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Draft 2019-09 Applicator vocabulary

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use List::Util 1.45 qw(any uniqstr max);
use Ref::Util 0.100 'is_plain_arrayref';
use JSON::Schema::Draft201909::Utilities qw(is_type jsonp local_annotations E A abort assert_keyword_type assert_pattern true);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/applicator' }

sub keywords {
  qw(allOf anyOf oneOf not if then else dependentSchemas
    items additionalItems unevaluatedItems contains
    properties patternProperties additionalProperties unevaluatedProperties propertyNames);
}

sub _traverse_keyword_allOf { shift->traverse_array_schemas(@_) }

sub _eval_keyword_allOf {
  my ($self, $data, $schema, $state) = @_;

  my @invalid;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $idx (0 .. $#{$schema->{allOf}}) {
    my @annotations = @orig_annotations;
    if ($self->evaluator->_eval($data, $schema->{allOf}[$idx], +{ %$state,
        schema_path => $state->{schema_path}.'/allOf/'.$idx, annotations => \@annotations })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
    }
    else {
      push @invalid, $idx;
      last if $state->{short_circuit};
    }
  }

  if (not @invalid) {
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
    next if not $self->evaluator->_eval($data, $schema->{anyOf}[$idx],
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
    next if not $self->evaluator->_eval($data, $schema->{oneOf}[$idx],
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

sub _traverse_keyword_not { shift->traverse_schema(@_) }

sub _eval_keyword_not {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $self->evaluator->_eval($data, $schema->{not},
    +{ %$state, schema_path => $state->{schema_path}.'/not',
      short_circuit => (!$state->{short_circuit} || $state->{collect_annotations} ? 0 : 1),
      errors => [], annotations => [ @{$state->{annotations}} ] });

  return E($state, 'subschema is valid');
}

sub _traverse_keyword_if { shift->traverse_schema(@_) }
sub _traverse_keyword_then { shift->traverse_schema(@_) }
sub _traverse_keyword_else { shift->traverse_schema(@_) }

sub _eval_keyword_if {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not exists $schema->{then} and not exists $schema->{else}
    and not $state->{collect_annotations};
  my $keyword = $self->evaluator->_eval($data, $schema->{if},
     +{ %$state,
        schema_path => $state->{schema_path}.'/if',
        short_circuit => (!$state->{short_circuit} || $state->{collect_annotations} ? 0 : 1),
        errors => [],
      })
    ? 'then' : 'else';

  return 1 if not exists $schema->{$keyword};
  return 1 if $self->evaluator->_eval($data, $schema->{$keyword},
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
    if ($self->evaluator->_eval($data, $schema->{dependentSchemas}{$property},
        +{ %$state, annotations => \@annotations,
          schema_path => jsonp($state->{schema_path}, 'dependentSchemas', $property) })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      next;
    }

    $valid = 0;
    last if $state->{short_circuit};
  }

  return E($state, 'not all subschemas are valid') if not $valid;
  push @{$state->{annotations}}, @new_annotations;
  return 1;
}

sub _traverse_keyword_items {
  my ($self, $schema, $state) = @_;

  # Note: the metaschema says "items" has minItems:1 but the written spec omits this.
  my $method = is_plain_arrayref($schema->{items}) ? 'traverse_array_schemas' : 'traverse_schema';
  $self->$method($schema, $state);
}

sub _traverse_keyword_additionalItems { shift->traverse_schema(@_) }

sub _eval_keyword_items {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);

  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;

  if (not is_plain_arrayref($schema->{items})) {
    my $valid = 1;
    foreach my $idx (0 .. $#{$data}) {
      my @annotations = @orig_annotations;
      if (is_type('boolean', $schema->{items})) {
        next if $schema->{items};
        $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx }, 'item not permitted');
      }
      elsif ($self->evaluator->_eval($data->[$idx], $schema->{items},
          +{ %$state, annotations => \@annotations,
            data_path => $state->{data_path}.'/'.$idx,
            schema_path => $state->{schema_path}.'/items' })) {
        push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
        next;
      }

      $valid = 0;
      last if $state->{short_circuit};
    }

    return E($state, 'subschema is not valid against all items') if not $valid;
    push @{$state->{annotations}}, @new_annotations;
    return A($state, true);
  }

  my $last_index = -1;
  my $valid = 1;
  foreach my $idx (0 .. $#{$data}) {
    last if $idx > $#{$schema->{items}};
    $last_index = $idx;

    my @annotations = @orig_annotations;
    if (is_type('boolean', $schema->{items}[$idx])) {
      next if $schema->{items}[$idx];
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx,
        _schema_path_suffix => $idx }, 'item not permitted');
    }
    elsif ($self->evaluator->_eval($data->[$idx], $schema->{items}[$idx],
        +{ %$state, annotations => \@annotations,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/items/'.$idx })) {
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      next;
    }

    $valid = 0;
    last if $state->{short_circuit} and not exists $schema->{additionalItems};
  }

  if ($valid) {
    push @{$state->{annotations}}, @new_annotations;
    A($state, $last_index);
  }
  else {
    E($state, 'subschema is not valid against all items');
  }

  return $valid if not exists $schema->{additionalItems} or $last_index == $#{$data};
  $state->{keyword} = 'additionalItems';
  @orig_annotations = @{$state->{annotations}};

  foreach my $idx ($last_index+1 .. $#{$data}) {
    if (is_type('boolean', $schema->{additionalItems})) {
      next if $schema->{additionalItems};
      $valid = E({ %$state, data_path => $state->{data_path}.'/'.$idx },
          'additional item not permitted');
    }
    else {
      my @annotations = @orig_annotations;
      if ($self->evaluator->_eval($data->[$idx], $schema->{additionalItems},
          +{ %$state, data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/additionalItems', annotations => \@annotations })) {
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

sub _traverse_keyword_unevaluatedItems {
  my ($self, $schema, $state) = @_;

  $self->traverse_schema($schema, $state);

  # remember that annotations need to be collected in order to evaluate this keyword
  $state->{configs}{collect_annotations} = 1;
}

sub _eval_keyword_unevaluatedItems {
  my ($self, $data, $schema, $state) = @_;

  abort($state, '"unevaluatedItems" keyword present, but annotation collection is disabled')
    if not $state->{collect_annotations};

  abort($state, '"unevaluatedItems" keyword present, but short_circuit is enabled: results unreliable')
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
      if ($self->evaluator->_eval($data->[$idx], $schema->{unevaluatedItems},
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

sub _traverse_keyword_contains { shift->traverse_schema(@_) }

sub _eval_keyword_contains {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('array', $data);

  my $num_valid = 0;
  my @orig_annotations = @{$state->{annotations}};
  my (@errors, @new_annotations);
  foreach my $idx (0 .. $#{$data}) {
    my @annotations = @orig_annotations;
    if ($self->evaluator->_eval($data->[$idx], $schema->{contains},
        +{ %$state, errors => \@errors, annotations => \@annotations,
          data_path => $state->{data_path}.'/'.$idx,
          schema_path => $state->{schema_path}.'/contains' })) {
      ++$num_valid;
      push @new_annotations, @annotations[$#orig_annotations+1 .. $#annotations];
      last if $state->{short_circuit}
        and (not exists $schema->{maxContains} or $num_valid > $schema->{maxContains})
        and ($num_valid >= ($schema->{minContains} // 1));
    }
  }

  push @{$state->{annotations}}, @new_annotations if $num_valid;

  my $valid = 1;
  # note: no items contained is only valid when minContains=0
  if (not $num_valid and ($schema->{minContains} // 1) > 0) {
    $valid = 0;
    push @{$state->{errors}}, @errors;
    E($state, 'subschema is not valid against any item');
    return 0 if $state->{short_circuit};
  }

  # TODO: in the future, we can move these implementations to the Validation vocabulary
  # and inspect the annotation produced by the 'contains' keyword.
  if (exists $schema->{maxContains} and $num_valid > $schema->{maxContains}) {
    $valid = E({ %$state, keyword => 'maxContains' }, 'contains too many matching items');
    return 0 if $state->{short_circuit};
  }

  if ($num_valid < ($schema->{minContains} // 1)) {
    $valid = E({ %$state, keyword => 'minContains' }, 'contains too few matching items');
    return 0 if $state->{short_circuit};
  }

  return $valid;
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
      if ($self->evaluator->_eval($data->{$property}, $schema->{properties}{$property},
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

    $self->evaluator->_traverse($schema->{patternProperties}{$property},
      +{ %$state, schema_path => jsonp($state->{schema_path}, 'patternProperties', $property) });
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
        if ($self->evaluator->_eval($data->{$property}, $schema->{patternProperties}{$property_pattern},
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

sub _traverse_keyword_additionalProperties { shift->traverse_schema(@_) }

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
      if ($self->evaluator->_eval($data->{$property}, $schema->{additionalProperties},
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

  $self->traverse_schema($schema, $state);

  # remember that annotations need to be collected in order to evaluate this keyword
  $state->{configs}{collect_annotations} = 1;
}

sub _eval_keyword_unevaluatedProperties {
  my ($self, $data, $schema, $state) = @_;

  abort($state, '"unevaluatedProperties" keyword present, but annotation collection is disabled')
    if not $state->{collect_annotations};

  abort($state, '"unevaluatedProperties" keyword present, but short_circuit is enabled: results unreliable')
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
      if ($self->evaluator->_eval($data->{$property}, $schema->{unevaluatedProperties},
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

sub _traverse_keyword_propertyNames { shift->traverse_schema(@_) }

sub _eval_keyword_propertyNames {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('object', $data);

  my $valid = 1;
  my @orig_annotations = @{$state->{annotations}};
  my @new_annotations;
  foreach my $property (sort keys %$data) {
    my @annotations = @orig_annotations;
    if ($self->evaluator->_eval($property, $schema->{propertyNames},
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
