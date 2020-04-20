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
use MooX::HandlesVia;
use MooX::TypeTiny;
use Types::Standard qw(HashRef Ref);
use Types::TypeTiny 'StringLike';
use JSON::MaybeXS 'is_bool';
use Syntax::Keyword::Try;

# use JSON::Schema::Draft201909::Document;

# these attributes not yet fully implemented, so we hardcode their values for now
# maybe move these into a config hash, for easier localization during traversal.
# then the attribute can be set up with a Dict constraint with handles-via accessors.
#sub annotate { 0 }
#sub base_uri { '' } # use cwd when load_from_disk is true
#sub load_from_disk { 0 }
#sub load_from_network { 0 }
sub output_format { 'flag' }  # should not be required to be set at all - it can be determined later
                              # by setting it on the ::Result object
sub short_circuit { 1 } # cannot be true when annotate is true
#sub strict { 0 }

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
has resources => ( is => 'ro', isa => HashRef );

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
# if we want to add a document that is already known, but under a new uri,
# we need to tell that document object its new name as well (i.e. there is an index in *two* places,
# which must always be consistent.)
# whenever we add a pre-constructed ::Document, we should suck in all its uris and add them to our
# global registry.
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

  # state collects localized configs, current instance_location, schema_location
  #
  # errors and annotations are collected locally and returned to the caller
  # to be merged and returned recursively to the root.

  my $result = $self->_try_evaluate(
    $instance_data, $schema,
    {
      instance_path => '',
      schema_path => '',
      errors => [],
      $self->_has_short_circuit ? ( short_circuit => $self->short_circuit ) : (),
      $self->_has_no_collect_errors ? ( no_collect_errors => $self->no_collect_errors ) : (),
      # XXX ^^ need to structure this so the option is intuitive for the user to set, but also
      # lets us keep the value as undef when not set *and* default to collect_errors => 1.
      # we only set the option in $state when it has been explicitly set.
    }
  );

  return JSON::Schema::Draft201909::Result->new(
    result => $result,
    errors => \@errors,
    output_format => $self->output_format,
    instance_data => $instance_data,
  );
}

sub _try_evaluate ($self, $instance_data, $schema, $state) {
  my ($result, @errors);
  try {
    $result = $self->_evaluate($instance_data, $schema, { $state->%*, errors => \@errors });
  }
  catch my $e {
    $result = 0;
    push @errors, JSON::Schema::Draft201909::Error->new(
      instance_location => $state->{instance_path},
      keyword_location => $state->{schema_path},
      # for now, we do not support $ref, therefore absolute_schema_path is redundant
      #keyword_absolute_location => $state->{absolute_schema_path} // $state->{schema_path},
      #$state->{absolute_schema_path} eq $state->{schema_path} ? () : ( keyword_absolute_location => ),
      error => $e,
    );
  }

  push $state->{errors}->@*, $errors->@* if not $result and not $state->{no_collect_errors};
  return $result;
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
  # https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.6
  #   type, enum, const, <numeric>, <string>, <array>, <object>

  # consider applicator keywords against the current data instance (call _evaluate recursively)
  #   $ref, $recursiveRef:
  #     if reference is unknown, or not loaded and !load_from_*, generate an error but continue.

  # consider applicator keywords against a child data instance (call _evaluate recursively)
  #   not, if/then/else, allOf, oneOf, anyOf, properties, items, ...

  # --> for now, we recognize no keywords.

  # return state as well? or the set of errors and annotations collected from children?
  return $result if not $result;

  # collect annotations in the current subschema
  # combine with annotations from results from recursive calls against child data instances
  # for now, we collect no annotations.

  # whenever we look at subschemas for applicator keywords (allOf, anyOf, oneOf, not),
  # call _try_evaluate with collect_errors = 0, collect_annotations => 0, short_circuit => 1 ??
  # not quite -- anyOf requires checking more than the first success path for annotations, and more
  # than the first failure path for errors -- unless short_circuit => 1 is already set.

  # return state as well? or the set of errors and annotations collected from children?
  return true;


  # this applicator keyword list should be in a sub so roles/subclasses can alter it.
  foreach my $keyword (qw(not if anyOf allOf oneOf dependentSchemas items)) {
    next if not exists $schema->{$keyword};
    # note that $schema in this sub is not the schema contained by the keyword (not just because it
    # isn't always a schema itself), but the schema that contains the keyword - so sibling keywords
    # are visible and can be accessed.
    my $result = $self->${\ '_evaluate_keyword_'.$kewyord }($instance_data, $schema,
        {
          $state->%*,
          schema_path => $state->{schema_path}.'/'.$keyword,
          errors => (my $errors = []),
        });
use Data::Dumper;
local $Data::Dumper::Sortkeys = 1;
local $Data::Dumper::Maxdepth = 2;
# TODO: turn this into a DDC ::Dwarn that I can uncomment, but fix the formatting options.
print STDERR "### from keyword '$keyword', got result $result, errors ", Dumper($errors);

    next if $result;

    # is this necessary? just trust the calling function to use this config option properly.
    # (TODO: we can test the _evaluate_keyword* subs individually to verify this.)
    # edit: no.. *something* needs to check it.. either the caller or the callee?
    push $state->{errors}->@*, $errors->@* if not $state->{no_collect_errors};
    return $result if $state->{short_circuit};
  }
}

