use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=4 sw=4 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.001';


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

=head2 strict

Boolean; defaults to false. When true, unrecognized keywords or unexpected layout in the schema document
will generate an error at the instance location, which will cause validation to fail.

=head2 short_circuit

Boolean; is always true when C<output_format> is C<flag>, or defaults to false otherwise. When true, evaluation
returns as soon as validation is known to fail, without collecting all possible errors.

=head2 load_from_disk

Boolean; not yet supported. When true, permits loading referenced schemas from local disk.

=head2 load_from_network

Boolean; not yet supported. When true, permits loading referenced schemas from the network when URIs using a scheme
such as C<http> are referenced.

=head2 base_uri

Must be an absolute URI or an absolute filename. Used as the base URI for resolving relative URIs when no other
base URI is suitable for use.  Defaults to the directory corresponding to the local working directory when
C<load_from_disk> is true, or undefined otherwise (which will generate an error if used).

=head2 output_format

Must be one of the following values: C<flag>, C<basic>, C<detailed>, C<verbose>. Defaults to C<flag>.
See L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.2> for detailed description.

=head2 annotate

Boolean; is always false when C<output_format> is C<flag>. When true, collects annotations on validating
(sub-)schemas in the result.

=head1 METHODS

=head2 new

    JSON::Schema::Draft201909->new(
        strict => 0,
        load_from_disk => 1,
        base_uri => 'https://nohello.com',
    );

Accepts all documented L<configuration options|/CONFIGURATION OPTIONS>. Additionally, can accept one
or more schemas to be added directly:

    JSON::Schema::Draft201909->new(schema => $schema_data);
    JSON::Schema::Draft201909->new(schema => $schema_document);
    JSON::Schema::Draft201909->new(schema => $id_string);
    JSON::Schema::Draft201909->new(schema => { $id_string => $schema_data });
    JSON::Schema::Draft201909->new(schema => [ $schema_data,
                                               $schema_document,
                                               $id_string,
                                               { $id_string => $schema_data },
                                             ]);

=head2 add_schema

Makes the provided schema available to the evaluator. Can be called in multiple ways:

=over 4

=item * C<< $jv->add_schema($schema_data) >>

Must be recognizable as schema data (i.e. a boolean or a hashref). Its canonical URI will be parsed out of the
root C<$id> keyword, and resolved against L</base_uri> if not absolute.

=item * C<< $jv->add_schema($schema_document) >>

Add an existing L<JSON::Schema::Document> object.

-item * C<< $js->add_schema($id_string) >>

Fetches the schema document referenced by C<$id_string>. Will require either L</load_from_disk> or
L</load_from_network> to be enabled, if the document is not L<cached|/CACHED DOCUMENTS>.

=item * C<< $jv->add_schema($id_string => $schema_data) >>

As C<< $jv->add_schema($schema_data) >>, but uses the provided C<$id_string> as the base URI (which is resolved
against L</base_uri> if not absolute).

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

TBD. Explain how perl types and JSON types are mostly interchangeable and how one maps to the other for the purpose
of JSON Schema evaluation. Of particular concern are distinguishing strings from numbers, and booleans from strings
or numbers.

=head1 LIMITATIONS

Until version 1.000 is released, this implementation is not fully specification-compliant.

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
