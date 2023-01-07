use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Core vocabulary

our $VERSION = '0.562';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::Schema::Modern::Utilities qw(is_type abort assert_keyword_type canonical_uri E assert_uri_reference assert_uri jsonp);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/core' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/core' => 'draft2020-12';
}

sub evaluation_order { 0 }

sub keywords ($self, $spec_version) {
  return (
    qw($id $schema),
    $spec_version ne 'draft7' ? '$anchor' : (),
    $spec_version eq 'draft2019-09' ? '$recursiveAnchor' : (),
    $spec_version eq 'draft2020-12' ? '$dynamicAnchor' : (),
    '$ref',
    $spec_version eq 'draft2019-09' ? '$recursiveRef' : (),
    $spec_version eq 'draft2020-12' ? '$dynamicRef' : (),
    $spec_version eq 'draft7' ? 'definitions' : qw($vocabulary $comment $defs),
  );
}

# adds the following keys to $state during traversal:
# - identifiers: an arrayref of tuples:
#   $uri => { path => $path_to_identifier, canonical_uri => Mojo::URL (absolute when possible) }
# this is used by the Document constructor to build its resource_index.

sub _traverse_keyword_id ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_uri_reference($state, $schema);

  my $uri = Mojo::URL->new($schema->{'$id'});

  if ($state->{spec_version} eq 'draft7') {
    if (length($uri->fragment)) {
      return E($state, '$id cannot change the base uri at the same time as declaring an anchor')
        if length($uri->clone->fragment(undef));

      return $self->_traverse_keyword_anchor({ %$schema, $state->{keyword} => $uri->fragment }, $state);
    }
  }
  else {
    return E($state, '$id value "%s" cannot have a non-empty fragment', $schema->{'$id'})
      if length $uri->fragment;
  }

  $uri->fragment(undef);
  return E($state, '$id cannot be empty') if not length $uri;

  $state->{initial_schema_uri} = $uri->is_abs ? $uri : $uri->to_abs($state->{initial_schema_uri});
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  # we don't set or update document_path because it is identical to traversed_schema_path
  $state->{schema_path} = '';

  push $state->{identifiers}->@*,
    $state->{initial_schema_uri} => {
      path => $state->{traversed_schema_path},
      canonical_uri => $state->{initial_schema_uri}->clone,
      specification_version => $state->{spec_version}, # note! $schema keyword can change this
      vocabularies => $state->{vocabularies}, # reference, not copy
      configs => $state->{configs},
    };
  return 1;
}

sub _eval_keyword_id ($self, $data, $schema, $state) {
  my $schema_info = $state->{document}->path_to_resource($state->{document_path}.$state->{schema_path});
  # this should never happen, if the pre-evaluation traversal was performed correctly
  abort($state, 'failed to resolve %s to canonical uri', $state->{keyword}) if not $schema_info;

  $state->{initial_schema_uri} = $schema_info->{canonical_uri}->clone;
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{document_path} = $state->{document_path}.$state->{schema_path};
  $state->{schema_path} = '';
  $state->{spec_version} = $schema_info->{specification_version};
  $state->{vocabularies} = $schema_info->{vocabularies};

  if ($state->{validate_formats}) {
    $state->{vocabularies} = [
      map s/^JSON::Schema::Modern::Vocabulary::Format\KAnnotation$/Assertion/r, $state->{vocabularies}->@*
    ];
    require JSON::Schema::Modern::Vocabulary::FormatAssertion;
  }

  $state->@{keys $state->{configs}->%*} = values $state->{configs}->%*;
  push $state->{dynamic_scope}->@*, $state->{initial_schema_uri};

  return 1;
}

