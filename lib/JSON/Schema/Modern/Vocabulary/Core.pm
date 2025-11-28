use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Core vocabulary

our $VERSION = '0.625';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use JSON::Schema::Modern::Utilities qw(is_type abort assert_keyword_type canonical_uri E assert_uri_reference assert_uri jsonp);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary ($class) {
  'https://json-schema.org/draft/2019-09/vocab/core' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/core' => 'draft2020-12';
}

sub evaluation_order ($class) { 0 }

sub keywords ($class, $spec_version) {
  return (
    '$schema',  # must be first to ensure we use the correct Core keywords and subsequent vocabularies
    $spec_version eq 'draft4' ? 'id' : '$id',
    $spec_version !~ /^draft[467]$/ ? '$anchor' : (),
    $spec_version eq 'draft2019-09' ? '$recursiveAnchor' : (),
    $spec_version !~ /^draft(?:[467]|2019-09)$/ ? '$dynamicAnchor' : (),
    '$ref',
    $spec_version eq 'draft2019-09' ? '$recursiveRef' : (),
    $spec_version !~ /^draft(?:[467]|2019-09)$/ ? '$dynamicRef' : (),
    $spec_version !~ /^draft[467]$/ ? '$vocabulary' : (),
    $spec_version =~ /^draft[467]$/ ? 'definitions' : '$defs',
    $spec_version !~ /^draft[46]$/ ? '$comment' : (),
  );
}

# adds the following keys to $state during traversal:
# - identifiers: an arrayref of tuples:
#   $uri => { path => $path_to_identifier, canonical_uri => Mojo::URL (absolute when possible) }
# this is used by the Document constructor to build its resource_index.

sub _traverse_keyword_id ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_uri_reference($state, $schema);

  my $uri = Mojo::URL->new($schema->{$state->{keyword}});

  if (length $uri->fragment) {
    return E($state, '%s value "%s" cannot have a non-empty fragment', $state->{keyword}, $schema->{$state->{keyword}})
      if $state->{specification_version} !~ /^draft[467]$/;

    if (length(my $base = $uri->clone->fragment(undef))) {
      return E($state, '$id cannot change the base uri at the same time as declaring an anchor')
        if $state->{specification_version} =~ /^draft[67]$/;

      # only permitted in draft4: add an id and an anchor via the single 'id' keyword
      return if not $class->__create_identifier($base, $state);
    }

    return $class->_traverse_keyword_anchor({ %$schema, id => '#'.$uri->fragment }, $state);
  }

  return if not $class->__create_identifier($uri, $state);
  return 1;
}

sub __create_identifier ($class, $uri, $state) {
  $uri->fragment(undef);
  return E($state, '%s cannot be empty', $state->{keyword}) if not length $uri;

  $uri = $uri->to_abs($state->{initial_schema_uri}) if not $uri->is_abs;

  return E($state, 'duplicate canonical uri "%s" found (original at path "%s")',
      $uri, $state->{identifiers}{$uri}{path})
    if exists $state->{identifiers}{$uri};

  $state->{initial_schema_uri} = $uri;
  $state->{traversed_keyword_path} = $state->{traversed_keyword_path}.$state->{keyword_path};
  $state->{keyword_path} = '';

  # Note that since '$schema' is considered ahead of '$id' in the keyword list, the dialect
  # (specification_version and vocabularies) is known to be correct.

  $state->{identifiers}{$uri} = {
    path => $state->{traversed_keyword_path},
    canonical_uri => $uri,
    $state->%{qw(specification_version vocabularies)},
  };

  return 1;
}

