use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Core;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Core vocabulary

our $VERSION = '0.518';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities qw(is_type abort assert_keyword_type canonical_schema_uri E assert_uri_reference assert_uri);
use Moo;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  my ($self, $spec_version) = @_;
  return
      $spec_version eq 'draft2019-09' ? 'https://json-schema.org/draft/2019-09/vocab/core'
    : $spec_version eq 'draft2020-12' ? 'https://json-schema.org/draft/2020-12/vocab/core'
    : undef;
}

sub keywords {
  my ($self, $spec_version) = @_;
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

# supported metaschema URIs. is a subset of JSON::Schema::Modern::CACHED_METASCHEMAS
my %version_uris = (
  'https://json-schema.org/draft/2020-12/schema'  => 'draft2020-12',
  'https://json-schema.org/draft/2019-09/schema'  => 'draft2019-09',
  'http://json-schema.org/draft-07/schema#'       => 'draft7',
);

# adds the following keys to $state during traversal:
# - identifiers: an arrayref of tuples:
#   $uri => { path => $path_to_identifier, canonical_uri => Mojo::URL (absolute when possible) }
# this is used by the Document constructor to build its resource_index.

sub _traverse_keyword_id {
  my ($self, $schema, $state) = @_;

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

  push @{$state->{identifiers}},
    $state->{initial_schema_uri} => {
      path => $state->{traversed_schema_path},
      canonical_uri => $state->{initial_schema_uri}->clone,
    };
  return 1;
}

sub _eval_keyword_id {
  my ($self, $data, $schema, $state) = @_;

  my $schema_info = $state->{document}->path_to_resource($state->{document_path}.$state->{schema_path});
  # this should never happen, if the pre-evaluation traversal was performed correctly
  abort($state, 'failed to resolve %s to canonical uri', $state->{keyword}) if not $schema_info;

  $state->{initial_schema_uri} = $schema_info->{canonical_uri}->clone;
  $state->{traversed_schema_path} = $state->{traversed_schema_path}.$state->{schema_path};
  $state->{document_path} = $state->{document_path}.$state->{schema_path};
  $state->{schema_path} = '';
  push @{$state->{dynamic_scope}}, $state->{initial_schema_uri};

  return 1;
}

sub _traverse_keyword_schema {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string') or not assert_uri($state, $schema);

  # "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
  # "A resource's root schema is its top-level schema object."
  # note: we need not be at the document root, but simply adjacent to an $id (or be the at the
  # document root)
  return E($state, '$schema can only appear at the schema resource root')
    if length($state->{schema_path});

  my $spec_version = $version_uris{$schema->{'$schema'}};
  return E($state, 'custom $schema URIs are not yet supported (must be one of: %s',
      join(', ', map '"'.$_.'"', sort keys %version_uris))
    if not $spec_version;

  # The spec version cannot change as we traverse through a schema document, due to the race
  # condition involved in supporting different core keyword semantics before we can parse the
  # keywords that tell us what those semantics are.
  # To support different dialects, we will record the local dialect in the document object for
  # swapping out during evaluation and following $refs. We must also store a value to be populated
  # into $state->{validate_formats}, if one of the format vocabularies is included.
  return E($state, '"$schema" indicates a different version than that requested by \'specification_version\'')
    if $state->{evaluator}->specification_version
      and $spec_version ne $state->{evaluator}->specification_version;

  return E($state, 'draft specification version cannot change within a single schema document')
    if $spec_version ne $state->{spec_version} and length($state->{traversed_schema_path});

  # we special-case this because the check in _eval_subschema for older drafts + $ref has already happened
  return E($state, '$schema and $ref cannot be used together in older drafts')
    if exists $schema->{'$ref'} and $spec_version eq 'draft7';

  $state->{spec_version} = $spec_version;
  return 1;
}

# In the future, at traversal time we will fetch the schema at the value of this keyword and examine
# its $vocabulary keyword to determine which dialect shall be in effect when considering this
# schema, then storing that dialect instance in $state.
# If no $schema is provided at the top level, we will use the default dialect defined by the
# specification metaschema (all six vocabularies).
# At evaluation time we simply swap out the dialect instance in $state (but it still can't change
# specification versions).

sub _traverse_keyword_anchor {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'string');

  return E($state, '%s value "%s" does not match required syntax',
      $state->{keyword}, ($state->{keyword} eq '$id' ? '#' : '').$schema->{$state->{keyword}})
    if $state->{spec_version} =~ /^draft(7|2019-09)$/
        and $schema->{$state->{keyword}} !~ /^[A-Za-z][A-Za-z0-9_:.-]*$/
      or $state->{spec_version} eq 'draft2020-12'
        and $schema->{$state->{keyword}} !~ /^[A-Za-z_][A-Za-z0-9._-]*$/;

  my $canonical_uri = canonical_schema_uri($state);

  push @{$state->{identifiers}},
    Mojo::URL->new->to_abs($canonical_uri)->fragment($schema->{$state->{keyword}}) => {
      path => $state->{traversed_schema_path}.$state->{schema_path},
      canonical_uri => $canonical_uri,
    };
  return 1;
}