sub _traverse_keyword_schema ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string') or not assert_uri($state, $schema);

  # "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
  # "A resource's root schema is its top-level schema object."
  # note: we need not be at the document root, but simply adjacent to an $id (or be the at the
  # document root)
  return E($state, '$schema can only appear at the schema resource root')
    if length($state->{schema_path});

  my ($spec_version, $vocabularies);

  if (my $metaschema_info = $state->{evaluator}->_get_metaschema_vocabulary_classes($schema->{'$schema'})) {
    ($spec_version, $vocabularies) = @$metaschema_info;
  }
  else {
    my $schema_info = $state->{evaluator}->_fetch_from_uri($schema->{'$schema'});
    return E($state, 'EXCEPTION: unable to find resource %s', $schema->{'$schema'}) if not $schema_info;

    ($spec_version, $vocabularies) = $self->__fetch_vocabulary_data({ %$state,
        keyword => '$vocabulary', initial_schema_uri => Mojo::URL->new($schema->{'$schema'}),
        traversed_schema_path => jsonp($state->{schema_path}, '$schema'),
      }, $schema_info);
  }

  return E($state, '"%s" is not a valid metaschema', $schema->{'$schema'}) if not @$vocabularies;

  # we special-case this because the check in _eval_subschema for older drafts + $ref has already happened
  return E($state, '$schema and $ref cannot be used together in older drafts')
    if exists $schema->{'$ref'} and $spec_version eq 'draft7';

  $state->@{qw(spec_version vocabularies)} = ($spec_version, $vocabularies);

  # remember, if we don't have a sibling $id, we must be at the document root with no identifiers
  if ($state->{identifiers}->@*) {
    $state->{identifiers}[-1]->@{qw(specification_version vocabularies)} = $state->@{qw(spec_version vocabularies)};
  }

  return 1;
}

sub _traverse_keyword_anchor ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');

  return E($state, '%s value "%s" does not match required syntax',
      $state->{keyword}, ($state->{keyword} eq '$id' ? '#' : '').$schema->{$state->{keyword}})
    if $state->{spec_version} =~ /^draft(?:7|2019-09)$/
        and $schema->{$state->{keyword}} !~ /^[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{spec_version} eq 'draft2020-12'
        and $schema->{$state->{keyword}} !~ /^[A-Za-z_][A-Za-z0-9._-]*$/;

  my $canonical_uri = canonical_uri($state);

  push $state->{identifiers}->@*,
    Mojo::URL->new->to_abs($canonical_uri)->fragment($schema->{$state->{keyword}}) => {
      path => $state->{traversed_schema_path}.$state->{schema_path},
      canonical_uri => $canonical_uri,
      specification_version => $state->{spec_version},
      vocabularies => $state->{vocabularies}, # reference, not copy
      configs => $state->{configs},
    };
  return 1;
}

# we already indexed the $anchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_recursiveAnchor ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'boolean');

  # this is required because the location is used as the base URI for future resolution
  # of $recursiveRef, and the fragment would be disregarded in the base
  return E($state, '"$recursiveAnchor" keyword used without "$id"')
    if length($state->{schema_path});
  return 1;
}

sub _eval_keyword_recursiveAnchor ($self, $data, $schema, $state) {
  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  $state->{recursive_anchor_uri} = canonical_uri($state);
  return 1;
}

sub _traverse_keyword_dynamicAnchor { shift->_traverse_keyword_anchor(@_) }

# we already indexed the $dynamicAnchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_ref ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_uri_reference($state, $schema);
  return 1;
}

sub _eval_keyword_ref ($self, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$ref'})->to_abs($state->{initial_schema_uri});
  $self->eval_subschema_at_uri($data, $schema, $state, $uri);
}

sub _traverse_keyword_recursiveRef { shift->_traverse_keyword_ref(@_) }

