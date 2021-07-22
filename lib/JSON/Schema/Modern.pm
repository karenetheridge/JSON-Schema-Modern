use strict;
use warnings;
package JSON::Schema::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.515';

use 5.016;  # for fc, unicode_strings features
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::MaybeXS;
use Carp qw(croak carp);
use List::Util 1.55 qw(pairs first uniqint);
use Ref::Util 0.100 qw(is_ref is_plain_hashref is_plain_coderef);
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use Module::Runtime 'use_module';
use Moo;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef Optional slurpy);
use Feature::Compat::Try;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Result;
use JSON::Schema::Modern::Document;
use JSON::Schema::Modern::Utilities qw(get_type canonical_schema_uri E abort annotate_self);
use namespace::clean;

our @CARP_NOT = qw(JSON::Schema::Modern::Document);

use constant SPECIFICATION_VERSION_DEFAULT => 'draft2019-09';

has specification_version => (
  is => 'ro',
  isa => Enum([qw(draft7 draft2019-09)]),
);

has output_format => (
  is => 'ro',
  isa => Enum(JSON::Schema::Modern::Result->OUTPUT_FORMATS),
  default => 'basic',
);

has short_circuit => (
  is => 'ro',
  isa => Bool,
  lazy => 1,
  default => sub { $_[0]->output_format eq 'flag' && !$_[0]->collect_annotations },
);

has max_traversal_depth => (
  is => 'ro',
  isa => Int,
  default => 50,
);

has validate_formats => (
  is => 'ro',
  isa => Bool,
  default => 0, # as specified by https://json-schema.org/draft/2019-09/schema#/$vocabulary
);

has collect_annotations => (
  is => 'ro',
  isa => Bool,
);

has annotate_unknown_keywords => (
  is => 'ro',
  isa => Bool,
);

has _format_validations => (
  is => 'bare',
  isa => Dict[
    (map +($_ => Optional[CodeRef]), qw(date-time date time duration email idn-email hostname idn-hostname ipv4 ipv6 uri uri-reference iri iri-reference uuid uri-template json-pointer relative-json-pointer regex)),
    slurpy HashRef[Dict[type => Enum[qw(null object array boolean string number integer)], sub => CodeRef]],
  ],
  init_arg => 'format_validations',
  handles_via => 'Hash',
  handles => {
    _get_format_validation => 'get',
  },
  lazy => 1,
  default => sub { {} },
);

sub add_schema {
  croak 'insufficient arguments' if @_ < 2;
  my $self = shift;

  # TODO: resolve $uri against $self->base_uri
  my $uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $uri->fragment;

  if (not @_) {
    my ($schema, $canonical_uri, $document, $document_path) = $self->_fetch_schema_from_uri($uri);
    return if not defined $schema or not defined wantarray;
    return $document;
  }

  my $document = $_[0]->$_isa('JSON::Schema::Modern::Document') ? shift
    : JSON::Schema::Modern::Document->new(
      schema => shift,
      $uri ? (canonical_uri => $uri) : (),
      _evaluator => $self,  # used only for traversal during document construction
    );

  die((caller())[0] ne ref($self)
    ? join('; ', map $_->keyword_location.': '.$_->error, $document->errors)
    : die JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      errors => [ $document->errors ],
    )) if $document->has_errors;

  if (not grep $_->{document} == $document, $self->_resource_values) {
    my $schema_content = $document->_serialized_schema
      // $document->_serialized_schema($self->_json_decoder->encode($document->schema));

    if (my $existing_doc = first {
          my $existing_content = $_->_serialized_schema
            // $_->_serialized_schema($self->_json_decoder->encode($_->schema));
          $existing_content eq $schema_content
        } uniqint map $_->{document}, $self->_resource_values) {
      # we already have this schema content in another document object.
      $document = $existing_doc;
    }
    else {
      $self->_add_resources(map +($_->[0] => +{ %{$_->[1]}, document => $document }),
        $document->resource_pairs);
    }
  }

  if ("$uri") {
    $self->_add_resources($uri => { path => '', canonical_uri => $document->canonical_uri, document => $document });
  }

  return $document;
}

