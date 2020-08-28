use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :

our $VERSION = '0.013';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(is_type abort assert_keyword_type);
use Moo;
use strictures 2;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/core' }

sub keywords {
  qw($id $schema $anchor $recursiveAnchor $ref $recursiveRef $vocabulary $comment $defs);
}

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  abort($state, '$id value "%s" cannot have a non-empty fragment', $schema->{'$id'})
    if length Mojo::URL->new($schema->{'$id'})->fragment;

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
  my $uri = $state->{canonical_schema_uri}->clone;
  $uri->fragment(($uri->fragment//'').$state->{schema_path});
  abort($state, '"$recursiveAnchor" keyword used without "$id"') if length $uri->fragment;

  $state->{recursive_anchor_uri} = $uri;
  return 1;
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

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

sub _eval_keyword_recursiveRef {
  my ($self, $data, $schema, $state) = @_;

  assert_keyword_type($state, $schema, 'string');

  my $target_uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{canonical_schema_uri});
  my ($subschema, $canonical_uri, $document, $document_path) = $self->evaluator->_fetch_schema_from_uri($target_uri);
  abort($state, 'unable to find resource %s', $target_uri) if not defined $subschema;

  if (is_type('boolean', $subschema->{'$recursiveAnchor'})
      and $subschema->{'$recursiveAnchor'}) {
    my $base = $state->{recursive_anchor_uri} // $state->{canonical_schema_uri};
    abort($state, 'cannot resolve a $recursiveRef with a non-empty fragment against a $recursiveAnchor location with a canonical URI containing a fragment')
      if $schema->{'$recursiveRef'} ne '#' and length $base->fragment;

    my $uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($base);
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

1;
__END__

=pod

=for Pod::Coverage keywords

=cut