sub _eval_keyword_recursiveRef ($self, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;

  if (is_type('boolean', $schema_info->{schema}{'$recursiveAnchor'}) and $schema_info->{schema}{'$recursiveAnchor'}) {
    $uri = Mojo::URL->new($schema->{'$recursiveRef'})
      ->to_abs($state->{recursive_anchor_uri} // $state->{initial_schema_uri});
  }

  return $self->eval_subschema_at_uri($data, $schema, $state, $uri);
}

sub _traverse_keyword_dynamicRef { shift->_traverse_keyword_ref(@_) }

sub _eval_keyword_dynamicRef ($self, $data, $schema, $state) {
  my $uri = Mojo::URL->new($schema->{'$dynamicRef'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;

  # If the initially resolved starting point URI includes a fragment that was created by the
  # "$dynamicAnchor" keyword, ...
  if (length $uri->fragment and exists $schema_info->{schema}{'$dynamicAnchor'}
      and $uri->fragment eq (my $anchor = $schema_info->{schema}{'$dynamicAnchor'})) {
    # ...the initial URI MUST be replaced by the URI (including the fragment) for the outermost
    # schema resource in the dynamic scope that defines an identically named fragment with
    # "$dynamicAnchor".
    foreach my $base_scope ($state->{dynamic_scope}->@*) {
      my $test_uri = Mojo::URL->new($base_scope)->fragment($anchor);
      my $dynamic_anchor_subschema_info = $state->{evaluator}->_fetch_from_uri($test_uri);
      if (($dynamic_anchor_subschema_info->{schema}->{'$dynamicAnchor'}//'') eq $anchor) {
        $uri = $test_uri;
        last;
      }
    }
  }

  return $self->eval_subschema_at_uri($data, $schema, $state, $uri);
}

sub _traverse_keyword_vocabulary ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'object');

  return E($state, '$vocabulary can only appear at the schema resource root')
    if length($state->{schema_path});

  my $valid = 1;

  my @vocabulary_classes;
  foreach my $uri (sort keys $schema->{'$vocabulary'}->%*) {
    $valid = 0, next if not assert_keyword_type({ %$state, _schema_path_suffix => $uri }, $schema, 'boolean');
    $valid = 0, next if not assert_uri({ %$state, _schema_path_suffix => $uri }, undef, $uri);
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

sub _traverse_keyword_comment ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

# we do nothing with $comment at evaluation time, including not collecting its value for annotations.

sub _traverse_keyword_definitions { shift->traverse_object_schemas(@_) }
sub _traverse_keyword_defs { shift->traverse_object_schemas(@_) }

# we do nothing directly with $defs at evaluation time, including not collecting its value for
# annotations.


# translate vocabulary URIs into classes, caching the results (if any)
sub __fetch_vocabulary_data ($self, $state, $schema_info) {
  if (not exists $schema_info->{schema}{'$vocabulary'}) {
    # "If "$vocabulary" is absent, an implementation MAY determine behavior based on the meta-schema
    # if it is recognized from the URI value of the referring schema's "$schema" keyword."
    my $metaschema_uri = $state->{evaluator}->METASCHEMA_URIS->{$schema_info->{specification_version}};
    return $state->{evaluator}->_get_metaschema_vocabulary_classes($metaschema_uri)->@*;
  }

  my $valid = 1;
  $valid = E($state, '$vocabulary can only appear at the document root') if length $schema_info->{document_path};
  $valid = E($state, 'metaschemas must have an $id') if not exists $schema_info->{schema}{'$id'};

  return (undef, []) if not $valid;

  my @vocabulary_classes;

  foreach my $uri (sort keys $schema_info->{schema}{'$vocabulary'}->%*) {
    my $class_info = $state->{evaluator}->_get_vocabulary_class($uri);
    $valid = E({ %$state, _schema_path_suffix => $uri }, '"%s" is not a known vocabulary', $uri), next
      if $schema_info->{schema}{'$vocabulary'}{$uri} and not $class_info;

    next if not $class_info;  # vocabulary is not known, but marked as false in the metaschema

    my ($spec_version, $class) = @$class_info;
    $valid = E({ %$state, _schema_path_suffix => $uri }, '"%s" uses %s, but the metaschema itself uses %s',
        $uri, $spec_version, $schema_info->{specification_version}), next
      if $spec_version ne $schema_info->{specification_version};

    push @vocabulary_classes, $class;
  }

  @vocabulary_classes = sort {
    $a->evaluation_order <=> $b->evaluation_order
    || ($a->evaluation_order == 999 ? 0
      : ($valid = E($state, '%s and %s have a conflicting evaluation_order', sort $a, $b)))
  } @vocabulary_classes;

  $valid = E($state, 'the first vocabulary (by evaluation_order) must be Core')
    if ($vocabulary_classes[0]//'') ne 'JSON::Schema::Modern::Vocabulary::Core';

  $state->{evaluator}->_set_metaschema_vocabulary_classes($schema_info->{canonical_uri},
    [ $schema_info->{specification_version}, \@vocabulary_classes ]) if $valid;

  return ($schema_info->{specification_version}, $valid ? \@vocabulary_classes : []);
}

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

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