sub _eval_keyword_id ($class, $data, $schema, $state) {
  # we already indexed the anchor uri, so there is nothing more to do at evaluation time.
  # we explicitly do NOT set $state->{initial_schema_uri} or change any other $state values.
  return 1
    if $state->{specification_version} =~ /^draft[467]$/ and $schema->{$state->{keyword}} =~ /^#/;

  my $schema_info = $state->{evaluator}->_fetch_from_uri($state->{initial_schema_uri}->clone->fragment($state->{keyword_path}));

  # this should never happen, if the pre-evaluation traversal was performed correctly
  abort($state, 'failed to resolve "%s" to canonical uri', $state->{keyword}) if not $schema_info;

  # $state->{document} is set by evaluate() and does not change unless following a reference
  abort($state, 'EXCEPTION: mismatched document when processing %s "%s"',
      $state->{keyword}, $schema->{$state->{keyword}})
    if $schema_info->{document} != $state->{document};

  # these will all be set when we are at the document root, or if we are here via a $ref,
  # but not if we are organically passing through this subschema.
  $state->{initial_schema_uri} = $schema_info->{canonical_uri};
  $state->{traversed_keyword_path} = $state->{traversed_keyword_path}.$state->{keyword_path};
  $state->{keyword_path} = '';
  $state->@{qw(specification_version vocabularies)} = $schema_info->@{qw(specification_version vocabularies)};

  push $state->{dynamic_scope}->@*, $state->{initial_schema_uri}
    if $state->{dynamic_scope}->[-1] ne $schema_info->{canonical_uri};

  return 1;
}

