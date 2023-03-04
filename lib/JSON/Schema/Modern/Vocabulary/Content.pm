use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::Content;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Content vocabulary

our $VERSION = '0.565';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Storable 'dclone';
use Feature::Compat::Try;
use JSON::Schema::Modern::Utilities qw(is_type A assert_keyword_type E abort);
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2019-09/vocab/content' => 'draft2019-09',
  'https://json-schema.org/draft/2020-12/vocab/content' => 'draft2020-12';
}

sub evaluation_order { 4 }

sub keywords ($self, $spec_version) {
  return (
    qw(contentEncoding contentMediaType),
    $spec_version ne 'draft7' ? 'contentSchema' : (),
  );
}

sub _traverse_keyword_contentEncoding ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_contentEncoding ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);

  A($state, $schema->{$state->{keyword}});

  if ($state->{validate_content_schemas}) {
    my $decoder = $state->{evaluator}->get_encoding($schema->{contentEncoding});
    abort($state, 'cannot find decoder for contentEncoding "%s"', $schema->{contentEncoding})
      if not $decoder;

    # decode the data now, so we can report errors for the right keyword
    try {
      $state->{_content_ref} = $decoder->(\$data);
    }
    catch ($e) {
      chomp $e;
      return E($state, 'could not decode %s string: %s', $schema->{contentEncoding}, $e);
    };
  }

  return 1;
}

sub _traverse_keyword_contentMediaType { shift->_traverse_keyword_contentEncoding(@_) }

sub _eval_keyword_contentMediaType ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);

  A($state, $schema->{$state->{keyword}});

  if ($state->{validate_content_schemas}) {
    my $decoder = $state->{evaluator}->get_media_type($schema->{contentMediaType});
    abort($state, 'cannot find decoder for contentMediaType "%s"', $schema->{contentMediaType})
      if not $decoder;

    # contentEncoding failed to decode the content
    return 1 if exists $schema->{contentEncoding} and not exists $state->{_content_ref};

    # decode the data now, so we can report errors for the right keyword
    try {
      $state->{_content_ref} = $decoder->($state->{_content_ref} // \$data);
    }
    catch ($e) {
      chomp $e;
      delete $state->{_content_ref};
      return E($state, 'could not decode %s string: %s', $schema->{contentMediaType}, $e);
    }
  }

  return 1;
}

sub _traverse_keyword_contentSchema ($self, $schema, $state) {
  # since contentSchema should never be assumed to be evaluated in the context of the containing
  # schema, it is not appropriate to gather identifiers found therein -- but we can still validate
  # the subschema.
  $self->traverse_subschema($schema, +{ %$state, identifiers => [] });
}

sub _eval_keyword_contentSchema ($self, $data, $schema, $state) {
  return 1 if not exists $schema->{contentMediaType};
  return 1 if not is_type('string', $data);

  A($state, dclone($schema->{contentSchema}));
  return 1 if not $state->{validate_content_schemas};

  return 1 if not exists $state->{_content_ref};  # contentMediaType failed to decode the content

  return 1 if $self->eval($state->{_content_ref}->$*, $schema->{contentSchema},
    { %$state, schema_path => $state->{schema_path}.'/contentSchema' });
  return E($state, 'subschema is not valid');
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Content" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/content> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-validation.html#section-8>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keywords, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/content> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-8>.
* the equivalent Draft 7 keywords that correspond to this vocabulary and are formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-8>.

Assertion behaviour can be enabled by toggling the L<JSON::Schema::Modern/validate_content_schemas>
option.

New handlers for C<contentEncoding> and C<contentMediaType> can be done through
L<JSON::Schema::Modern/add_encoding> and L<JSON::Schema::Modern/add_media_type>.

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
