use strict;
use warnings;
package JSON::Schema::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.549';

use 5.020;  # for fc, unicode_strings features
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::MaybeXS;
use Carp qw(croak carp);
use List::Util 1.55 qw(pairs first uniqint pairmap uniq);
use Ref::Util 0.100 qw(is_ref is_plain_hashref);
use Scalar::Util 'refaddr';
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use Module::Runtime qw(use_module require_module);
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef Optional slurpy ArrayRef Undef ClassName Tuple Map);
use Feature::Compat::Try;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Result;
use JSON::Schema::Modern::Document;
use JSON::Schema::Modern::Utilities qw(get_type canonical_uri E abort annotate_self);
use namespace::clean;

our @CARP_NOT = qw(
  JSON::Schema::Modern::Document
  JSON::Schema::Modern::Vocabulary
  JSON::Schema::Modern::Vocabulary::Applicator
  OpenAPI::Modern
);

use constant SPECIFICATION_VERSION_DEFAULT => 'draft2020-12';
use constant SPECIFICATION_VERSIONS_SUPPORTED => [qw(draft7 draft2019-09 draft2020-12)];

has specification_version => (
  is => 'ro',
  isa => Enum(SPECIFICATION_VERSIONS_SUPPORTED),
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
  default => 0, # as specified by https://json-schema.org/draft/<version>/schema#/$vocabulary
);