# we already indexed the $anchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_recursiveAnchor {
  my ($self, $schema, $state) = @_;

  return if not assert_keyword_type($state, $schema, 'boolean');

  # this is required because the location is used as the base URI for future resolution
  # of $recursiveRef, and the fragment would be disregarded in the base
  return E($state, '"$recursiveAnchor" keyword used without "$id"')
    if length($state->{schema_path});
  return 1;
}

sub _eval_keyword_recursiveAnchor {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not $schema->{'$recursiveAnchor'} or exists $state->{recursive_anchor_uri};

  # record the canonical location of the current position, to be used against future resolution
  # of a $recursiveRef uri -- as if it was the current location when we encounter a $ref.
  $state->{recursive_anchor_uri} = canonical_schema_uri($state);
  return 1;
}

sub _traverse_keyword_dynamicAnchor { goto \&_traverse_keyword_anchor }

# we already indexed the $dynamicAnchor uri, so there is nothing more to do at evaluation time.
# we explicitly do NOT set $state->{initial_schema_uri}.

sub _traverse_keyword_ref {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string')
    or not assert_uri_reference($state, $schema);
  return 1;
}

sub _eval_keyword_ref {
  my ($self, $data, $schema, $state) = @_;

  my $uri = Mojo::URL->new($schema->{'$ref'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;

  return $self->eval($data, $schema_info->{schema},
    +{
      %{$schema_info->{document}->evaluation_configs},
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$ref',
      initial_schema_uri => $schema_info->{canonical_uri},
      document => $schema_info->{document},
      document_path => $schema_info->{document_path},
      spec_version => $schema_info->{document}->specification_version,
      schema_path => '',
    });
}

sub _traverse_keyword_recursiveRef { goto \&_traverse_keyword_ref }

sub _eval_keyword_recursiveRef {
  my ($self, $data, $schema, $state) = @_;

  my $uri = Mojo::URL->new($schema->{'$recursiveRef'})->to_abs($state->{initial_schema_uri});
  my $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
  abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;

  if (is_type('boolean', $schema_info->{schema}{'$recursiveAnchor'}) and $schema_info->{schema}{'$recursiveAnchor'}) {
    $uri = Mojo::URL->new($schema->{'$recursiveRef'})
      ->to_abs($state->{recursive_anchor_uri} // $state->{initial_schema_uri});
    $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
    abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;
  }

  return $self->eval($data, $schema_info->{schema},
    +{
      %{$schema_info->{document}->evaluation_configs},
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$recursiveRef',
      initial_schema_uri => $schema_info->{canonical_uri},
      document => $schema_info->{document},
      document_path => $schema_info->{document_path},
      spec_version => $schema_info->{document}->specification_version,
      schema_path => '',
    });
}

sub _traverse_keyword_dynamicRef { goto \&_traverse_keyword_ref }

sub _eval_keyword_dynamicRef {
  my ($self, $data, $schema, $state) = @_;

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
    foreach my $base_scope (@{$state->{dynamic_scope}}) {
      $uri = Mojo::URL->new($base_scope)->fragment($anchor);
      my $dynamic_anchor_subschema_info = $state->{evaluator}->_fetch_from_uri($uri);
      if (($dynamic_anchor_subschema_info->{schema}->{'$dynamicAnchor'}//'') eq $anchor) {
        $schema_info = $state->{evaluator}->_fetch_from_uri($uri);
        abort($state, 'EXCEPTION: unable to find resource %s', $uri) if not $schema_info;
        last;
      }
    }
  }

  return $self->eval($data, $schema_info->{schema},
    +{
      %{$schema_info->{document}->evaluation_configs},
      %$state,
      traversed_schema_path => $state->{traversed_schema_path}.$state->{schema_path}.'/$dynamicRef',
      initial_schema_uri => $schema_info->{canonical_uri},
      document => $schema_info->{document},
      document_path => $schema_info->{document_path},
      spec_version => $schema_info->{document}->specification_version,
      schema_path => '',
    });
}

sub _traverse_keyword_vocabulary {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'object');

  my $valid = 1;
  foreach my $property (sort keys %{$schema->{'$vocabulary'}}) {
    $valid = 0 if not assert_keyword_type({ %$state, _schema_path_suffix => $property }, $schema, 'boolean');
    $valid = 0 if not assert_uri($state, $schema, $property);
  }

  return E($state, '$vocabulary can only appear at the schema resource root')
    if length($state->{schema_path});

  return E($state, '$vocabulary can only appear at the document root')
    if length($state->{traversed_schema_path}.$state->{schema_path});

  return $valid;
}

# we do nothing with $vocabulary yet at evaluation time. When we know we are in a metaschema,
# we can scan the URIs included here and either abort if a vocabulary is enabled that we do not
# understand, or turn on and off certain keyword behaviours based on the boolean values seen.

sub _traverse_keyword_comment {
  my ($self, $schema, $state) = @_;

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

=for Pod::Coverage vocabulary keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Core" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/core> and formally specified in
L<https://datatracker.ietf.org/doc/html/draft-bhutton-json-schema-00#section-8>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/core> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-02#section-8>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-01>.

=cut
