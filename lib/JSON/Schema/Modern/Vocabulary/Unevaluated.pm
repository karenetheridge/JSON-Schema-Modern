use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Unevaluated;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Unevaluated vocabulary

our $VERSION = '0.515';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use List::Util 1.45 qw(any max);
use JSON::Schema::Modern::Utilities qw(is_type jsonp local_annotations E A abort true);
use Moo;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  my ($self, $spec_version) = @_;
  return
      $spec_version eq 'draft2019-09' ? 'https://json-schema.org/draft/2019-09/vocab/applicator'
    : undef;
}

# This vocabulary should be evaluated after the Applicator vocabulary.
sub keywords {
  qw(unevaluatedItems unevaluatedProperties);
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

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the C<unevaluatedItems> and C<unevaluatedProperties> keywords in the
JSON Schema Draft 2019-09 "Applicator" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/applicator> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-02#section-9>.

=cut
