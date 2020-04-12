use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use experimental 'signatures';
use Types::Standard qw(HashRef Ref);
use MooX::HandlesVia;
use JSON::MaybeXS 'is_bool';

# use JSON::Schema::Draft201909::Document;

# these attributes not yet fully implemented, so we hardcode their values for now
sub annotate { 0 }
sub base_uri { '' } # use cwd when load_from_disk is true
sub load_from_disk { 0 }
sub load_from_network { 0 }
sub output_format { 'flag' }
sub short_circuit { 1 }
sub strict { 0 }

has documents => (
  is => 'bare',
  # isa => HashRef[InstanceOf['JSON::Schema::Draft201909::Document']],
  isa => HashRef[Ref],  # just store the raw document for now
  handles_via => 'Hash',
  handles => {
    _get_schema => 'get',
    _set_schema => 'set',
    _all_schema_uris => 'keys'
  },
);

# this collects schema resources which may be a schema root, or
# a subschema.  the key should be an absolute uri; the value
# should be either just a reference to the raw 'data' so identified,
# but possibly also the document that this data resides within as well as a json pointer string
# showing the location within the document.
has resources => ( is => 'ro', HashRef );

#around BUILDARGS => sub ($orig, $class, %args) {
#  if (my $documents = delete $args{document}) {
#    die 'documents argument not yet supported';
#  }
#
#  return $class->$orig(%args);
#};
#
#    # one arg, non-ref (id string - load the schema)
#    # one arg, JSON::Schema::Draft201909::Document
#    # two args, non-ref: $id => data|doc
# https://json-schema.org/draft/2019-09/json-schema-core.html#root
# "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
#sub add_document($self, @args) {
#  # one arg, non-ref (id string - load the schema)
#  # one arg, JSON::Schema::Draft201909::Document
#  # two args, non-ref: $id => data|doc
#  # one arg, unblessed ref: a raw document. use base uri as id.
#
#    # -> here I am.
#  # die if this schema is already stored - https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.8.2.4.5
#
#  # ... _set_schema(..)
#}

sub evaluate ($self, $instance_data, $schema) {
  # figure out what document is to be evaluated.
  # - schema = undef: use the schema document we know. die if more than one.
  # - schema = raw data: ->add_schema(..)
  # - schema = id str: if known, fetch the doc; otherwise, ->add_schema(..)

  # state collects localized configs, current instance_location, schema_location, and the errors/annotations.

  # XXX wrap in a try/catch and turn exception into an error
  my $results = $self->_evaluate($instance_data, $schema, {});

  # collect boolean result, errors and annotations into a ::Result object
}

sub _evaluate ($self, $instance_data, $schema, $state) {
  # this is the recursive sub. we keep a hash of state data to track json pointers to
  # where we are in instance data and schema data, to be used for error generation.
  # We also need to store the schema document object, where we store information that
  # might affect evaluation behaviour (such as vocabulary support, or draft-07 compatibility).
  # we will likely localize some config options depending on the keyword - e.g. when
  # evaluating the 'not' keyword, we can set short_circuit = true and annotate = false.

  # TODO: check short_circuit before returning
  # TODO: create error object, if output_format ne 'flag'
  return $schema if is_bool($schema);
  return false;

#  die 'bad structure' if ref $schema ne 'HASH';
#
#  die 'illegal $schema'
#    if exists $schema->{'$schema'} and $schema->{'$schema'} ne 'https://json-schema.org/draft/2019-09/schema';
#
#  my $result = true;

  # consider assertion keywords against the current data instance
  # consider applicator keywords against the current data instance (call _evaluate recursively)
  # consider applicator keywords against a child data instance (call _evaluate recursively)
  # --> for now, we recognize no keywords.

  # return state as well? or the set of errors and annotations collected from children?
  return $result if not $result;

  # collect annotations in the current subschema
  # combine with annotations from results from recursive calls against child data instances
  # for now, we collect no annotations.

  # return state as well? or the set of errors and annotations collected from children?
  return true;
}

1;
__END__

=pod

=for :header
=for stopwords schema subschema metaschema validator

=head1 SYNOPSIS

    use JSON::Schema::Draft201909;

    $js = JSON::Schema::Draft2019->new(
        strict => 1,
        short_circuit => 1,
        load_from_disk => 0,
        load_from_network => 0,
        base_uri => 'https://evilgeniuses.org',
        output_format => 'flag',
        annotate => 0,
    );

    $js->base_uri('https://insane-asylum.org/ward_one/');

    $js->add_schema($schema_data);
    $js->add_schema($schema_document);
    $js->add_schema($id_string => $schema_data);
    $js->add_schema($id_string);

    $result = $js->evaluate($instance_data);
    $result = $js->evaluate($instance_data, $id_string);    # TODO
    $result = $js->evaluate($instance_data, $schema_data);  # TODO

=head1 DESCRIPTION

This module aims to be a fully-compliant L<JSON Schema|https://json-schema.org/> evaluator and validator,
targeting the currently-latest
L<Draft 2019-09|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>
version of the specification.

=head1 CONFIGURATION OPTIONS

All of these options can be set via the constructor, or altered later on an instance using accessor methods.

=head2 annotate

Boolean; is always false when C<output_format> is C<flag>. When true, collects annotations on validating
(sub-)schemas in the result.

=head2 base_uri

Must be an absolute URI or an absolute filename. Used as the base URI for resolving relative URIs when no other
base URI is suitable for use.  Defaults to the directory corresponding to the local working directory when
C<load_from_disk> is true; otherwise, the empty string is used.

=head2 load_from_disk

