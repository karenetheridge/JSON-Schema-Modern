use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Core vocabulary

our $VERSION = '0.513';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities qw(is_type abort assert_keyword_type canonical_schema_uri E assert_uri_reference assert_uri);
use Moo;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/core' }

sub keywords {
  qw($id $schema $anchor $recursiveAnchor $ref $recursiveRef $vocabulary $comment $defs);
}

# adds the following keys to $state during traversal:
# - identifiers: an arrayref of tuples:
#   $uri => { path => $path_to_identifier, canonical_uri => Mojo::URL (absolute when possible) }
# this is used by the Document constructor to build its resource_index.

sub _traverse_keyword_id {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$id'});
  return E($state, '$id value should not equal "%s"', $uri) if $uri eq '' or $uri eq '#';
  return E($state, '$id value "%s" cannot have a non-empty fragment', $schema->{'$id'})
    if length $uri->fragment;

  $uri->fragment(undef);
  $state->{initial_schema_uri} = $uri->is_abs ? $uri : $uri->to_abs($state->{initial_schema_uri});
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{schema_path} = '';

  push @{$state->{identifiers}},
    $state->{initial_schema_uri} => {
      path => $state->{traversed_schema_path},
      canonical_uri => $state->{initial_schema_uri}->clone,
    };
}

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  if (my $canonical_uri = $state->{document}->path_to_canonical_uri($state->{document_path}.$state->{schema_path})) {
    $state->{initial_schema_uri} = $canonical_uri->clone;
    $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
    $state->{document_path} = $state->{document_path}.$state->{schema_path};
    $state->{schema_path} = '';
    return 1;
  }

  # this should never happen, if the pre-evaluation traversal was performed correctly
  abort($state, 'failed to resolve $id to canonical uri');
}

sub _traverse_keyword_schema {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string');
  assert_uri($state, $schema);

  return E($state, '$schema can only appear at the schema resource root')
    if length($state->{schema_path});

  return E($state, 'custom $schema references are not yet supported')
    if $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';
}

# we do nothing with $schema yet at evaluation time. In the future, at traversal time we will fetch
# the schema at the value of this keyword and examine its $vocabulary keyword to determine which
# dialect shall be in effect when considering this schema, then storing that dialect instance in
# $state.
# If no $schema is provided at the top level, we will use the default dialect defined by the
# specification metaschema (all six vocabularies).
# At evaluation time we simply swap out the dialect instance in $state.

sub _traverse_keyword_anchor {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string');
  return E($state, '$anchor value "%s" does not match required syntax', $schema->{'$anchor'})
    if $schema->{'$anchor'} !~ /^[A-Za-z][A-Za-z0-9_:.-]*$/;

  my $canonical_uri = canonical_schema_uri($state);

  push @{$state->{identifiers}},
    Mojo::URL->new->to_abs($canonical_uri)->fragment($schema->{'$anchor'}) => {
      path => $state->{traversed_schema_path}.$state->{schema_path},
      canonical_uri => $canonical_uri,
    };
}

# we already indexed the $anchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_recursiveAnchor {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'boolean');

  return if not $schema->{'$recursiveAnchor'};

  # this is required because the location is used as the base URI for future resolution
  # of $recursiveRef, and the fragment would be disregarded in the base
  return E($state, '"$recursiveAnchor" keyword used without "$id"')
    if length($state->{schema_path});
}

sub _eval_keyword_recursiveAnchor {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  $state->{recursive_anchor_uri} = canonical_schema_uri($state);
  return 1;
}

sub _traverse_keyword_ref {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  return if not assert_uri_reference($state, $schema);
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  my $uri = Mojo::URL->new($schema->{'$ref'})->to_abs($state->{initial_schema_uri});
  my ($subschema, $canonical_uri, $document, $document_path) = $state->{evaluator}->_fetch_schema_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not defined $subschema;

  return $self->eval($data, $subschema,
    +{
      %{$document->evaluation_configs},
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$ref',
      initial_schema_uri => $canonical_uri,
      document => $document,
      document_path => $document_path,
      schema_path => '',
    });
}

sub _traverse_keyword_recursiveRef {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  return if not assert_uri_reference($state, $schema);
}

sub _eval_keyword_recursiveRef {
  my ($self, $data, $schema, $state) = @_;

  my $uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{initial_schema_uri});
  my ($subschema, $canonical_uri, $document, $document_path) = $state->{evaluator}->_fetch_schema_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not defined $subschema;

  if (is_type('boolean', $subschema->{'$recursiveAnchor'}) and $subschema->{'$recursiveAnchor'}) {
    $uri = Mojo::URL->new($schema->{'$recursiveRef'})
      ->to_abs($state->{recursive_anchor_uri} // $state->{initial_schema_uri});
    ($subschema, $canonical_uri, $document, $document_path) = $state->{evaluator}->_fetch_schema_from_uri($uri);
    abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not defined $subschema;
  }

  return $self->eval($data, $subschema,
    +{
      %{$document->evaluation_configs},
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$recursiveRef',
      initial_schema_uri => $canonical_uri,
      document => $document,
      document_path => $document_path,
      schema_path => '',
    });
}

sub _traverse_keyword_vocabulary {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'object');

  foreach my $property (sort keys %{$schema->{'$vocabulary'}}) {
    E($state, '$vocabulary/%s value is not a boolean', $property)
      if not is_type('boolean', $schema->{'$vocabulary'}{$property});

    assert_uri($state, $schema, $property);
  }

  return E($state, '$vocabulary can only appear at the schema resource root')
    if length($state->{schema_path});

  return E($state, '$vocabulary can only appear at the document root')
    if length($state->{traversed_schema_path}.$state->{schema_path});
}

# we do nothing with $vocabulary yet at evaluation time. When we know we are in a metaschema,
# we can scan the URIs included here and either abort if a vocabulary is enabled that we do not
# understand, or turn on and off certain keyword behaviours based on the boolean values seen.

sub _traverse_keyword_comment {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string');
}

# we do nothing with $comment at evaluation time, including not collecting its value for annotations.

sub _traverse_keyword_defs { shift->traverse_object_schemas(@_) }

# we do nothing directly with $defs at evaluation time, including not collecting its value for
# annotations.

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2019-09 "Core" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/core> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8>.

=cut