sub _evaluate_keyword_not ($self, $instance_data, $schema, $state) {
  my $result = $self->_try_evaluate(
    $instance_data, $schema->{not},
    {
      instance_path => $state->{instance_path},
      schema_path => $state->{schema_path},
      errors => [], # do not need to save this reference
      short_circuit => 1,
      no_collect_errors => 1,
    },
  );
  return $result if $result or $state->{no_collect_errors};
  push $state->{errors}->@*, JSON::Schema::Draft201909::Error->new(
    instance_location => $state->{instance_path},
    keyword_location => $state->{schema_path},
    error => 'subschema evaluated to false',
  );
  return $result;
}

sub _evaluate_keyword_if ($self, $instance_data, $schema, $state) {
  # TODO: must evaluate 'if' subschema anyway if collecting annotations
  return 1 if not exists $schema->{then} and not exists $schema->{else};

  my $result = $self->_try_evaluate(
    $instance_data, $schema->{if},
    {
      $state->%*, # ? just in case there are other values we aren't overriding (like what?)
      errors => [], # do not need to save errors from here
      short_circuit => 1,
      no_collect_errors => 1,
    },
  );

  # for the 'then' or 'else' schema: short-circuit default, errors default, annotations default.
  # schema path is ../then or ../else
  my $keyword = $result ? 'then' : 'else';
  $state->{schema_path} =~ s/if$/$keyword/r;
  my $result = $self->_try_evaluate(
    $instance_data, $schema->{$keyword},
    {
      $state->%*,
      errors => (my $errors = []),
    },
  );

  return $result if $result or $state->{no_collect_errors};
  push $state->{errors}->@*, $errors->@*;
  return $result;
}

sub _evaluate_keyword_allOf ($self, $instance_data, $schema, $state) {
  my $result = 1;
  foreach my $index (0.. $schema->{allOf}->$#*) {
    $result &&= $self->_try_evaluate($instance_data, $schema->{allOf}[$index],
      +{ $state->%*, keyword_location => $state->{schema_path}.'/'.$index, (my $errors = []) });

    push $state->{errors}->@*, $errors->@* if not $result;  # do we check no_collect_errors? if so, pivot to using $success count?
    return $result if not $result and $state->{short_circuit};
  }
  return $result;
}

sub _evaluate_keyword_anyOf ($self, $instance_data, $schema, $state) {
  my $successes;
  foreach my $index (0.. $schema->{anyOf}->$#*) {
    my $result = $self->_try_evaluate($instance_data, $schema->{anyOf}[$index],
      +{ $state->%*, keyword_location => $state->{schema_path}.'/'.$index, (my $errors = []) });

    ++$successes if $result;
    push $state->{errors}->@*, $errors->@* if not $result;  # do we check no_collect_errors? if not, can pivot to $result ||= ...
    return $result if $result and $state->{short_circuit};
  }
  return $successes ? 1 : 0;
}

sub _evaluate_keyword_oneOf ($self, $instance_data, $schema, $state) {
  my $successes;
  foreach my $index (0.. $schema{oneOf}->$#*) {
    my $result = $self->_try_evaluate($instance_data, $schema->{oneOf}[$index],
      +{ $state->%*, keyword_location => $state->{schema_path}.'/'.$index, (my $errors = []) });

    ++$successes if $result;
    push $state->{errors}->@*, $errors->@* if not $result;
    return $result if $successes > 1 and $state->{short_circuit};
  }
  return $successes == 1 ? 1 : 0;
}

