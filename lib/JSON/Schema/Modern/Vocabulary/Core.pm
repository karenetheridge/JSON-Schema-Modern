use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Core vocabulary

our $VERSION = '0.610';

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
use Ref::Util 'is_plain_hashref';
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
    '$schema',
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
  return if not assert_keyword_type($state, $schema, 'string');

  my $uri = Mojo::URL->new($schema->{$state->{keyword}});

  if ($state->{spec_version} =~ /^draft[467]$/) {
    # technically the draft4 spec allows this form, but we are not supporting it.
    if (length($uri->fragment)) {
      return E($state, '%s cannot change the base uri at the same time as declaring an anchor', $state->{keyword})
        if length($uri->clone->fragment(undef));

      return $class->_traverse_keyword_anchor($schema, $state);
    }
  }
  else {
    return if not assert_uri_reference($state, $schema);

    return E($state, '%s value "%s" cannot have a non-empty fragment', $state->{keyword}, $schema->{$state->{keyword}})
      if length $uri->fragment;
  }

  $uri->fragment(undef);
  return E($state, '%s cannot be empty', $state->{keyword}) if not length $uri;

  $uri = $uri->to_abs($state->{initial_schema_uri}) if not $uri->is_abs;

  return E($state, 'duplicate canonical uri "%s" found (original at path "%s")',
      $uri, $state->{identifiers}{$uri}{path})
    if exists $state->{identifiers}{$uri};

  $state->{initial_schema_uri} = $uri;
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  # we don't set or update document_path because it is identical to traversed_schema_path
  $state->{schema_path} = '';

  # Note that even though '$id' is considered ahead of '$schema' in the keyword list, we have
  # already parsed the '$schema' keyword (before we even started looping through all vocabularies)
  # and therefore this data (specification_version and vocabularies) is known to be correct.

  $state->{identifiers}{$uri} = {
    path => $state->{traversed_schema_path},
    canonical_uri => $uri,
    specification_version => $state->{spec_version}, # note! $schema keyword can change this
    vocabularies => $state->{vocabularies}, # reference, not copy
    configs => $state->{configs},
  };
  return 1;
}

sub _eval_keyword_id ($class, $data, $schema, $state) {
  # we already indexed the anchor uri, so there is nothing more to do at evaluation time.
  # we explicitly do NOT set $state->{initial_schema_uri} or change any other $state values.
  return 1
    if $state->{spec_version} =~ /^draft[467]$/ and $schema->{$state->{keyword}} =~ /^#/;

  # we could use _fetch_from_uri here to use the parent base uri to resolve against $id at our
  # current location, but looking up the current path in the resource index is faster.
  my $schema_info = $state->{document}->path_to_resource($state->{document_path}.$state->{schema_path});
  # this should never happen, if the pre-evaluation traversal was performed correctly
  abort($state, 'failed to resolve "%s" to canonical uri', $state->{keyword}) if not $schema_info;

  $state->{initial_schema_uri} = $schema_info->{canonical_uri}->clone;
  # these will already be set in all cases: at document root, or if we are here via a $ref
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{document_path} = $state->{document_path}.$state->{schema_path};
  $state->{schema_path} = '';
  # these will already be set if there is an adjacent $schema keyword, or if we are here via a $ref
  $state->{spec_version} = $schema_info->{specification_version};
  $state->{vocabularies} = $schema_info->{vocabularies};

  $state->@{keys $state->{configs}->%*} = values $state->{configs}->%*;
  push $state->{dynamic_scope}->@*, $state->{initial_schema_uri};

  return 1;
}