sub evaluate_json_string {
  croak 'evaluate_json_string called in void context' if not defined wantarray;
  croak 'insufficient arguments' if @_ < 3;
  my ($self, $json_data, $schema, $config_override) = @_;

  my $data;
  try {
    $data = $self->_json_decoder->decode($json_data)
  }
  catch ($e) {
    return JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      errors => [
        JSON::Schema::Modern::Error->new(
          keyword => undef,
          instance_location => '',
          keyword_location => '',
          error => $e,
        )
      ],
    );
  }

  return $self->evaluate($data, $schema, $config_override);
}

# this is called whenever we need to walk a document for something.
# for now it is just called when a ::Document object is created, to identify
# $id and $anchor keywords within.
# Returns the internal $state object accumulated during the traversal.
sub traverse {
  croak 'insufficient arguments' if @_ < 2;
  my ($self, $schema_reference, $config_override) = @_;

  my $base_uri = Mojo::URL->new($config_override->{initial_schema_uri} // '');

  my $state = {
    depth => 0,
    data_path => '',                    # this never changes since we don't have an instance yet
    traversed_schema_path => '',        # the accumulated traversal path as of the start, or last $id
    initial_schema_uri => $base_uri,    # the canonical URI as of the start, or last $id
    schema_path => '',                  # the rest of the path, since the last $id
    errors => [],
    spec_version => $self->specification_version//SPECIFICATION_VERSION_DEFAULT, # can change, iff nothing explicitly requested
    # for now, this is hardcoded, but in the future we will wrap this in a dialect that starts off
    # just with the Core vocabulary and then determine the actual vocabularies from the '$schema'
    # keyword in the schema and the '$vocabulary' keyword in the metaschema.
    vocabularies => [
      (map use_module('JSON::Schema::Modern::Vocabulary::'.$_)->new,
        qw(Core Applicator Validation Format Content MetaData)),
    ],
    identifiers => [],
    configs => {},
    callbacks => $config_override->{callbacks} // {},
    evaluator => $self,
  };

  try {
    $self->_traverse_subschema($schema_reference, $state);
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Error')) {
      # note: we should never be here, since traversal subs are no longer be fatal
      push @{$state->{errors}}, $e;
    }
    else {
      E($state, 'EXCEPTION: '.$e);
    }
  }

  return $state;
}

sub evaluate {
  croak 'evaluate called in void context' if not defined wantarray;
  croak 'insufficient arguments' if @_ < 3;
  my ($self, $data, $schema_reference, $config_override) = @_;

  my $base_uri = Mojo::URL->new;  # TODO: will be set by a global attribute

  my $state = {
    data_path => '',
    traversed_schema_path => '',        # the accumulated traversal path as of the start, or last $id, or up to the last traversed $ref
    initial_schema_uri => $base_uri,    # the canonical URI as of the start or last $id, or the last traversed $ref
    schema_path => '',                  # the rest of the path, since the last $id or the last traversed $ref
  };

  my $valid;
  try {
    my ($schema, $canonical_uri, $document, $document_path);

    if (not is_ref($schema_reference) or $schema_reference->$_isa('Mojo::URL')) {
      # TODO: resolve $uri against base_uri
      ($schema, $canonical_uri, $document, $document_path) = $self->_fetch_schema_from_uri($schema_reference);
    }
    else {
      # traverse is called via add_schema -> ::Document->new -> ::Document->BUILD
      $document = $self->add_schema($base_uri, $schema_reference);
      ($schema, $canonical_uri) = map $document->$_, qw(schema canonical_uri);
      $document_path = '';
    }

    abort($state, 'EXCEPTION: unable to find resource %s', $schema_reference)
      if not defined $schema;

    $state = +{
      %$state,
      depth => 0,
      initial_schema_uri => $canonical_uri, # the canonical URI as of the start or last $id, or the last traversed $ref
      document => $document,                # the ::Document object containing this schema
      document_path => $document_path,      # the path within the document of this schema, since the last $id or $ref traversal
      errors => [],
      annotations => [],
      seen => {},
      spec_version => $document->specification_version,
      # for now, this is hardcoded, but in the future the dialect will be determined by the
      # traverse() pass on the schema and examination of the referenced metaschema.
      vocabularies => [
        (map use_module('JSON::Schema::Modern::Vocabulary::'.$_)->new,
          qw(Core Applicator Validation Format Content MetaData)),
      ],
      evaluator => $self,
      %{$document->evaluation_configs},
      (map {
        my $val = $config_override->{$_} // $self->$_;
        defined $val ? ( $_ => $val ) : ()
      } qw(short_circuit collect_annotations validate_formats annotate_unknown_keywords)),
    };

    $valid = $self->_eval_subschema($data, $schema, $state);
    warn 'result is false but there are no errors' if not $valid and not @{$state->{errors}};
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      return $e;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      push @{$state->{errors}}, $e;
    }
    else {
      E($state, 'EXCEPTION: '.$e);
    }

    $valid = 0;
  }

  return JSON::Schema::Modern::Result->new(
    output_format => $self->output_format,
    valid => $valid,
    $valid
      # strip annotations from result if user didn't explicitly ask for them
      ? ($config_override->{collect_annotations} // $self->collect_annotations
          ? (annotations => $state->{annotations}) : ())
      : (errors => $state->{errors}),
  );
}