Boolean; not yet supported. When true, permits loading referenced schemas from local disk.

=head2 load_from_network

Boolean; not yet supported. When true, permits loading referenced schemas from the network when URIs using a scheme
such as C<http> are referenced.

=head2 output_format

Must be one of the following values: C<flag>, C<basic>, C<detailed>, C<verbose>. Defaults to C<flag>.
See L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.2> for detailed description.

=head2 short_circuit

Boolean; is always true when C<output_format> is C<flag>, or defaults to false otherwise. When true, evaluation
returns as soon as validation is known to fail, without collecting all possible errors or annotations.

=head2 strict

Boolean; defaults to false. When true, unrecognized keywords or unexpected layout in the schema document
will generate an error at the instance location, which will cause validation to fail.

=head1 METHODS

=head2 new

    JSON::Schema::Draft201909->new(
        strict => 0,
        load_from_disk => 1,
        base_uri => 'https://nohello.com',
    );

Accepts all documented L<configuration options|/CONFIGURATION OPTIONS>. Additionally, can accept one
or more schema documents to be added directly:

    JSON::Schema::Draft201909->new(document => $schema_data);
    JSON::Schema::Draft201909->new(document => $schema_document);
    JSON::Schema::Draft201909->new(document => $id_string);
    JSON::Schema::Draft201909->new(document => { $id_string => $schema_data });
    JSON::Schema::Draft201909->new(document => [ $schema_data,
                                               $schema_document,
                                               $id_string,
                                               { $id_string => $schema_data },
                                             ]);

=head2 add_document

Makes the provided schema document available to the evaluator. Can be called in multiple ways:

=over 4

=item * C<< $jv->add_document($schema_data) >>

Must be recognizable as schema data (i.e. a boolean or a hashref). Its canonical URI will be parsed out of the
root C<$id> keyword, and resolved against L</base_uri> if not absolute.

=item * C<< $jv->add_document($schema_document) >>

B<Not yet implemented.>

Add an existing L<JSON::Schema::Draft201909::Document> object.

-item * C<< $js->add_document($id_string) >>

B<Not yet implemented.>

Fetches the schema document referenced by C<$id_string>. Will require either L</load_from_disk> or
L</load_from_network> to be enabled, if the document is not L<cached|/CACHED DOCUMENTS>.

=item * C<< $jv->add_document($id_string => $schema_data | $schema_document) >>

B<Not yet implemented.>

As C<< $jv->add_document($schema_data) >> or C<< $jv->add_document($schema_document) >>, but uses the
provided C<$id_string> as a base URI (which is resolved against L</base_uri> if not absolute).

=back

=head2 evaluate

Evaluates the provided instance data against the known schema document.  The result is returned one of
the following formats, as configured with L</output_format>:

=for :list
* L<flag|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.1> -
  a true/false result indicating whether the data is valid against the schema,
* L<basic|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.2> (not yet supported)
* L<detailed|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.3> (not yet supported)
* L<verbose|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.4> (not yet supported)

=head1 CACHED DOCUMENTS

The following schema documents are cached by this module, and do not need to be fetched from the network when
referenced:

=for :list
* L<https://json-schema.org/draft/2019-09/schema>
* L<https://json-schema.org/draft/2019-09/meta/core>
* L<https://json-schema.org/draft/2019-09/meta/applicator>
* L<https://json-schema.org/draft/2019-09/meta/validation>
* L<https://json-schema.org/draft/2019-09/meta/meta-data>
* L<https://json-schema.org/draft/2019-09/meta/format>
* L<https://json-schema.org/draft/2019-09/meta/content>

=head1 TYPE SEMANTICS

Perl types and JSON types are mostly interchangeable, and JSON encoders/decoders do a good job of
mapping one to the other while preserving type. The main sticky points are differentiating between
boolean, numeric and string scalar values.  For now, this JSON Schema evaluator will use the same
heuristics as L<JSON::MaybeXS> and L<Mojo::JSON> (via L<Cpanel::JSON::XS>) do:

=for :list
* a value is a boolean if and only if it isa L<JSON::PP::Boolean>
* a value is a number if and only if it is stored as an SvIV or SvNV (see L<perlguts>).

If your document passed through a JSON decoder, everything should work out just fine.

=head1 LIMITATIONS

Until version 1.000 is released, this implementation is not fully specification-compliant,
and public interfaces are subject to change. Internal interfaces (private and undocumented methods)
may change at any time and should not be relied upon.

The minimum extensible JSON Schema implementation requirements involve:

=for :list
* identifying, organizing, and linking schemas (with keywords such as C<$ref>, C<$id>, C<$schema>, C<$anchor>,
  C<$defs>)
* providing an interface to evaluate assertions
* providing an interface to collect annotations
* applying subschemas to instances and combining assertion results and annotation data accordingly.
* support for all vocabularies required by the Draft 2019-09 metaschema, L<https://json-schema.org/draft/2019-09/schema>

To date, missing components include most of these. More specifically, features to be added include:

=for :list
* recognition of <$ref> and C<$id>
* registration of a schema against a canonical base URI
* collection of validation errors (as opposed to a short-circuited true/false result)
* collection of annotations (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.7.7>
* multiple output formats (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* use of C<$recursiveRef>
* use of plain-name fragments with C<$anchor>
* support (either in annotations or validation of formats
  (L<https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.7>)
* support for string-encoded data keywords: C<contentEncoding>, C<contentMediaType>, C<contentSchema>
  (L<https://json-schema.org/draft/2019-09/json-schema-validation.html#content>)

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<Test::JSON::Schema::Acceptance>
* L<JSON::Validator>

=cut
