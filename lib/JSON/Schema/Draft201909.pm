use strict;
use warnings;
no if "$]" >= 5.031008, feature => 'indirect';
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=4 sw=4 tw=115 et :
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
    );

    $js->add_schema($schema_data);
    $js->add_schema($id_string => $data);   # TODO

    $result = $js->evaluate($instance_data);
    $result = $js->evaluate($instance_data, $id_string);    # TODO
    $result = $js->evaluate($instance_data, $schema_data);  # TODO

=head1 DESCRIPTION

This module aims to be a fully-compliant L<JSON Schema|https://json-schema.org/> evaluator and validator,
targeting the currently-latest
L<Draft 2019-09|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>
version of the specification.

=head1 CONFIGURATION OPTIONS

All of these options can be set via the constructor, or altered later on an instance.

=head2 strict

Boolean; defaults to false. When true, unrecognized keywords or unexpected layout in the schema document
will generate an error at the instance location (or cause validation to fail if C<output_format> is C<flag>).

=head2 short_circuit

Boolean; defaults to true when C<output_format> is C<flag>, or false otherwise. When true, evaluation
returns as soon as validation is known to fail, without collecting all possible errors.

=head2 load_from_disk

Boolean; not yet supported. When true, permits loading referenced schemas from local disk.

=head2 load_from_network

Boolean; not yet supported. When true, permits loading referenced schemas from the network when URIs using a scheme
such as C<http> are referenced.

=head2 base_uri

Must be an absolute URI or an absolute filename. Used as the base URI for resolving relative URIs when no other
base URI is suitable for use.  Defaults to the directory corresponding to the local working directory.

=head2 output_format

Must be one of the following values: C<flag>, C<basic>, C<detailed>, C<verbose>. Defaults to C<flag>.
See L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.2> for detailed description.

=head1 METHODS

=head2 evaluate

Evaluates the provided instance data against the known schema document.  The result is returned one of
the following formats, as configured with L</output_format>:

=for :list
* L<flag|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.1>
- a true/false result indicating whether the data is valid against the schema,
* L<basic|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.2> (not yet supported)
* L<detailed|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.3> (not yet supported)
* L<verbose|https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10.4.4> (not yet supported)

=head2 LIMITATIONS

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

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<Test::JSON::Schema::Acceptance>
* L<JSON::Validator>

=cut