sub get {
  croak 'insufficient arguments' if @_ < 2;
  my ($self, $uri) = @_;

  my ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
  $subschema = dclone($subschema) if is_ref($subschema);
  return !defined $subschema ? () : wantarray ? ($subschema, $canonical_uri) : $subschema;
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

# current spec version => { keyword => undef, or arrayref of alternatives }
my %removed_keywords = (
  'draft7' => {
    id => [ '$id' ],
  },
  'draft2019-09' => {
    id => [ '$id' ],
    definitions => [ '$defs' ],
    dependencies => [ qw(dependentSchemas dependentRequired) ],
  },
);

sub _traverse_subschema {
  croak 'insufficient arguments' if @_ < 3;
  my ($self, $schema, $state) = @_;

  delete $state->{keyword};

  return E($state, 'EXCEPTION: maximum traversal depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = get_type($schema);
  return if $schema_type eq 'boolean';

  return E($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  foreach my $vocabulary (@{$state->{vocabularies}}) {
    foreach my $keyword ($vocabulary->keywords($state->{spec_version})) {
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      $state->{keyword} = $keyword;
      my $method = '_traverse_keyword_'.($keyword =~ s/^\$//r);

      $vocabulary->$method($schema, $state) if $vocabulary->can($method);

      if (my $sub = $state->{callbacks}{$keyword}) {
        $sub->($schema, $state);
      }
    }
  }

  # check for previously-supported but now removed keywords
  foreach my $keyword (sort keys %{$removed_keywords{$state->{spec_version}}}) {
    next if not exists $schema->{$keyword};
    my $message ='no-longer-supported "'.$keyword.'" keyword present (at location "'
      .canonical_schema_uri($state).'")';
    if (my $alternates = $removed_keywords{$state->{spec_version}}->{$keyword}) {
      my @list = map '"'.$_.'"', @$alternates;
      @list = ((map $_.',', @list[0..$#list-1]), $list[-1]) if @list > 2;
      splice(@list, -1, 0, 'or') if @list > 1;
      $message .= ': this should be rewritten as '.join(' ', @list);
    }
    carp $message;
  }
}

sub _eval_subschema {
  croak '_eval_subschema called in void context' if not defined wantarray;
  croak 'insufficient arguments' if @_ < 4;
  my ($self, $data, $schema, $state) = @_;

  # callers created a new $state for us, so we do not propagate upwards changes to depth, traversed
  # paths; but annotations, errors are arrayrefs so their contents will be shared
  delete @{$state}{'keyword', grep /^_/, keys %$state};

  abort($state, 'EXCEPTION: maximum evaluation depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  # find all schema locations in effect at this data path + canonical_uri combination
  # if any of them are absolute prefix of this schema location, we are in a loop.
  my $canonical_uri = canonical_schema_uri($state);
  my $schema_location = $state->{traversed_schema_path}.$state->{schema_path};
  abort($state, 'EXCEPTION: infinite loop detected (same location evaluated twice)')
    if grep substr($schema_location, 0, length) eq $_,
      keys %{$state->{seen}{$state->{data_path}}{$canonical_uri}};
  $state->{seen}{$state->{data_path}}{$canonical_uri}{$schema_location}++;

  my $schema_type = get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  # this should never happen, due to checks in traverse
  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  my $valid = 1;
  my %unknown_keywords = map +($_ => undef), keys %$schema;
  my $orig_annotations = $state->{annotations};
  $state->{annotations} = [];
  my @new_annotations;

  ALL_KEYWORDS:
  foreach my $vocabulary (@{$state->{vocabularies}}) {
    foreach my $keyword ($vocabulary->keywords($state->{spec_version})) {
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      delete $unknown_keywords{$keyword};

      my $method = '_eval_keyword_'.($keyword =~ s/^\$//r);
      next if not $vocabulary->can($method);

      $state->{keyword} = $keyword;
      my $error_count = @{$state->{errors}};
      if (not $vocabulary->$method($data, $schema, $state)) {
        warn 'result is false but there are no errors (keyword: '.$keyword.')'
          if $error_count == @{$state->{errors}};
        $valid = 0;
      }

      last ALL_KEYWORDS if not $valid and $state->{short_circuit};

      push @new_annotations, @{$state->{annotations}}[$#new_annotations+1 .. $#{$state->{annotations}}];
    }
  }

  $state->{annotations} = $orig_annotations;

  if ($valid) {
    push @{$state->{annotations}}, @new_annotations;
    annotate_self(+{ %$state, keyword => $_ }, $schema) foreach sort keys %unknown_keywords;
  }

  return $valid;
}

has _resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,
      document => InstanceOf['JSON::Schema::Modern::Document'],
    ]],
  handles_via => 'Hash',
  handles => {
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _resource_index => 'elements',
    _resource_keys => 'keys',
    _add_resources_unsafe => 'set',
    _resource_values => 'values',
  },
  lazy => 1,
  default => sub { {} },
);

around _add_resources => sub {
  my ($orig, $self) = (shift, shift);

  my @resources;
  foreach my $pair (sort { $a->[0] cmp $b->[0] } pairs @_) {
    my ($key, $value) = @$pair;
    if (my $existing = $self->_get_resource($key)) {
      # we allow overwriting canonical_uri = '' to allow for ad hoc evaluation of schemas that
      # lack all identifiers altogether, but preserve other resources from the original document
      if ($key ne '') {
        next if $existing->{path} eq $value->{path}
          and $existing->{canonical_uri} eq $value->{canonical_uri}
          and $existing->{document} == $value->{document};
        croak 'uri "'.$key.'" conflicts with an existing schema resource';
      }
    }
    elsif ($self->CACHED_METASCHEMAS->{$key}) {
      croak 'uri "'.$key.'" conflicts with an existing meta-schema resource';
    }

    my $fragment = $value->{canonical_uri}->fragment;
    croak sprintf('canonical_uri cannot contain an empty fragment (%s)', $value->{canonical_uri})
      if defined $fragment and $fragment eq '';

    croak sprintf('canonical_uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($fragment // '') =~ m{^[^/]};

    $self->$orig($key, $value);
  }
};

use constant CACHED_METASCHEMAS => {
  'https://json-schema.org/draft/2019-09/hyper-schema'        => 'draft2019-09/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/links'               => 'draft2019-09/links.json',
  'https://json-schema.org/draft/2019-09/meta/applicator'     => 'draft2019-09/meta/applicator.json',
  'https://json-schema.org/draft/2019-09/meta/content'        => 'draft2019-09/meta/content.json',
  'https://json-schema.org/draft/2019-09/meta/core'           => 'draft2019-09/meta/core.json',
  'https://json-schema.org/draft/2019-09/meta/format'         => 'draft2019-09/meta/format.json',
  'https://json-schema.org/draft/2019-09/meta/hyper-schema'   => 'draft2019-09/meta/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/meta/meta-data'      => 'draft2019-09/meta/meta-data.json',
  'https://json-schema.org/draft/2019-09/meta/validation'     => 'draft2019-09/meta/validation.json',
  'https://json-schema.org/draft/2019-09/output/hyper-schema' => 'draft2019-09/output/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/output/schema'       => 'draft2019-09/output/schema.json',
  'https://json-schema.org/draft/2019-09/schema'              => 'draft2019-09/schema.json',

  # trailing # is omitted because we always cache documents by its canonical (fragmentless) URI
  'http://json-schema.org/draft-07/schema' => 'draft7/schema.json',
};

# returns the same as _get_resource
sub _get_or_load_resource {
  my ($self, $uri) = @_;

  my $resource = $self->_get_resource($uri);
  return $resource if $resource;

  if (my $local_filename = $self->CACHED_METASCHEMAS->{$uri}) {
    my $file = path(dist_dir('JSON-Schema-Modern'), $local_filename);
    my $schema = $self->_json_decoder->decode($file->slurp_raw);
    my $document = JSON::Schema::Modern::Document->new(schema => $schema, _evaluator => $self);

    # this should be caught by the try/catch in evaluate()
    die JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      errors => [ $document->errors ],
    ) if $document->has_errors;

    # we have already performed the appropriate collision checks, so we bypass them here
    $self->_add_resources_unsafe(
      map +($_->[0] => +{ %{$_->[1]}, document => $document }),
        $document->resource_pairs
    );

    return $self->_get_resource($uri);
  }

  # TODO:
  # - load from network or disk
  # - handle such resources with $anchor fragments

  return;
};

# returns a schema (which may not be at a document root), the canonical uri for that schema,
# the JSON::Schema::Modern::Document object that holds that schema, and the path relative
# to the document root for this schema.
# creates a Document and adds it to the resource index, if not already present.
sub _fetch_schema_from_uri {
  my ($self, $uri) = @_;

  $uri = Mojo::URL->new($uri) if not is_ref($uri);
  my $fragment = $uri->fragment;

  my ($subschema, $canonical_uri, $document, $document_path);
  if (not length($fragment) or $fragment =~ m{^/}) {
    my $base = $uri->clone->fragment(undef);
    if (my $resource = $self->_get_or_load_resource($base)) {
      $subschema = $resource->{document}->get($document_path = $resource->{path}.($fragment//''));
      $document = $resource->{document};
      my $closest_resource = first { !length($_->[1]{path})       # document root
          || length($document_path)
            && path($_->[1]{path})->subsumes($document_path) }    # path is above present location
        sort { length($b->[1]{path}) <=> length($a->[1]{path}) }  # sort by length, descending
        grep { not length Mojo::URL->new($_->[0])->fragment }     # omit anchors
        $document->resource_pairs;

      $canonical_uri = $closest_resource->[1]{canonical_uri}->clone
        ->fragment(substr($document_path, length($closest_resource->[1]{path})));
      $canonical_uri->fragment(undef) if not length($canonical_uri->fragment);
    }
  }
  else {  # we are following a URI with a plain-name fragment
    if (my $resource = $self->_get_resource($uri)) {
      $subschema = $resource->{document}->get($document_path = $resource->{path});
      $canonical_uri = $resource->{canonical_uri}->clone; # this is *not* the anchor-containing URI
      $document = $resource->{document};
    }
  }

  return defined $subschema ? ($subschema, $canonical_uri, $document, $document_path) : ();
}

has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 1) },
);

1;
__END__

=pod

=for :header
=for stopwords schema subschema metaschema validator evaluator listref

=head1 SYNOPSIS

  use JSON::Schema::Modern;

  $js = JSON::Schema::Modern->new(
    output_format => 'flag',
    ... # other options
  );
  $result = $js->evaluate($instance_data, $schema_data);

=head1 DESCRIPTION

This module aims to be a fully-compliant L<JSON Schema|https://json-schema.org/> evaluator and
validator, targeting the currently-latest
L<Draft 2019-09|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>
version of the specification.

=head1 CONFIGURATION OPTIONS

=head2 specification_version

Indicates which version of the JSON Schema specification is used during evaluation. When not set,
this value is derived from the C<$schema> keyword in the schema used in evaluation, or defaults to
the latest (supported) version (draft2019-09). When left unset, the use of C<$schema> keywords in
the schema is permitted, to switch between draft versions.

May be one of:

=for :list
* L<C<draft2019-09>|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>,
  corresponding to metaschema C<https://json-schema.org/draft/2019-09/schema>.
* L<C<draft7>|https://json-schema.org/specification-links.html#draft-7>,
  corresponding to metaschema C<http://json-schema.org/draft-07/schema#>

=head2 output_format

One of: C<flag>, C<basic>, C<strict_basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>.
Passed to L<JSON::Schema::Modern::Result/output_format>.

=head2 short_circuit

When true, evaluation will return early in any execution path as soon as the outcome can be
determined, rather than continuing to find all errors or annotations. Be aware that this can result
in invalid results in the presence of keywords that depend on annotations, namely
C<unevaluatedItems> and C<unevaluatedProperties>.

Defaults to true when C<output_format> is C<flag>, and false otherwise.

=head2 max_traversal_depth

The maximum number of levels deep a schema traversal may go, before evaluation is halted. This is to
protect against accidental infinite recursion, such as from two subschemas that each reference each
other, or badly-written schemas that could be optimized. Defaults to 50.

=head2 validate_formats

When true, the C<format> keyword will be treated as an assertion, not merely an annotation. Defaults
to false.

=head2 format_validations

An optional hashref that allows overriding the validation method for formats, or adding new ones.
Overrides to existing formats (see L</Format Validation>)
must be specified in the form of C<< { $format_name => $format_sub } >>, where
the format sub is a coderef that takes one argument and returns a boolean result. New formats must
be specified in the form of C<< { $format_name => { type => $type, sub => $format_sub } } >>,
where the type indicates which of the core JSON Schema types (null, object, array, boolean, string,
number, or integer) the instance value must be for the format validation to be considered.

=head2 collect_annotations

When true, annotations are collected from keywords that produce them, when validation succeeds.
These annotations are available in the returned result (see L<JSON::Schema::Modern::Result>).
Defaults to false.

=head2 annotate_unknown_keywords

When true, keywords that are not recognized by any vocabulary are collected as annotations (where
the value of the annotation is the value of the keyword). L</collect_annotations> must also be true
in order for this to have any effect.
Defaults to false (for now).

=head1 METHODS

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema);
  $result = $js->evaluate_json_string($data_as_json_string, $schema, { collect_annotations => 1});

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://tools.ietf.org/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema must be in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Modern::Document> object,
* or a URI string indicating the location where such a schema is located.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations>, L</annotate_unknown_keywords> and/or
L</validate_formats> settings for just this evaluation call.

The result is a L<JSON::Schema::Modern::Result> object, which can also be used as a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema);
  $result = $js->evaluate($instance_data, $schema, { short_circuit => 0 });

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows: null, boolean, string, number, object, array. (See L</TYPES> below.)

The schema must be in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Modern::Document> object,
* or a URI string indicating the location where such a schema is located.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations>, L</annotate_unknown_keywords> and/or
L</validate_formats> settings for just this
evaluation call.

The result is a L<JSON::Schema::Modern::Result> object, which can also be used as a boolean.

=head2 traverse

  $result = $js->traverse($schema);
  $result = $js->traverse($schema, { initial_schema_uri => 'http://example.com' });

Traverses the provided schema without evaluating it against any instance data. Returns the
internal state object accumulated during the traversal, including any identifiers found therein, and
any errors found during parsing. For internal purposes only.

You can pass a series of callback subs to this method corresponding to keywords, which is useful for
extracting data from within schemas and skipping properties that may look like keywords but actually
are not (for example C<{"const":{"$ref": "this is not actually a $ref"}}>). This feature is highly
experimental and is highly likely to change in the future.

For example, to find the resolved targets of all C<$ref> keywords in a schema document:

  my @refs;
  JSON::Schema::Modern->new->traverse($schema, {
    callbacks => {
      '$ref' => sub ($schema, $state) {
        push @refs, Mojo::URL->new($schema->{'$ref'})
          ->to_abs(JSON::Schema::Modern::Utilities::canonical_schema_uri($state));
      }
    },
  });

=head2 add_schema

  $js->add_schema($uri => $schema);
  $js->add_schema($uri => $document);
  $js->add_schema($schema);
  $js->add_schema($document);

Introduces the (unblessed, nested) Perl data structure or L<JSON::Schema::Modern::Document>
object, representing a JSON Schema, to the implementation, registering it under the indicated URI if
provided (and if not, C<''> will be used if no other identifier can be found within).

You B<MUST> call C<add_schema> for any external resources that a schema may reference via C<$ref>
before calling L</evaluate>, other than the standard metaschemas which are loaded from a local cache
as needed.

Returns C<undef> if the resource could not be found;
if there were errors in the document, will die with these errors;
otherwise returns the L<JSON::Schema::Modern::Document> that contains the added schema.

=head2 get

  my $schema = $js->get($uri);
  my ($schema, $canonical_uri) = $js->get($uri);

Fetches the Perl data structure representing the JSON Schema at the indicated URI. When called in
list context, the canonical URI of that location is also returned, as a L<Mojo::URL>. Returns
C<undef> if the schema with that URI has not been loaded (or cached).

=head1 LIMITATIONS

=head2 Types

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value. However, if a value is
used in another context (for example, a numeric value is concatenated into a string, or a numeric
string is used in an arithmetic operation), additional flags can be added onto the variable causing
it to resemble the other type. This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.
If this turns out to be an issue in real environments, I may have to implement a C<lax_scalars>
option.

For more information, see L<Cpanel::JSON::XS/MAPPING>.

=head2 Format Validation

By default, formats are treated only as annotations, not assertions. When L</validate_format> is
true, strings are also checked against the format as specified in the schema. At present the
following formats are supported (use of any other formats than these will always evaluate as true):

=for :list
* C<date-time>
* C<date>
* C<time>
* C<duration>
* C<email>
* C<idn-email>
* C<hostname>
* C<idn-hostname>
* C<ipv4>
* C<ipv6>
* C<uri>
* C<uri-reference>
* C<iri>
* C<uuid>
* C<json-pointer>
* C<relative-json-pointer>
* C<regex>

A few optional prerequisites are needed for some of these (if the prerequisite is missing,
validation will always succeed):

=for :list
* C<date-time>, C<date>, and C<time> require L<Time::Moment>
* C<email> and C<idn-email> require L<Email::Address::XS> version 1.01 (or higher)
* C<hostname> and C<idn-hostname> require L<Data::Validate::Domain>
* C<idn-hostname> requires L<Net::IDN::Encode>

=head2 Specification Compliance

Until version 1.000 is released, this implementation is not fully specification-compliant.

To date, missing features (some of which are optional, but still quite useful) include:

=for :list
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* additional output formats beyond C<flag>, C<basic>, C<strict_basic>, and C<terse>
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* examination of the C<$schema> keyword for deviation from the standard draft metaschemas, including
  changes to vocabulary behaviour
* changing the draft specification version semantics after construction time

Additionally, some small errors in the specification (which have been fixed in the next draft
specification version) are fixed here rather than implementing the precise but unintended behaviour,
most notably in the use of json pointers rather than fragment-only URIs in C<instanceLocation> and
C<keywordLocation> in annotations and errors. (Use the C<strict_basic>
L<JSON::Schema::Modern/output_format> to revert this change.)

=head1 SECURITY CONSIDERATIONS

The C<pattern> and C<patternProperties> keywords, and the C<regex> format validator,
evaluate regular expressions from the schema.
No effort is taken (at this time) to sanitize the regular expressions for embedded code or
potentially pathological constructs that may pose a security risk, either via denial of service
or by allowing exposure to the internals of your application. B<DO NOT USE SCHEMAS FROM UNTRUSTED
SOURCES.>

=head1 SEE ALSO

=for :list
* L<https://json-schema.org>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://tools.ietf.org/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://tools.ietf.org/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>: contains the official JSON Schema test suite
* L<JSON::Schema::Tiny>: a more minimal implementation of the specification, with fewer dependencies
* L<https://json-schema.org/draft/2019-09/release-notes.html>
# L<https://json-schema.org/draft-07/json-schema-release-notes.html>
* L<Understanding JSON Schema|https://json-schema.org/understanding-json-schema>: tutorial-focused documentation

=cut