sub _traverse_keyword_schema ($class, $schema, $state) {
  # Note that this sub is sometimes called with $state->{keyword} undefined, in order to change
  # error locations

  # Note that because this keyword is parsed ahead of "id"/"$id", location information may not
  # be correct if an error occurs when parsing this keyword.
  return E($state, '$schema value is not a string') if not is_type('string', $schema->{'$schema'});
  return if not assert_uri($state, $schema, $schema->{'$schema'});

  my ($spec_version, $vocabularies);

  if (my $metaschema_info = $state->{evaluator}->_get_metaschema_vocabulary_classes($schema->{'$schema'})) {
    ($spec_version, $vocabularies) = @$metaschema_info;
  }
  else {
    my $schema_info = $state->{evaluator}->_fetch_from_uri($schema->{'$schema'});
    return E($state, 'EXCEPTION: unable to find resource "%s"', $schema->{'$schema'}) if not $schema_info;
    # this cannot happen unless there are other entity types in the index
    return E($state, 'EXCEPTION: bad reference to $schema "%s": not a schema', $schema_info->{canonical_uri})
      if $schema_info->{document}->get_entity_at_location($schema_info->{document_path}) ne 'schema';

    if (ref $schema_info->{schema} ne 'HASH') {
      ()= E($state, 'metaschemas must be objects');
    }
    else {
      ($spec_version, $vocabularies) = $state->{evaluator}->_fetch_vocabulary_data({ %$state,
          keyword => '$vocabulary', initial_schema_uri => Mojo::URL->new($schema->{'$schema'}),
          traversed_keyword_path => jsonp($state->{traversed_keyword_path}.$state->{keyword_path}, $state->{keyword}) },
        $schema_info);
    }
  }

  return E($state, '"%s" is not a valid metaschema', $schema->{'$schema'})
    if not $vocabularies or not @$vocabularies;

  # "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
  # "A resource's root schema is its top-level schema object."
  # note: we need not be at the document root, but simply adjacent to an $id (or be the at the
  # document root)
  return E($state, '$schema can only appear at the schema resource root')
    if not exists $schema->{$spec_version eq 'draft4' ? 'id' : '$id'}
      and length($state->{keyword_path});

  # This is a bit of a chicken-and-egg situation. If we start off at draft2020-12, then all
  # keywords are valid, so we inspect and process the $schema keyword; this switches us to draft7
  # but now only the $ref keyword is respected and everything else should be ignored, so the
  # $schema keyword never happened, so now we're back to draft2020-12 again, and...?!
  # The only winning move is not to play.
  return E($state, '$schema and $ref cannot be used together in older drafts')
    if exists $schema->{'$ref'} and $spec_version =~ /^draft[467]$/;

  $state->{evaluator}->_set_metaschema_vocabulary_classes($schema->{'$schema'}, [ $spec_version, $vocabularies ]);
  $state->@{qw(specification_version vocabularies metaschema_uri)} = ($spec_version, $vocabularies, $schema->{'$schema'} =~ s/#$//r);
  return 1;
}

sub _eval_keyword_schema ($class, $data, $schema, $state) {
  # the dialect can change at any time, even in the middle of a document, where subsequent keywords
  # and vocabularies can change; however if we came to this schema via a $ref it will already be
  # set correctly
  $state->@{qw(specification_version vocabularies)} = $state->{evaluator}->_get_metaschema_vocabulary_classes($schema->{'$schema'})->@*;
  return 1;
}

sub _traverse_keyword_anchor ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');

  my $anchor = $schema->{$state->{keyword}};
  return E($state, '%s value "%s" does not match required syntax', $state->{keyword}, $anchor)
    if $state->{specification_version} =~ /^draft[467]$/  and $anchor !~ /^#[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{specification_version} eq 'draft2019-09' and $anchor !~ /^[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{specification_version} eq 'draft2020-12' and $anchor !~ /^[A-Za-z_][A-Za-z0-9._-]*$/;

  my $canonical_uri = canonical_uri($state);

  $anchor =~ s/^#// if $state->{specification_version} =~ /^draft[467]$/;
  my $uri = Mojo::URL->new->to_abs($canonical_uri)->fragment($anchor);
  my $base_uri = $canonical_uri->clone->fragment(undef);

  if (exists $state->{identifiers}{$base_uri}) {
    return E($state, 'duplicate anchor uri "%s" found (original at path "%s")',
        $uri, $state->{identifiers}{$base_uri}{anchors}{$anchor}{path})
      if exists(($state->{identifiers}{$base_uri}{anchors}//{})->{$anchor});

    use autovivification 'store';
    $state->{identifiers}{$base_uri}{anchors}{$anchor} = {
      canonical_uri => $canonical_uri,
      path => $state->{traversed_keyword_path}.$state->{keyword_path},
    };
  }
  # we need not be at the root of the resource schema, and we need not even have an entry
  # in 'identifiers' for our current base uri (if there was no $id at the root, or if
  # initial_schema_uri was overridden in the call to traverse())
  else {
    my $base_path = '';
    if (my $fragment = $canonical_uri->fragment) {
      # this shouldn't happen, as we also check this at the start of traverse
      return E($state, 'something is wrong; "%s" is not the suffix of "%s"', $fragment, $state->{traversed_keyword_path}.$state->{keyword_path})
        if substr($state->{traversed_keyword_path}.$state->{keyword_path}, -length($fragment))
          ne $fragment;
      $base_path = substr($state->{traversed_keyword_path}.$state->{keyword_path}, 0, -length($fragment));
    }

    $state->{identifiers}{$base_uri} = {
      # We didn't see an $id keyword at this position or above us, so a resource entry hasn't been
      # made yet for this identifier. However, we have all the information we need to infer its
      # data. If this entry is being created in a subschema (below the document root), another one
      # just like it may be created by another subschema using the same base canonical uri, so that
      # caller will need to merge the entries together before providing them to the Document's
      # resource index.
      canonical_uri => $base_uri,
      path => $base_path,
      $state->%{qw(specification_version vocabularies)},
      anchors => {
        $anchor => {
          canonical_uri => $canonical_uri,
          path => $state->{traversed_keyword_path}.$state->{keyword_path},
        },
      },
    };
  }

  return 1;
}

# we already indexed the $anchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_recursiveAnchor ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'boolean');

  # this is required because the location is used as the base URI for future resolution
  # of $recursiveRef, and the fragment would be disregarded in the base
  return E($state, '"$recursiveAnchor" keyword used without "$id"')
    if length($state->{keyword_path});
  return 1;
}

sub _eval_keyword_recursiveAnchor ($class, $data, $schema, $state) {
  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  $state->{recursive_anchor_uri} = canonical_uri($state);
  return 1;
}

sub _traverse_keyword_dynamicAnchor ($class, $schema, $state) {
  return if not $class->_traverse_keyword_anchor($schema, $state);
  $state->{identifiers}{$state->{initial_schema_uri}}{anchors}{$schema->{'$dynamicAnchor'}}{dynamic} = 1;
}

# we already indexed the $dynamicAnchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_ref ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_uri_reference($state, $schema);
  return 1;
}

sub _eval_keyword_ref ($class, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$ref'})->to_abs($state->{initial_schema_uri});
  $class->eval_subschema_at_uri($data, $schema, $state, $uri);
}

*_traverse_keyword_recursiveRef = \&_traverse_keyword_ref;

