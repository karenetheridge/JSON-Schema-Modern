use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(is_type jsonp abort assert_keyword_type canonical_schema_uri);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/core' }

sub keywords {
  qw($id $schema $anchor $recursiveAnchor $ref $recursiveRef $vocabulary $comment $defs);
}

# adds the following keys to $state during traversal:
# - identifiers: an arrayref of tuples:
#   $uri => { path => $path_to_identifier, canonical_uri => Mojo::URL (absolute when possible) }

sub _traverse_keyword_id {
  my ($self, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{'$id'});
  abort($state, '$id value "%s" cannot have a non-empty fragment', $schema->{'$id'})
    if length $uri->fragment;

  $uri->fragment(undef);
  $state->{canonical_schema_uri} = $uri->is_abs ? $uri
    : $uri->to_abs($state->{canonical_schema_uri});
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{schema_path} = '';

  push @{$state->{identifiers}},
    $state->{canonical_schema_uri} => {
      path => $state->{traversed_schema_path},
      canonical_uri => $state->{canonical_schema_uri}->clone,
    };
}

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  if (my $canonical_uri = $state->{document}->_path_to_canonical_uri($state->{document_path}.$state->{schema_path})) {
    $state->{canonical_schema_uri} = $canonical_uri->clone;
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

  assert_keyword_type($state, $schema, 'string');

  my $uri = canonical_schema_uri($state);
  abort($state, '$schema can only appear at the schema resource root') if length($uri->fragment);

  abort($state, 'custom $schema references are not yet supported')
    if $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';
}

# we do nothing with $schema yet at evaluation time. In the future, at traversal time we will fetch
# the schema at the value of this keyword and examine its $vocabulary keyword to determine which
# vocabularies shall be in effect when considering this schema, then storing those vocabulary
# instances in $state.
# If no $schema is provided at the top level, we will assume the default set defined by the
# specification metaschema (all six vocabularies).
# At evaluation time we simply swap out the vocabulary instances in $state.

sub _traverse_keyword_anchor {
  my ($self, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  abort($state, '$anchor value "%s" does not match required syntax', $schema->{'$anchor'})
    if $schema->{'$anchor'} !~ /^[A-Za-z][A-Za-z0-9_:.-]+$/;

  my $canonical_uri = canonical_schema_uri($state);

  push @{$state->{identifiers}},
    Mojo::URL->new->to_abs($canonical_uri)->fragment($schema->{'$anchor'}) => {
      path => $state->{traversed_schema_path}.$state->{schema_path},
      canonical_uri => $canonical_uri,
    };
}

# we already indexed the $anchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{canonical_schema_uri}.

sub _traverse_keyword_recursiveAnchor {
  my ($self, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'boolean');

  return if not $schema->{'$recursiveAnchor'};

  my $uri = canonical_schema_uri($state);
  abort($state, '"$recursiveAnchor" keyword used without "$id"') if length $uri->fragment;
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
  assert_keyword_type($state, $schema, 'string');
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  my $uri = Mojo::URL->new($schema->{'$ref'})->to_abs($state->{canonical_schema_uri});
  my ($subschema, $canonical_uri, $document, $document_path) = $self->evaluator->_fetch_schema_from_uri($uri);
  abort($state, 'unable to find resource %s', $uri) if not defined $subschema;

  return $self->evaluator->_eval($data, $subschema,
    +{ %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$ref',
      canonical_schema_uri => $canonical_uri, # note: maybe not canonical yet until $id is processed
      document => $document,
      document_path => $document_path,
      schema_path => '',
    });
}

sub _traverse_keyword_recursiveRef {
  my ($self, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'string');
}

sub _eval_keyword_recursiveRef {
  my ($self, $data, $schema, $state) = @_;

  my $target_uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{canonical_schema_uri});
  my ($subschema, $canonical_uri, $document, $document_path) = $self->evaluator->_fetch_schema_from_uri($target_uri);
  abort($state, 'unable to find resource %s', $target_uri) if not defined $subschema;

  if (is_type('boolean', $subschema->{'$recursiveAnchor'}) and $subschema->{'$recursiveAnchor'}) {
    my $uri = Mojo::URL->new($schema->{'$recursiveRef'})
      ->to_abs($state->{recursive_anchor_uri} // $state->{canonical_schema_uri});
    ($subschema, $canonical_uri, $document, $document_path) = $self->evaluator->_fetch_schema_from_uri($uri);
    abort($state, 'unable to find resource %s', $uri) if not defined $subschema;
  }

  return $self->evaluator->_eval($data, $subschema,
    +{ %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$recursiveRef',
      canonical_schema_uri => $canonical_uri, # note: maybe not canonical yet until $id is processed
      document => $document,
      document_path => $document_path,
      schema_path => '',
    });
}

sub _traverse_keyword_vocabulary {
  my ($self, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'object');
}

# we do nothing with $vocabulary yet at evaluation time. When we know we are in a metaschema,
# we can scan the URIs included here and either abort if a vocabulary is enabled that we do not
# understand, or turn on and off certain keyword behaviours based on the boolean values seen.

sub _traverse_keyword_comment {
  my ($self, $schema, $state) = @_;
  assert_keyword_type($state, $schema, 'string');
}

# we do nothing with $comment at evaluation time, including not collecting its value for annotations.

sub _traverse_keyword_defs {
  my ($self, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'object');

  foreach my $property (sort keys %{$schema->{'$defs'}}) {
    $self->evaluator->_traverse($schema->{'$defs'}{$property},
      +{ %$state, schema_path => jsonp($state->{schema_path}, '$defs', $property) });
  }
}

# we do nothing directly with $defs at evaluation time, including not collecting its value for
# annotations.

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords

=cut