has validate_content_schemas => (
  is => 'ro',
  isa => Bool,
  lazy => 1,
  # defaults to false in latest versions, as specified by
  # https://json-schema.org/draft/2020-12/json-schema-validation.html#rfc.section.8.2
  default => sub { ($_[0]->specification_version//'') eq 'draft7' },
);

has collect_annotations => (
  is => 'ro',
  isa => Bool,
);

has scalarref_booleans => (
  is => 'ro',
  isa => Bool,
);

has strict => (
  is => 'ro',
  isa => Bool,
);

has _format_validations => (
  is => 'bare',
  isa => my $format_type = Dict[
    (map +($_ => Optional[CodeRef]), qw(date-time date time duration email idn-email hostname idn-hostname ipv4 ipv6 uri uri-reference iri iri-reference uuid uri-template json-pointer relative-json-pointer regex)),
    slurpy HashRef[Dict[type => Enum[qw(null object array boolean string number integer)], sub => CodeRef]],
  ],
  init_arg => 'format_validations',
  handles_via => 'Hash',
  handles => {
    _get_format_validation => 'get',
    add_format_validation => 'set',
  },
  lazy => 1,
  default => sub { {} },
);

before add_format_validation => sub ($self, @kvs) { $format_type->({ @$_ }) foreach pairs @kvs };

around BUILDARGS => sub ($orig, $class, @args) {
  my $args = $class->$orig(@args);
  croak 'output_format: strict_basic can only be used with specification_version: draft2019-09'
    if ($args->{output_format}//'') eq 'strict_basic'
      and ($args->{specification_version}//'') ne 'draft2019-09';

  return $args;
};

sub add_schema {
  croak 'insufficient arguments' if @_ < 2;
  my $self = shift;

  # TODO: resolve $uri against $self->base_uri
  my $uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $uri->fragment;

  if (not @_) {
    my $schema_info = $self->_fetch_from_uri($uri);
    return if not $schema_info or not defined wantarray;
    return $schema_info->{document};
  }

  # document BUILD will trigger $self->traverse($schema)
  my $document = $_[0]->$_isa('JSON::Schema::Modern::Document') ? shift
    : JSON::Schema::Modern::Document->new(
      schema => shift,
      $uri ? (canonical_uri => $uri) : (),
      evaluator => $self,  # used mainly for traversal during document construction
    );

  if ($document->has_errors) {
    my $result = JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      errors => [ $document->errors ],
      exception => 1,
      mode => 'traverse',
    );
    die $result;
  }

  if (not grep refaddr($_->{document}) == refaddr($document), $self->_canonical_resources) {
    my $schema_content = $document->_serialized_schema
      // $document->_serialized_schema($self->_json_decoder->encode($document->schema));

    if (my $existing_doc = first {
          my $existing_content = $_->_serialized_schema
            // $_->_serialized_schema($self->_json_decoder->encode($_->schema));
          $existing_content eq $schema_content
        } uniqint map $_->{document}, $self->_canonical_resources) {
      # we already have this schema content in another document object.
      $document = $existing_doc;
    }
    else {
      $self->_add_resources(map +($_->[0] => +{ $_->[1]->%*, document => $document }),
        $document->resource_pairs);
    }
  }

  if ("$uri") {
    my $resource = $document->_get_resource($document->canonical_uri);
    $self->_add_resources($uri => {
        path => '',
        canonical_uri => $document->canonical_uri,
        specification_version => $resource->{specification_version},
        vocabularies => $resource->{vocabularies},  # reference, not copy
        document => $document,
        configs => $resource->{configs},
      });
  }

  return $document;
}

sub evaluate_json_string ($self, $json_data, $schema, $config_override = {}) {
  croak 'evaluate_json_string called in void context' if not defined wantarray;

  my $data;
  try {
    $data = $self->_json_decoder->decode($json_data)
  }
  catch ($e) {
    return JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      exception => 1,
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
# for now it is just called when a ::Document object is created, to verify the integrity of the
# schema structure, to identify the metaschema (via the $schema keyword), and to extract all
# embedded resources via $id and $anchor keywords within.
# Returns the internal $state object accumulated during the traversal.
sub traverse ($self, $schema_reference, $config_override = {}) {
  # Note: the starting position is not guaranteed to be at the root of the $document.
  my $initial_uri = Mojo::URL->new($config_override->{initial_schema_uri} // '');
  my $initial_path = $config_override->{traversed_schema_path} // '';
  my $spec_version = $self->specification_version//SPECIFICATION_VERSION_DEFAULT;

  my $state = {
    depth => 0,
    data_path => '',                        # this never changes since we don't have an instance yet
    initial_schema_uri => $initial_uri,     # the canonical URI as of the start of this method, or last $id
    traversed_schema_path => $initial_path, # the accumulated traversal path as of the start, or last $id
    schema_path => '',                      # the rest of the path, since the start of this method, or last $id
    effective_base_uri => Mojo::URL->new(''),
    errors => [],
    identifiers => [],
    configs => {},
    callbacks => $config_override->{callbacks} // {},
    evaluator => $self,
    traverse => 1,
  };

  try {
    my $for_canonical_uri = Mojo::URL->new(
      (is_plain_hashref($schema_reference) && exists $schema_reference->{'$id'}
          ? Mojo::URL->new($schema_reference->{'$id'}) : undef)
        // $state->{initial_schema_uri});
    $for_canonical_uri->fragment(undef) if not length $for_canonical_uri->fragment;

    # a subsequent "$schema" keyword can still change these values
    $state->@{qw(spec_version vocabularies)} = $self->_get_metaschema_info(
      $config_override->{metaschema_uri} // $self->METASCHEMA_URIS->{$spec_version},
      $for_canonical_uri,
    );
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      push $state->{errors}->@*, $e->errors;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      push $state->{errors}->@*, $e;
    }
    else {
      ()= E({ %$state, exception => 1 }, 'EXCEPTION: '.$e);
    }

    return $state;
  }

  try {
    $self->_traverse_subschema($schema_reference, $state);
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Error')) {
      # note: we should never be here, since traversal subs are no longer be fatal
      push $state->{errors}->@*, $e;
    }
    else {
      E({ %$state, exception => 1 }, 'EXCEPTION: '.$e);
    }
  }

  delete $state->{traverse};
  return $state;
}

# the actual runtime evaluation of the schema against input data.
sub evaluate ($self, $data, $schema_reference, $config_override = {}) {
  croak 'evaluate called in void context' if not defined wantarray;

  my $initial_path = $config_override->{traversed_schema_path} // '';
  my $effective_base_uri = Mojo::URL->new($config_override->{effective_base_uri}//'');

  my $state = {
    data_path => $config_override->{data_path} // '',
    traversed_schema_path => $initial_path, # the accumulated path as of the start of evaluation, or last $id or $ref
    initial_schema_uri => Mojo::URL->new,   # the canonical URI as of the start of evaluation, or last $id or $ref
    schema_path => '',                  # the rest of the path, since the start of evaluation, or last $id or $ref
    effective_base_uri => $effective_base_uri, # resolve locations against this for errors and annotations
    errors => [],
  };

  my $valid;
  try {
    my $schema_info;

    if (not is_ref($schema_reference) or $schema_reference->$_isa('Mojo::URL')) {
      $schema_info = $self->_fetch_from_uri($schema_reference);
      $state->{initial_schema_uri} = Mojo::URL->new($config_override->{initial_schema_uri} // '');
    }
    else {
      # traverse is called via add_schema -> ::Document->new -> ::Document->BUILD
      my $document = $self->add_schema('', $schema_reference);
      my $base_resource = $document->_get_resource($document->canonical_uri)
        || croak "couldn't get resource: document parse error";

      $schema_info = {
        schema => $document->schema,
        document => $document,
        document_path => '',
        $base_resource->%{qw(canonical_uri specification_version vocabularies configs)},
      };
    }

    abort($state, 'EXCEPTION: unable to find resource %s', $schema_reference)
      if not $schema_info;

    $state = +{
      %$state,
      depth => 0,
      initial_schema_uri => $schema_info->{canonical_uri}, # the canonical URI as of the start of evaluation, or last $id or $ref
      document => $schema_info->{document},   # the ::Document object containing this schema
      document_path => $schema_info->{document_path}, # the path within the document of this schema, as of the start of evaluation, or last $id or $ref
      dynamic_scope => [ $schema_info->{canonical_uri} ],
      annotations => [],
      seen => {},
      spec_version => $schema_info->{specification_version},
      vocabularies => $schema_info->{vocabularies},
      callbacks => $config_override->{callbacks} // {},
      evaluator => $self,
      $schema_info->{configs}->%*,
      (map {
        my $val = $config_override->{$_} // $self->$_;
        defined $val ? ( $_ => $val ) : ()
      } qw(validate_formats validate_content_schemas short_circuit collect_annotations scalarref_booleans strict)),
    };

    $valid = $self->_eval_subschema($data, $schema_info->{schema}, $state);
    warn 'result is false but there are no errors' if not $valid and not $state->{errors}->@*;
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      return $e;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      push $state->{errors}->@*, $e;
    }
    else {
      $valid = E({ %$state, exception => 1 }, 'EXCEPTION: '.$e);
    }
  }

  die 'evaluate validity inconstent with error count' if $valid xor !$state->{errors}->@*;

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

sub get ($self, $uri) {
  my $schema_info = $self->_fetch_from_uri($uri);
  return if not $schema_info;
  my $subschema = is_ref($schema_info->{schema}) ? dclone($schema_info->{schema}) : $schema_info->{schema};
  return wantarray ? ($subschema, $schema_info->{canonical_uri}) : $subschema;
}

# defined lower down:
# sub add_vocabulary { ... }
# sub add_encoding { ... }
# sub add_media_type { ... }

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
  'draft2020-12' => {
    id => [ '$id' ],
    definitions => [ '$defs' ],
    dependencies => [ qw(dependentSchemas dependentRequired) ],
    '$recursiveAnchor' => [ '$dynamicAnchor' ],
    '$recursiveRef' => [ '$dynamicRef' ],
    additionalItems => [ 'items' ],
  },
);

sub _traverse_subschema ($self, $schema, $state) {
  delete $state->{keyword};

  return E($state, 'EXCEPTION: maximum traversal depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = get_type($schema);
  return 1 if $schema_type eq 'boolean';

  return E($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  return 1 if not keys %$schema;

  my $valid = 1;
  my %unknown_keywords = map +($_ => undef), keys %$schema;
  # we must check the array length on every iteration because some keywords can change it!
  for (my $idx = 0; $idx <= $state->{vocabularies}->$#*; ++$idx) {
    my $vocabulary = $state->{vocabularies}[$idx];
    foreach my $keyword ($vocabulary->keywords($state->{spec_version})) {
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;
      my $method = '_traverse_keyword_'.($keyword =~ s/^\$//r);

      if (not $vocabulary->$method($schema, $state)) {
        die 'traverse returned false but we have no errors' if not $state->{errors}->@*;
        $valid = 0;
        next;
      }

      if (my $sub = $state->{callbacks}{$keyword}) {
        $sub->($schema, $state);
      }
    }
  }

  delete $state->{keyword};

  if ($self->strict and keys %unknown_keywords) {
    ()= E($state, 'unknown keyword%s found: %s', keys %unknown_keywords > 1 ? 's' : '',
      join(', ', sort keys %unknown_keywords));
  }

  # check for previously-supported but now removed keywords
  foreach my $keyword (sort keys $removed_keywords{$state->{spec_version}}->%*) {
    next if not exists $schema->{$keyword};
    my $message ='no-longer-supported "'.$keyword.'" keyword present (at location "'
      .canonical_uri($state).'")';
    if (my $alternates = $removed_keywords{$state->{spec_version}}->{$keyword}) {
      my @list = map '"'.$_.'"', @$alternates;
      @list = ((map $_.',', @list[0..$#list-1]), $list[-1]) if @list > 2;
      splice(@list, -1, 0, 'or') if @list > 1;
      $message .= ': this should be rewritten as '.join(' ', @list);
    }
    carp $message;
  }

  return $valid;
}

sub _eval_subschema ($self, $data, $schema, $state) {
  croak '_eval_subschema called in void context' if not defined wantarray;

  # callers created a new $state for us, so we do not propagate upwards changes to depth, traversed
  # paths; but annotations, errors are arrayrefs so their contents will be shared
  $state->{dynamic_scope} = [ ($state->{dynamic_scope}//[])->@* ];
  delete $state->@{'keyword', grep /^_/, keys %$state};

  abort($state, 'EXCEPTION: maximum evaluation depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  # find all schema locations in effect at this data path + canonical_uri combination
  # if any of them are absolute prefix of this schema location, we are in a loop.
  my $canonical_uri = canonical_uri($state);
  my $schema_location = $state->{traversed_schema_path}.$state->{schema_path};
  abort($state, 'EXCEPTION: infinite loop detected (same location evaluated twice)')
    if grep substr($schema_location, 0, length) eq $_,
      keys $state->{seen}{$state->{data_path}}{$canonical_uri}->%*;
  $state->{seen}{$state->{data_path}}{$canonical_uri}{$schema_location}++;

  my $schema_type = get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  # this should never happen, due to checks in traverse
  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  return 1 if not keys %$schema;

  my $valid = 1;
  my %unknown_keywords = map +($_ => undef), keys %$schema;
  my $orig_annotations = $state->{annotations};
  $state->{annotations} = [];
  my @new_annotations;

  my @vocabularies = $state->{vocabularies}->@*; # override locally only (copy, not reference)
  if ($state->{validate_formats}) {
    s/^JSON::Schema::Modern::Vocabulary::Format\KAnnotation$/Assertion/ foreach @vocabularies;
    require JSON::Schema::Modern::Vocabulary::FormatAssertion;
  }

  ALL_KEYWORDS:
  foreach my $vocabulary (@vocabularies) {
    foreach my $keyword ($vocabulary->keywords($state->{spec_version})) {
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;

      my $method = '_eval_keyword_'.($keyword =~ s/^\$//r);
      if (my $sub = $vocabulary->can($method)) {
        my $error_count = $state->{errors}->@*;

        if (not $sub->($vocabulary, $data, $schema, $state)) {
          warn 'result is false but there are no errors (keyword: '.$keyword.')'
            if $error_count == $state->{errors}->@*;
          $valid = 0;

          last ALL_KEYWORDS if $state->{short_circuit};
          next;
        }
      }

      if (my $sub = $state->{callbacks}{$keyword}) {
        $sub->($data, $schema, $state);
      }

      push @new_annotations, $state->{annotations}->@[$#new_annotations+1 .. $state->{annotations}->$#*];
    }
  }

  delete $state->{keyword};

  if ($state->{strict} and keys %unknown_keywords) {
    abort($state, 'unknown keyword%s found: %s', keys %unknown_keywords > 1 ? 's' : '',
      join(', ', sort keys %unknown_keywords));
  }

  $state->{annotations} = $orig_annotations;

  if ($valid) {
    push $state->{annotations}->@*, @new_annotations;
    if ($state->{collect_annotations} and $state->{spec_version} !~ qr/^draft(7|2019-09)$/) {
      annotate_self(+{ %$state, keyword => $_, _unknown => 1 }, $schema)
        foreach sort keys %unknown_keywords;
    }
  }

  return $valid;
}

has _resource_index => (
  is => 'bare',
  isa => HashRef[my $resource_type = Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,
      specification_version => my $spec_version_type = Enum(SPECIFICATION_VERSIONS_SUPPORTED),
      document => InstanceOf['JSON::Schema::Modern::Document'],
      # the vocabularies used when evaluating instance data against schema
      vocabularies => ArrayRef[my $vocabulary_class_type = ClassName->where(q{$_->DOES('JSON::Schema::Modern::Vocabulary')})],
      configs => HashRef,
      slurpy HashRef[Undef],  # no other fields allowed
    ]],
  handles_via => 'Hash',
  handles => {
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _resource_index => 'elements',
    _resource_keys => 'keys',
    _add_resources_unsafe => 'set',
    _canonical_resources => 'values',
    _resource_exists => 'exists',
  },
  lazy => 1,
  default => sub { {} },
);

around _add_resources => sub {
  my ($orig, $self) = (shift, shift);

  my @resources;
  foreach my $pair (sort { $a->[0] cmp $b->[0] } pairs @_) {
    my ($key, $value) = @$pair;

    $resource_type->($value); # check type of hash value against Dict

    if (my $existing = $self->_get_resource($key)) {
      # we allow overwriting canonical_uri = '' to allow for ad hoc evaluation of schemas that
      # lack all identifiers altogether, but preserve other resources from the original document
      if ($key ne '') {
        next if $existing->{path} eq $value->{path}
          and $existing->{canonical_uri} eq $value->{canonical_uri}
          and $existing->{specification_version} eq $value->{specification_version}
          and refaddr($existing->{document}) == refaddr($value->{document});
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

# $vocabulary uri (not its $id!) => [ spec_version, class ]
has _vocabulary_classes => (
  is => 'bare',
  isa => HashRef[
    Tuple[
      $spec_version_type,
      $vocabulary_class_type,
    ]
  ],
  handles_via => 'Hash',
  handles => {
    _get_vocabulary_class => 'get',
    _set_vocabulary_class => 'set',
    _get_vocabulary_values => 'values',
  },
  lazy => 1,
  default => sub {
    +{
      map { my $class = $_; pairmap { $a => [ $b, $class ] } $class->vocabulary }
        map use_module('JSON::Schema::Modern::Vocabulary::'.$_),
          qw(Core Applicator Validation FormatAssertion FormatAnnotation Content MetaData Unevaluated)
    }
  },
);

sub add_vocabulary ($self, $classname) {
  return if grep $_->[1] eq $classname, $self->_get_vocabulary_values;

  $vocabulary_class_type->(use_module($classname));

  # uri => version, uri => version
  foreach my $pair (pairs $classname->vocabulary) {
    my ($uri_string, $spec_version) = @$pair;
    Str->where(q{my $uri = Mojo::URL->new($_); $uri->is_abs && !defined $uri->fragment})->($uri_string);
    $spec_version_type->($spec_version);
    $self->_set_vocabulary_class($uri_string => [ $spec_version, $classname ])
  }
}

# $schema uri => [ spec_version, [ vocab classes ] ].
has _metaschema_vocabulary_classes => (
  is => 'bare',
  isa => HashRef[
    Tuple[
      $spec_version_type,
      ArrayRef[$vocabulary_class_type],
    ]
  ],
  handles_via => 'Hash',
  handles => {
    _get_metaschema_vocabulary_classes => 'get',
    _set_metaschema_vocabulary_classes => 'set',
    __all_metaschema_vocabulary_classes => 'values',
  },
  lazy => 1,
  default => sub {
    my @modules = map use_module('JSON::Schema::Modern::Vocabulary::'.$_),
      qw(Core Applicator Validation FormatAnnotation Content MetaData Unevaluated);
    +{
      'https://json-schema.org/draft/2020-12/schema' => [ 'draft2020-12', [ @modules ] ],
      do { pop @modules; () },
      'https://json-schema.org/draft/2019-09/schema' => [ 'draft2019-09', \@modules ],
      'http://json-schema.org/draft-07/schema#' => [ 'draft7', \@modules ],
    },
  },
);

# retrieves metaschema info either from cache or by parsing the schema for vocabularies
# throws a JSON::Schema::Modern::Result on error
sub _get_metaschema_info ($self, $metaschema_uri, $for_canonical_uri) {
  # check the cache
  my $metaschema_info = $self->_get_metaschema_vocabulary_classes($metaschema_uri);
  return @$metaschema_info if $metaschema_info;

  # otherwise, fetch the metaschema and parse its $vocabulary keyword.
  # we do this by traversing a baby schema with just the $schema keyword.
  my $state = $self->traverse({ '$schema' => $metaschema_uri.'' });
  die JSON::Schema::Modern::Result->new(
    output_format => $self->output_format,
    valid => JSON::PP::false,
    errors => [
      map {
        my $e = $_;
        # absolute location is undef iff the location = '/$schema'
        my $absolute_location = $e->absolute_keyword_location // $for_canonical_uri;
        JSON::Schema::Modern::Error->new(
          keyword => $e->keyword eq '$schema' ? '' : $e->keyword,
          instance_location => $e->instance_location,
          keyword_location => ($for_canonical_uri->fragment//'').($e->keyword_location =~ s{^/\$schema\b}{}r),
          length $absolute_location ? ( absolute_keyword_location => $absolute_location ) : (),
          error => $e->error,
        )
      }
      $state->{errors}->@* ],
    exception => 1,
    traverse => 1,
  ) if $state->{errors}->@*;
  return ($state->{spec_version}, $state->{vocabularies});
}

# used for determining a default '$schema' keyword where there is none
use constant METASCHEMA_URIS => {
  'draft2020-12' => 'https://json-schema.org/draft/2020-12/schema',
  'draft2019-09' => 'https://json-schema.org/draft/2019-09/schema',
  'draft7' => 'http://json-schema.org/draft-07/schema#',
};

use constant CACHED_METASCHEMAS => {
  'https://json-schema.org/draft/2020-12/meta/applicator'     => 'draft2020-12/meta/applicator.json',
  'https://json-schema.org/draft/2020-12/meta/content'        => 'draft2020-12/meta/content.json',
  'https://json-schema.org/draft/2020-12/meta/core'           => 'draft2020-12/meta/core.json',
  'https://json-schema.org/draft/2020-12/meta/format-annotation' => 'draft2020-12/meta/format-annotation.json',
  'https://json-schema.org/draft/2020-12/meta/format-assertion'  => 'draft2020-12/meta/format-assertion.json',
  'https://json-schema.org/draft/2020-12/meta/meta-data'      => 'draft2020-12/meta/meta-data.json',
  'https://json-schema.org/draft/2020-12/meta/unevaluated'    => 'draft2020-12/meta/unevaluated.json',
  'https://json-schema.org/draft/2020-12/meta/validation'     => 'draft2020-12/meta/validation.json',
  'https://json-schema.org/draft/2020-12/output/schema'       => 'draft2020-12/output/schema.json',
  'https://json-schema.org/draft/2020-12/schema'              => 'draft2020-12/schema.json',

  'https://json-schema.org/draft/2019-09/meta/applicator'     => 'draft2019-09/meta/applicator.json',
  'https://json-schema.org/draft/2019-09/meta/content'        => 'draft2019-09/meta/content.json',
  'https://json-schema.org/draft/2019-09/meta/core'           => 'draft2019-09/meta/core.json',
  'https://json-schema.org/draft/2019-09/meta/format'         => 'draft2019-09/meta/format.json',
  'https://json-schema.org/draft/2019-09/meta/meta-data'      => 'draft2019-09/meta/meta-data.json',
  'https://json-schema.org/draft/2019-09/meta/validation'     => 'draft2019-09/meta/validation.json',
  'https://json-schema.org/draft/2019-09/output/schema'       => 'draft2019-09/output/schema.json',
  'https://json-schema.org/draft/2019-09/schema'              => 'draft2019-09/schema.json',

  # trailing # is omitted because we always cache documents by its canonical (fragmentless) URI
  'http://json-schema.org/draft-07/schema' => 'draft7/schema.json',
};

# returns the same as _get_resource
sub _get_or_load_resource ($self, $uri) {
  my $resource = $self->_get_resource($uri);
  return $resource if $resource;

  if (my $local_filename = $self->CACHED_METASCHEMAS->{$uri}) {
    my $file = path(dist_dir('JSON-Schema-Modern'), $local_filename);
    my $schema = $self->_json_decoder->decode($file->slurp_raw);
    my $document = JSON::Schema::Modern::Document->new(schema => $schema, evaluator => $self);

    # this should be caught by the try/catch in evaluate()
    die JSON::Schema::Modern::Result->new(
      output_format => $self->output_format,
      valid => 0,
      errors => [ $document->errors ],
      exception => 1,
    ) if $document->has_errors;

    # we have already performed the appropriate collision checks, so we bypass them here
    $self->_add_resources_unsafe(
      map +($_->[0] => +{ $_->[1]->%*, document => $document }),
        $document->resource_pairs
    );

    return $self->_get_resource($uri);
  }

  # TODO:
  # - load from network or disk

  return;
};

# returns information necessary to use a schema found at a particular URI:
# - a schema (which may not be at a document root)
# - the canonical uri for that schema,
# - the JSON::Schema::Modern::Document object that holds that schema
# - the path relative to the document root for this schema
# - the specification version that applies to this schema
# - the vocabularies to use when considering schema keywords
# - the config overrides to set when considering schema keywords
# creates a Document and adds it to the resource index, if not already present.
sub _fetch_from_uri ($self, $uri) {
  $uri = Mojo::URL->new($uri) if not is_ref($uri);
  my $fragment = $uri->fragment;

  if (not length($fragment) or $fragment =~ m{^/}) {
    my $base = $uri->clone->fragment(undef);
    if (my $resource = $self->_get_or_load_resource($base)) {
      my $subschema = $resource->{document}->get(my $document_path = $resource->{path}.($fragment//''));
      return if not defined $subschema;
      my $document = $resource->{document};
      my $closest_resource = first { !length($_->[1]{path})       # document root
          || length($document_path)
            && $document_path =~ m{^\Q$_->[1]{path}\E(?:/|\z)} }  # path is above present location
        sort { length($b->[1]{path}) <=> length($a->[1]{path}) }  # sort by length, descending
        grep { not length Mojo::URL->new($_->[0])->fragment }     # omit anchors
        $document->resource_pairs;

      my $canonical_uri = $closest_resource->[1]{canonical_uri}->clone
        ->fragment(substr($document_path, length($closest_resource->[1]{path})));
      $canonical_uri->fragment(undef) if not length($canonical_uri->fragment);
      return {
        schema => $subschema,
        canonical_uri => $canonical_uri,
        document => $document,
        document_path => $document_path,
        $resource->%{qw(specification_version vocabularies configs)}, # reference, not copy
      };
    }
  }
  else {  # we are following a URI with a plain-name fragment
    if (my $resource = $self->_get_resource($uri)) {
      my $subschema = $resource->{document}->get($resource->{path});
      return if not defined $subschema;
      return {
        schema => $subschema,
        canonical_uri => $resource->{canonical_uri}->clone, # this is *not* the anchor-containing URI
        document => $resource->{document},
        document_path => $resource->{path},
        $resource->%{qw(specification_version vocabularies configs)}, # reference, not copy
      };
    }
  }
}

# used for internal encoding as well (when caching serialized schemas)
has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 1, allow_bignum => 1, convert_blessed => 1) },
);

# since media types are case-insensitive, all type names must be foldcased on insertion.
has _media_type => (
  is => 'bare',
  isa => my $media_type_type = Map[Str->where(q{$_ eq CORE::fc($_)}), CodeRef],
  handles_via => 'Hash',
  handles => {
    get_media_type => 'get',
    add_media_type => 'set',
    _media_types => 'keys',
  },
  lazy => 1,
  default => sub ($self) {
    my $_json_media_type = sub ($content_ref) {
      \ JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0)->decode($content_ref->$*);
    };
    +{
      # note: utf-8 decoding is NOT done, as we can't be sure that's the correct charset!
      'application/json' => $_json_media_type,
      'application/schema+json' => $_json_media_type,
      'application/schema-instance+json' => $_json_media_type,
      map +($_ => sub ($content_ref) { $content_ref }),
        qw(text/plain application/octet-stream),
    };
  },
);

# get_media_type('TExT/bloop') will match an entry for 'text/*' or '*/*'
# TODO: support queries for application/schema+json to match entry of application/json
around get_media_type => sub ($orig, $self, $type) {
  my $mt = $self->$orig(fc $type);
  return $mt if $mt;

  return $self->$orig((first { m{([^/]+)/\*$} && fc($type) =~ m{^\Q$1\E/[^/]+$} } $self->_media_types)
    // '*/*');
};

before add_media_type => sub ($self, $type, $sub) { $media_type_type->({ $type => $sub }) };

has _encoding => (
  is => 'bare',
  isa => HashRef[CodeRef],
  handles_via => 'Hash',
  handles => {
    get_encoding => 'get',
    add_encoding => 'set',
  },
  lazy => 1,
  default => sub ($self) {
    +{
      identity => sub ($content_ref) { $content_ref },
      base64 => sub ($content_ref) {
        die "invalid characters in base64 string"
          if $content_ref->$* =~ m{[^A-Za-z0-9+/=]} or $content_ref->$* =~ m{=(?=[^=])};
        require MIME::Base64; \ MIME::Base64::decode($content_ref->$*);
      },
    };
  },
);

sub FREEZE ($self, $serializer) {
  my $data = +{ %$self };
  # Cpanel::JSON::XS doesn't serialize: https://github.com/Sereal/Sereal/issues/266
  # coderefs can't serialize cleanly and must be re-added by the user.
  delete $data->@{qw(_json_decoder _format_validations _media_type _encoding)};
  return $data;
}

sub THAW ($class, $serializer, $data) {
  my $self = bless($data, $class);

  # load all vocabulary classes
  require_module($_) foreach uniq map $_->{vocabularies}->@*, $self->_canonical_resources;

  return $self;
}

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
L<Draft 2020-12|https://json-schema.org/specification-links.html#2020-12>
version of the specification.

=head1 CONFIGURATION OPTIONS

These values are all passed as arguments to the constructor.

=head2 specification_version

Indicates which version of the JSON Schema specification is used during evaluation. When not set,
this value is derived from the C<$schema> keyword in the schema used in evaluation, or defaults to
the latest version (draft2020-12). When left unset, the use of C<$schema> keywords in
the schema is permitted, to switch between draft versions.

May be one of:

=for :list
* L<C<draft2020-12>|https://json-schema.org/specification-links.html#2020-12>,
  corresponding to metaschema C<https://json-schema.org/draft/2020-12/schema>.
* L<C<draft2019-09>|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>,
  corresponding to metaschema C<https://json-schema.org/draft/2019-09/schema>.
* L<C<draft7>|https://json-schema.org/specification-links.html#draft-7>,
  corresponding to metaschema C<http://json-schema.org/draft-07/schema#>

=head2 output_format

One of: C<flag>, C<basic>, C<strict_basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>.
C<strict_basic> can only be used with C<specification_version = draft2019-09>.
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

=for stopwords subref

An optional hashref that allows overriding the validation method for formats, or adding new ones.
Overrides to existing formats (see L</Format Validation>)
must be specified in the form of C<< { $format_name => $format_sub } >>, where
the format sub is a subref that takes one argument and returns a boolean result. New formats must
be specified in the form of C<< { $format_name => { type => $type, sub => $format_sub } } >>,
where the type indicates which of the core JSON Schema types (null, object, array, boolean, string,
number, or integer) the instance value must be for the format validation to be considered.

=head2 validate_content_schemas

When true, the C<contentMediaType> and C<contentSchema> keywords are not treated as pure annotations:
C<contentEncoding> (when present) is used to decode the applied data payload and then
C<contentMediaType> will be used as the media-type for decoding to produce the data payload which is
then applied to the schema in C<contentSchema> for validation.

See L</add_media_type> and L</add_encoding> for adding additional type support.

=for stopwords shhh

Technically only draft7 allows this and drafts 2019-09 and 2020-12 prohibit ever returning the
subschema evaluation results together with their parent schema's, so shhh. I'm trying to get this
fixed for the next draft.

=head2 collect_annotations

When true, annotations are collected from keywords that produce them, when validation succeeds.
These annotations are available in the returned result (see L<JSON::Schema::Modern::Result>).
Defaults to false.

=head2 scalarref_booleans

When true, any type that is expected to be a boolean B<in the instance data> may also be expressed
as the scalar references C<\0> or C<\1> (which are serialized as booleans by JSON backends).
Defaults to false.

=head2 strict

When true, unrecognized keywords are disallowed in schemas (they will cause an immediate abort
in L</traverse> or L</evaluate>).

=head1 METHODS

=for Pod::Coverage BUILDARGS FREEZE THAW

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
L</short_circuit>, L</collect_annotations>, L</scalarref_booleans>,
L</strict>, L</validate_formats>, and/or L</validate_content_schemas>
settings for just this evaluation call.

You can also pass use these keys to alter behaviour (these are generally only used by custom validation
applications that contain embedded JSON Schemas):

=for :list
* C<data_path>: adjusts the effective path of the data instance as of the start of evaluation
* C<traversed_schema_path>: adjusts the accumulated path as of the start of evaluation (or last C<$id> or C<$ref>)
* C<initial_schema_uri>: adjusts the recorded absolute keyword location as of the start of evaluation
* C<effective_base_uri>: locations in errors and annotations are resolved against this URI

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
L</short_circuit>, L</collect_annotations>, L</scalarref_booleans>,
L</strict>, L</validate_formats>, and/or L</validate_content_schemas>
settings for just this evaluation call.

You can also pass use these keys to alter behaviour (these are generally only used by custom validation
applications that contain embedded JSON Schemas):

=for :list
* C<data_path>: adjusts the effective path of the data instance as of the start of evaluation
* C<traversed_schema_path>: adjusts the accumulated path as of the start of evaluation (or last C<$id> or C<$ref>)
* C<initial_schema_uri>: adjusts the recorded absolute keyword location as of the start of evaluation
* C<effective_base_uri>: locations in errors and annotations are resolved against this URI

You can pass a series of callback subs to this method corresponding to keywords, which is useful for
identifying various data that are not exposed by annotations.
This feature is highly experimental and may change in the future.

For example, to find the locations where all C<$ref> keywords are applied B<successfully>:

  my @used_ref_at;
  $js->evaluate($data, $schema_or_uri, {
    callbacks => {
      '$ref' => sub ($data, $schema, $state) {
        push @used_ref_at, $state->{data_path};
      }
    },
  });

The result is a L<JSON::Schema::Modern::Result> object, which can also be used as a boolean.

=head2 traverse

  $result = $js->traverse($schema);
  $result = $js->traverse($schema, { initial_schema_uri => 'http://example.com' });

Traverses the provided schema without evaluating it against any instance data. Returns the
internal state object accumulated during the traversal, including any identifiers found therein, and
any errors found during parsing. For internal purposes only.

Optionally, a hashref can be passed as a second parameter which alters some
behaviour (these are generally only used by custom validation
applications that contain embedded JSON Schemas):

=for :list
* C<traversed_schema_path>: adjusts the accumulated path as of the start of evaluation (or last C<$id> or C<$ref>)
* C<initial_schema_uri>: adjusts the recorded absolute keyword location as of the start of evaluation
* C<metaschema_uri>: use the indicated URI as the metaschema

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
          ->to_abs(JSON::Schema::Modern::Utilities::canonical_uri($state));
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

=head2 add_format_validation

=for comment we are the nine Eleven Deniers

  $js->add_format_validation(no_nines => { type => 'number', sub => sub ($value) { $value =~ m/^[0-8]$$/ });

Adds support for a custom format. The data type that this format applies to must be supplied; all
values of any other type will automatically be deemed to be valid, and will not be passed to the
subref.

=head2 add_vocabulary

  $js->add_vocabulary('My::Custom::Vocabulary::Class');

Makes a custom vocabulary class available to metaschemas that make use of this vocabulary.
as described in the specification at
L<"Meta-Schemas and Vocabularies"|https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.8.1>.

The class must compose the L<JSON::Schema::Modern::Vocabulary> role and implement the
L<vocabulary|JSON::Schema::Modern::Vocabulary/vocabulary> and
L<keywords|JSON::Schema::Modern::Vocabulary/keywords> methods.

=head2 add_media_type

  $js->add_media_type('application/furble' => sub ($content_ref) {
    return ...;  # data representing the deserialized text for Content-Type: application/furble
  });

Takes a media-type name and a subref which takes a single scalar reference, which is expected to be
a reference to a string, which might contain wide characters (i.e. not octets), especially when used
in conjunction with L</get_encoding> below. Must return B<a reference to a value of any type> (which is
then dereferenced for the C<contentSchema> keyword).

These media types are already known:

=for :list
* C<application/json>
* C<application/schema+json>
* C<application/schema-instance+json>
* C<application/octet-stream>
* C<text/plain>

=head2 get_media_type

Fetches a decoder sub for the indicated media type. Lookups are performed B<without case sensitivity>.

=for stopwords thusly

You can use it thusly:

  my $decoder = $self->get_media_type('application/furble') or die 'cannot find media type decoder';
  my $content_ref = $decoder->(\$content_string);

=head2 add_encoding

  $js->add_media_type('application/furble' => sub ($content_ref) {
    return \ ...;  # data representing the deserialized content for Content-Type: application/furble
  });

Takes an encoding name and a subref which takes a single scalar reference, which is expected to be
a reference to a string, which SHOULD be a 7-bit or 8-bit string. Result values MUST be a scalar-reference
to a string (which is then dereferenced for the C<contentMediaType> keyword).

=for stopwords natively

Encodings handled natively are:

=for :list
* C<identity>
* C<base64>

See also L<HTTP::Message/encode>.

=head2 get_encoding

Fetches a decoder sub for the indicated encoding. Incoming values MUST be a reference to an octet
string. Result values will be a scalar-reference to a string, which might be passed to a media_type
decoder (see above).

You can use it thusly:

  my $decoder = $self->get_encoding('base64') or die 'cannot find encoding decoder';
  my $content_ref = $decoder->(\$content_string);

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

By default (and unless you specify a custom metaschema with the C<$schema> keyword or
L<JSON::Schema::Modern::Document/metaschema>),
formats are treated only as annotations, not assertions. When L</validate_formats> is
true, strings are also checked against the format as specified in the schema. At present the
following formats are supported (use of any other formats than these will always evaluate as true,
but remember you can always supply custom format handlers; see L</format_validations> above):

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
* C<date-time>, C<date>, and C<time> require L<Time::Moment>, L<DateTime::Format::RFC3339>
* C<email> and C<idn-email> require L<Email::Address::XS> version 1.04 (or higher)
* C<hostname> and C<idn-hostname> require L<Data::Validate::Domain>
* C<idn-hostname> requires L<Net::IDN::Encode>

=head2 Specification Compliance

This implementation is now fully specification-compliant (for versions draft7, draft2019-09,
draft2020-12), but until version 1.000 is released, it is
still deemed to be missing some optional but quite useful features, such as:

=for :list
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* additional output formats beyond C<flag>, C<basic>, and C<terse>
  (L<https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.12>)

=head1 SECURITY CONSIDERATIONS

The C<pattern> and C<patternProperties> keywords evaluate regular expressions from the schema,
the C<regex> format validator evaluates regular expressions from the data, and some keywords
in the Validation vocabulary perform floating point operations on potentially-very large numbers.
No effort is taken (at this time) to sanitize the regular expressions for embedded code or
detect potentially pathological constructs that may pose a security risk, either via denial of
service or by allowing exposure to the internals of your application. B<DO NOT USE SCHEMAS FROM
UNTRUSTED SOURCES.>

=head1 SEE ALSO

=for :list
* L<json-schema-eval>
* L<https://json-schema.org>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://tools.ietf.org/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://tools.ietf.org/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>: contains the official JSON Schema test suite
* L<JSON::Schema::Tiny>: a more stripped-down implementation of the specification, with fewer
  dependencies and faster evaluation
* L<https://json-schema.org/draft/2020-12/release-notes.html>
* L<https://json-schema.org/draft/2019-09/release-notes.html>
* L<https://json-schema.org/draft-07/json-schema-release-notes.html>
* L<Understanding JSON Schema|https://json-schema.org/understanding-json-schema>: tutorial-focused documentation

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