sub _eval_keyword_recursiveRef ($class, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource "%s"', $uri) if not $schema_info;
  abort($state, 'EXCEPTION: bad reference to "%s": not a schema', $schema_info->{canonical_uri})
    if $schema_info->{document}->get_entity_at_location($schema_info->{document_path}) ne 'schema';

  if (ref $schema_info->{schema} eq 'HASH'
      and is_type('boolean', $schema_info->{schema}{'$recursiveAnchor'})
      and $schema_info->{schema}{'$recursiveAnchor'}) {
    $uri = Mojo::URL->new($schema->{'$recursiveRef'})
      ->to_abs($state->{recursive_anchor_uri} // $state->{initial_schema_uri});
  }

  return $class->eval_subschema_at_uri($data, $schema, $state, $uri);
}

*_traverse_keyword_dynamicRef = \&_traverse_keyword_ref;

sub _eval_keyword_dynamicRef ($class, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$dynamicRef'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource "%s"', $uri) if not $schema_info;
  abort($state, 'EXCEPTION: bad reference to "%s": not a schema', $schema_info->{canonical_uri})
    if $schema_info->{document}->get_entity_at_location($schema_info->{document_path}) ne 'schema';

  # If the initially resolved starting point URI includes a fragment that was created by the
  # "$dynamicAnchor" keyword, ...
  if (length $uri->fragment
      and ref $schema_info->{schema} eq 'HASH'
      and exists $schema_info->{schema}{'$dynamicAnchor'}
      and $uri->fragment eq (my $anchor = $schema_info->{schema}{'$dynamicAnchor'})) {
    # ...the initial URI MUST be replaced by the URI (including the fragment) for the outermost
    # schema resource in the dynamic scope that defines an identically named fragment with
    # "$dynamicAnchor".
    foreach my $scope_uri ($state->{dynamic_scope}->@*) {
      my $resource = $state->{evaluator}->_get_or_load_resource($scope_uri);
      die 'bad dynamic scope uri: ', $scope_uri if not $resource;
      if (exists(($resource->{anchors}//{})->{$anchor}) and $resource->{anchors}{$anchor}{dynamic}) {
        $uri = Mojo::URL->new($scope_uri)->fragment($anchor);
        last;
      }
    }
  }

  return $class->eval_subschema_at_uri($data, $schema, $state, $uri);
}

sub _traverse_keyword_vocabulary ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  return E($state, '$vocabulary can only appear at the schema resource root')
    if length($state->{keyword_path});

  my $valid = 1;

  my @vocabulary_classes;
  foreach my $uri (sort keys $schema->{'$vocabulary'}->%*) {
    if (not is_type('boolean', $schema->{'$vocabulary'}{$uri})) {
      ()= E({ %$state, _keyword_path_suffix => $uri }, '$vocabulary value at "%s" is not a boolean', $uri);
      $valid = 0;
      next;
    }

    $valid = 0 if not assert_uri({ %$state, _keyword_path_suffix => $uri }, undef, $uri);
  }

  # we cannot return an error here for invalid or incomplete vocabulary lists, because
  # - the specification vocabulary schemas themselves don't list Core,
  # - it is possible for a metaschema to $ref to another metaschema that uses an unrecognized
  #   vocabulary uri while still validating those vocabulary keywords (e.g.
  #   https://spec.openapis.org/oas/3.1/schema-base/2021-05-20)
  # Instead, we will verify these constraints when we actually use the metaschema, in
  # _traverse_keyword_schema -> _fetch_vocabulary_data

  return $valid;
}

# we do nothing with $vocabulary yet at evaluation time. When we know we are in a metaschema,
# we can scan the URIs included here and either abort if a vocabulary is enabled that we do not
# understand, or turn on and off certain keyword behaviours based on the boolean values seen.

sub _traverse_keyword_comment ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

# we do nothing with $comment at evaluation time, including not collecting its value for annotations.

sub _traverse_keyword_definitions { shift->traverse_object_schemas(@_) }
sub _traverse_keyword_defs { shift->traverse_object_schemas(@_) }

# we do nothing directly with $defs at evaluation time, including not collecting its value for
# annotations.

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Core" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/core> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-core.html#section-8>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/core> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-02#section-8>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-01>.
* the equivalent Draft 6 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-06/draft-wright-json-schema-01>.
* the equivalent Draft 4 keywords that correspond to this vocabulary and are formally specified in
  L<https://json-schema.org/draft-04/draft-zyp-json-schema-04>.

=cut