sub _traverse_keyword_schema ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string') or not assert_uri($state, $schema);

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

    if (not is_plain_hashref($schema_info->{schema})) {
      ()= E($state, 'metaschemas must be objects');
    }
    else {
      ($spec_version, $vocabularies) = $state->{evaluator}->_fetch_vocabulary_data({ %$state,
          keyword => '$vocabulary', initial_schema_uri => Mojo::URL->new($schema->{'$schema'}),
          traversed_schema_path => jsonp($state->{schema_path}, '$schema') },
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
      and length($state->{schema_path});

  # This is a bit of a chicken-and-egg situation. If we start off at draft2020-12, then all
  # keywords are valid, so we inspect and process the $schema keyword; this switches us to draft7
  # but now only the $ref keyword is respected and everything else should be ignored, so the
  # $schema keyword never happened, so now we're back to draft2020-12 again, and...?!
  # The only winning move is not to play.
  return E($state, '$schema and $ref cannot be used together in older drafts')
    if exists $schema->{'$ref'} and $spec_version =~ /^draft[467]$/;

  $state->{evaluator}->_set_metaschema_vocabulary_classes($schema->{'$schema'}, [ $spec_version, $vocabularies ]);
  $state->@{qw(spec_version vocabularies)} = ($spec_version, $vocabularies);
  return 1;
}

sub _eval_keyword_schema ($class, $data, $schema, $state) {
  # we can't always rely on metaschema information being set in $state (if we recursed into this
  # subschema from a parent, where the data is not already set via $ref), and we need to do it now
  # so the evaluator knows whether to look for an 'id' or an '$id' keyword next (which sets up the
  # remaining data in $state).
  $state->@{qw(spec_version vocabularies)} = $state->{evaluator}->_get_metaschema_vocabulary_classes($schema->{'$schema'})->@*;
  return 1;
}

sub _traverse_keyword_anchor ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');

  my $anchor = $schema->{$state->{keyword}};
  return E($state, '%s value "%s" does not match required syntax', $state->{keyword}, $anchor)
    if $state->{spec_version} =~ /^draft[467]$/ and $anchor !~ /^#[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{spec_version} eq 'draft2019-09' and $anchor !~ /^[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{spec_version} eq 'draft2020-12' and $anchor !~ /^[A-Za-z_][A-Za-z0-9._-]*$/;

  my $canonical_uri = canonical_uri($state);

  $anchor =~ s/^#// if $state->{spec_version} =~ /^draft[467]$/;
  my $uri = Mojo::URL->new->to_abs($canonical_uri)->fragment($anchor);
  my $base_uri = $canonical_uri->clone->fragment(undef);

  if (exists $state->{identifiers}{$base_uri}) {
    return E($state, 'duplicate anchor uri "%s" found (original at path "%s")',
        $uri, $state->{identifiers}{$base_uri}{anchors}{$anchor}{path})
      if exists(($state->{identifiers}{$base_uri}{anchors}//{})->{$anchor});

    use autovivification 'store';
    $state->{identifiers}{$base_uri}{anchors}{$anchor} = {
      canonical_uri => $canonical_uri,
      path => $state->{traversed_schema_path}.$state->{schema_path},
    };
  }
  # we need not be at the root of the resource schema, and we need not even have an entry
  # in 'identifiers' for our current base uri (if there was no $id at the root, or if
  # initial_schema_uri was overridden in the call to traverse())
  else {
    my $base_path = '';
    if (my $fragment = $canonical_uri->fragment) {
      # this shouldn't happen, as we also check this at the start of traverse
      return E($state, 'something is wrong; "%s" is not the suffix of "%s"', $fragment, $state->{traversed_schema_path}.$state->{schema_path})
        if substr($state->{traversed_schema_path}.$state->{schema_path}, -length($fragment))
          ne $fragment;
      $base_path = substr($state->{traversed_schema_path}.$state->{schema_path}, 0, -length($fragment));
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
      specification_version => $state->{spec_version},
      vocabularies => $state->{vocabularies}, # reference, not copy
      configs => $state->{configs},
      anchors => {
        $anchor => {
          canonical_uri => $canonical_uri,
          path => $state->{traversed_schema_path}.$state->{schema_path},
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
    if length($state->{schema_path});
  return 1;
}

sub _eval_keyword_recursiveAnchor ($class, $data, $schema, $state) {
  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  $state->{recursive_anchor_uri} = canonical_uri($state);
  return 1;
}

*_traverse_keyword_dynamicAnchor = \&_traverse_keyword_anchor;

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

  if (is_plain_hashref($schema_info->{schema})
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
      and is_plain_hashref($schema_info->{schema})
      and exists $schema_info->{schema}{'$dynamicAnchor'}
      and $uri->fragment eq (my $anchor = $schema_info->{schema}{'$dynamicAnchor'})) {
    # ...the initial URI MUST be replaced by the URI (including the fragment) for the outermost
    # schema resource in the dynamic scope that defines an identically named fragment with
    # "$dynamicAnchor".
    foreach my $base_scope ($state->{dynamic_scope}->@*) {
      my $test_uri = Mojo::URL->new($base_scope)->fragment($anchor);
      my $dynamic_anchor_subschema_info = $state->{evaluator}->_fetch_from_uri($test_uri);
      if (defined $dynamic_anchor_subschema_info and ($dynamic_anchor_subschema_info->{schema}{'$dynamicAnchor'}//'') eq $anchor) {
        $uri = $test_uri;
        last;
      }
    }
  }

  return $class->eval_subschema_at_uri($data, $schema, $state, $uri);
}

sub _traverse_keyword_vocabulary ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  return E($state, '$vocabulary can only appear at the schema resource root')
    if length($state->{schema_path});

  my $valid = 1;

  my @vocabulary_classes;
  foreach my $uri (sort keys $schema->{'$vocabulary'}->%*) {
    if (not is_type('boolean', $schema->{'$vocabulary'}{$uri})) {
      ()= E({ %$state, _schema_path_suffix => $uri }, '$vocabulary value at "%s" is not a boolean', $uri);
      $valid = 0;
      next;
    }

    $valid = 0 if not assert_uri({ %$state, _schema_path_suffix => $uri }, undef, $uri);
  }

  # we cannot return an error here for invalid or incomplete vocabulary lists, because
  # - the specification vocabulary schemas themselves don't list Core,
  # - it is possible for a metaschema to $ref to another metaschema that uses an unrecognized
  #   vocabulary uri while still validating those vocabulary keywords (e.g.
  #   https://spec.openapis.org/oas/3.1/schema-base/2021-05-20)
  # Instead, we will verify these constraints when we actually use the metaschema, in
  # _traverse_keyword_schema -> __fetch_vocabulary_data

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