sub _evaluate_keyword_dependentSchemas ($self, $instance_data, $schema, $state) {
  return 1 if ref $instance_data ne 'HASH'; # TODO use _is_instance_type('object') ?
  my $result = 1;
  foreach my $property (keys $schema->{dependentSchemas}->%*) {
    next if not exists $instance_data->{$property};

    $result &&= $self->_try_evaluate($instance_data, $schema->{dependentSchemas}{$property},
      +{ $state->%*, keyword_location => $state->{schema_path}.'/'.$property, (my $errors = []) });
    push $state->{errors}->@*, $errors->@* if not $result and not $state->{no_collect_errors};
    return $result if not $result and $state->{short_circuit};
  }

  return $result;
}

# https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.9.3.1.1
sub _evaluate_keyword_items ($self, $instance_data, $schema, $state) {
  return 1 if ref $instance_data ne 'ARRAY';

  # TODO: produce an annotation at the last index evaluated
  # The value of "items" MUST be either a valid JSON Schema or an array of valid JSON Schemas. 
  if (ref $schema->{items} eq 'ARRAY') {
    # If "items" is an array of schemas, validation succeeds if each element of the instance validates against the schema at the same position, if any.
    my $result = 1;
    foreach my $index (0 .. $instance_data->$#*) {
      last if $index > $schema->{items}->$#*;
      $result &&= $self->_try_evaluate($instance_data->[$index], $schema->{items}[$index],
        +{ $state->%*,
          instance_path => $state->{instance_path}.'/'.$index,
          schema_path => $state->{schema_path}.'/'.$index, (my $errors = []) });

      push $state->{errors}->@*, $errors->@* if not $result;  # see no_collect_errors not in anyOf
      return $result if not $result and $state->{short_circuit};
    }
    return $result;
  }
  else { # must be a valid JSON Schema - boolean or object
    # If "items" is a schema, validation succeeds if all elements in the array successfully validate against that schema.
    my $result = 1;
    foreach my $index (0 .. $instance_data->$#*) {
      $result &&= $self->_try_evaluate($instance_data->[$index], $schema->{items},
        +{ $state->%*, instance_path => $state->{instance_path}.'/'.$index, (my $errors = []) });

      push $state->{errors}->@*, $errors->@* if not $result;  # see no_collect_errors not in anyOf
      return $result if not $result and $state->{short_circuit};
    }
    return $result;
  }
}

#sub _load_from_disk ($self, $absolute_filename) {
#  1;
#  # must always be passed an absolute filename. if a Path::Tiny or Mojo::File object,
#  # we will use it to load and to check if abs.
#  # checks cache before checking load_from_disk.
#  # calls ::Document->new with the results (which figures out the canonical uri for the caller).
#}
#
#has useragent => ( is => 'ro' );
#sub _load_from_network ($class, $absolute_uri) {
#  1;
#  # must always be passed an absolute uri.
#  # makes use of a URI or Mojo::URL object to check if abs.
#  # if scheme eq 'file' (a 'file:///...' uri), call _load_from_disk with the correct components.
#  # checks cache before checking load_from_*.
#  # calls ::Document->new with the results (which figures out the canonical uri for the caller).
#  # will use the provided useragent attribute if one is given (which you should set up
#  # if custom headers e.g. Authorization should be passed).
#  # check spec about Content-Type - perhaps warn if res->ct ne 'application/schema+json'.
#}
#
#has custom_document_load => ( is => 'ro', isa => CodeRef );
#sub _load_from_other ($class, $uri, $subref) {
#  1;
#  # used to load all other resources if uri is not an absolute filename
#  # or absolute uri (or if load_from_* options are not enabled).
#  # calls the provided subref to fetch the document. must return an inflated
#  # perl datastructure (bool or hash). can be used to configure additional ways of getting documents
#  # into the system (e.g. via Mojo app, or custom data format). if this interface is to be used
#  # solely for all data loading (i.e. not using disk or network), then set those load_from_* options
#  # to false.
#  this coderef must (die? return undef?) if the document cannot be found or cannot be loaded
#  or is corrupt or...  - die with an exception ending in \n so it does not have a line number.
#}


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
