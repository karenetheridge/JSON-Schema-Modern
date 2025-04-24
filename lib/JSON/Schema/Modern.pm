use strict;
use warnings;
package JSON::Schema::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema using a JSON Schema
# KEYWORDS: JSON Schema validator data validation structure specification

our $VERSION = '0.610';

use 5.020;  # for fc, unicode_strings features
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Mojo::JSON ();  # for JSON_XS, MOJO_NO_JSON_XS environment variables
use Carp qw(croak carp);
use List::Util 1.55 qw(pairs first uniqint pairmap uniq any);
use Ref::Util 0.100 qw(is_ref is_plain_hashref);
use builtin::compat qw(refaddr load_module);
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use MooX::TypeTiny 0.002002;
use Types::Standard 1.016003 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef Optional Slurpy ArrayRef Undef ClassName Tuple Map);
use Digest::MD5 'md5';
use Feature::Compat::Try;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Result;
use JSON::Schema::Modern::Document;
use JSON::Schema::Modern::Utilities qw(get_type canonical_uri E abort annotate_self jsonp is_type assert_uri local_annotations);
use namespace::clean;

our @CARP_NOT = qw(
  JSON::Schema::Modern::Document
  JSON::Schema::Modern::Vocabulary
  JSON::Schema::Modern::Vocabulary::Applicator
  JSON::Schema::Modern::Document::OpenAPI
  OpenAPI::Modern
);

use constant SPECIFICATION_VERSION_DEFAULT => 'draft2020-12';
use constant SPECIFICATION_VERSIONS_SUPPORTED => [qw(draft4 draft6 draft7 draft2019-09 draft2020-12)];

has specification_version => (
  is => 'ro',
  isa => Enum(SPECIFICATION_VERSIONS_SUPPORTED),
  coerce => sub {
    return $_[0] if any { $_[0] eq $_ } SPECIFICATION_VERSIONS_SUPPORTED->@*;
    my $real = 'draft'.($_[0]//'');
    (any { $real eq $_ } SPECIFICATION_VERSIONS_SUPPORTED->@*) ? $real : $_[0];
  },
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
  lazy => 1,
  # as specified by https://json-schema.org/draft/<version>/schema#/$vocabulary
  default => sub { ($_[0]->specification_version//SPECIFICATION_VERSION_DEFAULT) =~ /^draft[467]$/ ? 1 : 0 },
);

has validate_content_schemas => (
  is => 'ro',
  isa => Bool,
  lazy => 1,
  # defaults to false in latest versions, as specified by
  # https://json-schema.org/draft/2020-12/json-schema-validation.html#rfc.section.8.2
  default => sub { ($_[0]->specification_version//'') eq 'draft7' },
);

has [qw(collect_annotations scalarref_booleans stringy_numbers strict)] => (
  is => 'ro',
  isa => Bool,
);

my $core_types = Enum[qw(null object array boolean string number)];
my @core_formats = qw(date-time date time duration email idn-email hostname idn-hostname ipv4 ipv6 uri uri-reference iri iri-reference uuid uri-template json-pointer relative-json-pointer regex);

# { $format_name => { type => ..., sub => ... }, ... }
has _format_validations => (
  is => 'bare',
  isa => my $format_type = HashRef[Dict[
      type => $core_types|ArrayRef[$core_types],
      sub => CodeRef,
    ]],
  init_arg => 'format_validations',
);

sub _get_format_validation ($self, $format) { ($self->{_format_validations}//{})->{$format} }

sub add_format_validation ($self, $format, $definition) {
  $definition = { type => 'string', sub => $definition } if not is_plain_hashref($definition);
  $format_type->({ $format => $definition });

  # all core formats are of type string (so far); changing type of custom format is permitted
  croak "Type for override of format $format does not match original type"
    if any { $format eq $_ } @core_formats and $definition->{type} ne 'string';

  use autovivification 'store';
  $self->{_format_validations}{$format} = $definition;
}

around BUILDARGS => sub ($orig, $class, @args) {
  my $args = $class->$orig(@args);
  croak 'output_format: strict_basic can only be used with specification_version: draft2019-09'
    if ($args->{output_format}//'') eq 'strict_basic'
      and ($args->{specification_version}//'') ne 'draft2019-09';

  croak 'collect_annotations cannot be used with specification_version '.$args->{specification_version}
    if $args->{collect_annotations} and ($args->{specification_version}//'') =~ /^draft[467]$/;

  $args->{format_validations} = +{
    map +($_->[0] => is_plain_hashref($_->[1]) ? $_->[1] : +{ type => 'string', sub => $_->[1] }),
      pairs $args->{format_validations}->%*
  } if $args->{format_validations};

  return $args;
};

sub add_schema {
  croak 'insufficient arguments' if @_ < 2;
  my $self = shift;

  # TODO: resolve $uri against $self->base_uri
  my $uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $uri->fragment;
  croak 'insufficient arguments' if not @_;

  if ($_[0]->$_isa('JSON::Schema::Modern::Document')) {
    Carp::carp('use of deprecated form of add_schema with document');
    return $self->add_document($uri, $_[0]);
  }

  # document BUILD will trigger $self->traverse($schema)
  # Note we do not pass the uri to the document constructor, so resources in that document may still
  # be relative
  my $document = JSON::Schema::Modern::Document->new(
    schema => $_[0],
    evaluator => $self,  # used mainly for traversal during document construction
  );

  # try to reuse the same document, if the same schema is being added twice:
  # this results in _add_resource silently ignoring the duplicate add, rather than erroring.
  my $schema_checksum = $document->_checksum(md5($self->_json_decoder->encode($document->schema)));
  if (my $existing_doc = first {
        my $existing_checksum = $_->_checksum
          // $_->_checksum(md5($self->_json_decoder->encode($_->schema)));
        $existing_checksum eq $schema_checksum
          and $_->canonical_uri eq $document->canonical_uri
          # FIXME: must also check spec version/metaschema_uri/vocabularies
      } uniqint map $_->{document}, $self->_canonical_resources) {
    $document = $existing_doc;
  }

  $self->add_document($uri, $document);
}

sub add_document {
  croak 'insufficient arguments' if @_ < 2;
  my $self = shift;

  # TODO: resolve $uri against $self->base_uri
  my $base_uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $base_uri->fragment;

  my $document = shift or croak 'insufficient arguments';
  croak 'wrong document type' if not $document->$_isa('JSON::Schema::Modern::Document');

  die JSON::Schema::Modern::Result->new(
    output_format => $self->output_format,
    valid => 0,
    errors => [ $document->errors ],
    exception => 1,
  ) if $document->has_errors;

  my @root; # uri_string => resource hash of the resource at path ''

  # document resources are added after resolving each resource against our provided base uri
  foreach my $res_pair ($document->resource_pairs) {
    my ($uri_string, $doc_resource) = @$res_pair;
    $uri_string = Mojo::URL->new($uri_string)->to_abs($base_uri)->to_string if length $base_uri;

    my $new_resource = {
      $doc_resource->%{qw(path specification_version vocabularies configs)},
      document => $document,
    };

    $new_resource->{canonical_uri} = length $base_uri
      ? Mojo::URL->new($doc_resource->{canonical_uri})->to_abs($base_uri)
      : $doc_resource->{canonical_uri};

    foreach my $anchor (keys (($doc_resource->{anchors}//{})->%*)) {
      use autovivification 'store';
      $new_resource->{anchors}{$anchor} = {
        path => $doc_resource->{anchors}{$anchor}{path},
        canonical_uri => length $base_uri
          ? Mojo::URL->new($doc_resource->{anchors}{$anchor}{canonical_uri})->to_abs($base_uri)
          : $doc_resource->{anchors}{$anchor}{canonical_uri},
      };
    }

    # this might croak if there are duplicates or malformed entries.
    $self->_add_resource($uri_string => $new_resource);
    @root = ( $uri_string => $new_resource ) if $new_resource->{path} eq '' and $uri_string !~ /#./;
  }

  # associate the root resource with the base uri we were provided, if it does not already exist
  $self->_add_resource($base_uri.'' => $root[1]) if length $base_uri and $root[0] ne $base_uri;

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
          depth => 0,
          mode => 'evaluate',
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
  my %overrides = %$config_override;
  delete @overrides{qw(callbacks initial_schema_uri metaschema_uri traversed_schema_path specification_version)};
  croak join(', ', sort keys %overrides), ' not supported as a config override in traverse'
    if keys %overrides;

  # Note: the starting position is not guaranteed to be at the root of the $document,
  # nor is the fragment portion of this uri necessarily empty
  my $initial_uri = Mojo::URL->new($config_override->{initial_schema_uri} // '');
  my $initial_path = $config_override->{traversed_schema_path} // '';
  my $spec_version = $config_override->{specification_version} // $self->specification_version // SPECIFICATION_VERSION_DEFAULT;

  croak 'traversed_schema_path must be a json pointer' if $initial_path !~ m{^(?:/|$)};

  if (length(my $uri_path = $initial_uri->fragment)) {
    croak 'initial_schema_uri fragment must be a json pointer' if $uri_path !~ m{^/};

    croak 'traversed_schema_path does not match initial_schema_uri path fragment'
      if substr($initial_path, -length($uri_path)) ne $uri_path;
  }

  my $state = {
    depth => 0,
    data_path => '',                        # this never changes since we don't have an instance yet
    initial_schema_uri => $initial_uri,     # the canonical URI as of the start of this method or last $id
    traversed_schema_path => $initial_path, # the accumulated traversal path as of the start or last $id
    schema_path => '',                      # the rest of the path, since the start of this method or last $id
    errors => [],
    identifiers => {},
    subschemas => [],
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

    my $valid = $self->_traverse_subschema($schema_reference, $state);
    die 'result is false but there are no errors' if not $valid and not $state->{errors}->@*;
    die 'result is true but there are errors' if $valid and $state->{errors}->@*;
  }
  catch ($e) {
    if ($e->$_isa('JSON::Schema::Modern::Result')) {
      push $state->{errors}->@*, $e->errors;
    }
    elsif ($e->$_isa('JSON::Schema::Modern::Error')) {
      # note: we should never be here, since traversal subs are no longer fatal
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

  my %overrides = %$config_override;
  delete @overrides{qw(validate_formats validate_content_schemas short_circuit collect_annotations scalarref_booleans stringy_numbers strict callbacks effective_base_uri data_path traversed_schema_path _strict_schema_data)};
  croak join(', ', sort keys %overrides), ' not supported as a config override in evaluate'
    if keys %overrides;

  my $state = {
    data_path => $config_override->{data_path} // '',
    traversed_schema_path => $config_override->{traversed_schema_path} // '', # the accumulated path as of the start of evaluation or last $id or $ref
    initial_schema_uri => Mojo::URL->new,   # the canonical URI as of the start of evaluation or last $id or $ref
    schema_path => '',                  # the rest of the path, since the start of evaluation or last $id or $ref
    errors => [],
    depth => 0,
    configs => {},
  };

  # resolve locations against this for errors and annotations, if locations are not already absolute
  if (length $config_override->{effective_base_uri}) {
    $state->{effective_base_uri} = Mojo::URL->new($config_override->{effective_base_uri});
    croak 'it is meaningless for effective_base_uri to have a fragment'
      if defined $state->{effective_base_uri}->fragment;
  }

  my $valid;
  try {
    # traverse is called via add_schema -> ::Document->new -> ::Document->BUILD
    $schema_reference = $self->add_schema($schema_reference)->canonical_uri
      if is_ref($schema_reference) and not $schema_reference->$_isa('Mojo::URL');

    my $schema_info = $self->_fetch_from_uri($schema_reference);
    abort($state, 'EXCEPTION: unable to find resource "%s"', $schema_reference)
      if not $schema_info;

    abort($state, 'EXCEPTION: collect_annotations cannot be used with specification_version '.$schema_info->{specification_version})
      if $config_override->{collect_annotations} and $schema_info->{specification_version} =~ /^draft[467]$/;

    abort($state, 'EXCEPTION: "%s" is not a schema', $schema_reference)
      if not $schema_info->{document}->get_entity_at_location($schema_info->{document_path});

    $state = +{
      %$state,
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
        # note: this is a subset of the allowed overrides defined above
      } qw(validate_formats validate_content_schemas short_circuit collect_annotations scalarref_booleans stringy_numbers strict)),
    };

    # this hash will be added to at each level of schema evaluation
    $state->{seen_data_properties} = {} if $config_override->{_strict_schema_data};

    # we're going to set collect_annotations during evaluation when we see an unevaluated* keyword
    # (or for object data when the _strict_schema_data configuration is set),
    # but after we pass to a new data scope we'll clear it again.. unless we've got the config set
    # globally for the entire evaluation, so we store that value in a high bit.
    $state->{collect_annotations} = ($state->{collect_annotations}//0) << 8;

    $valid = $self->_eval_subschema($data, $schema_info->{schema}, $state);
    warn 'result is false but there are no errors' if not $valid and not $state->{errors}->@*;
    warn 'result is true but there are errors' if $valid and $state->{errors}->@*;
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

  if ($state->{seen_data_properties}) {
    my @unevaluated_properties = grep !$state->{seen_data_properties}{$_}, keys $state->{seen_data_properties}->%*;
    foreach my $property (sort @unevaluated_properties) {
      $valid = E({ %$state, data_path => $property }, 'unknown keyword found in schema: %s',
        $property =~ m{/([^/]+)$});
    }
  }

  die 'evaluate validity inconsistent with error count' if $valid xor !$state->{errors}->@*;

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

sub validate_schema ($self, $schema, $config_override = {}) {
  croak 'validate_schema called in void context' if not defined wantarray;

  my $metaschema_uri = is_plain_hashref($schema) && $schema->{'$schema'} ? $schema->{'$schema'}
    : $self->METASCHEMA_URIS->{$self->specification_version // $self->SPECIFICATION_VERSION_DEFAULT};

  my $result = $self->evaluate($schema, $metaschema_uri,
    { %$config_override, $self->strict || $config_override->{strict} ? (_strict_schema_data => 1) : () });

  return $result if not $result->valid;

  my $state = $self->traverse($schema, $config_override);
  return JSON::Schema::Modern::Result->new(
    output_format => $self->output_format,
    valid => 0,
    errors => $state->{errors},
  ) if $state->{errors}->@*;

  return $result; # valid: true
}

sub get ($self, $uri_reference) {
  if (wantarray) {
    my $schema_info = $self->_fetch_from_uri($uri_reference);
    return if not $schema_info;
    my $subschema = is_ref($schema_info->{schema}) ? dclone($schema_info->{schema}) : $schema_info->{schema};
    return ($subschema, $schema_info->{canonical_uri});
  }
  else {  # abridged version of _fetch_from_uri
    $uri_reference = Mojo::URL->new($uri_reference) if not is_ref($uri_reference);
    my $fragment = $uri_reference->fragment;
    my $resource = $self->_get_or_load_resource($uri_reference->clone->fragment(undef));
    return if not $resource;

    my $schema;
    if (not length($fragment) or $fragment =~ m{^/}) {
      $schema = $resource->{document}->get($resource->{path}.($fragment//''));
    }
    else {  # we are following a URI with a plain-name fragment
      return if not my $subresource = ($resource->{anchors}//{})->{$fragment};
      $schema = $resource->{document}->get($subresource->{path});
    }
    return is_ref($schema) ? dclone($schema) : $schema;
  }
}

sub get_document ($self, $uri_reference) {
  my $schema_info = $self->_fetch_from_uri($uri_reference);
  return if not $schema_info;
  return $schema_info->{document};
}

# defined lower down:
# sub add_media_type ($self, $media_type, $sub) { ... }
# sub get_media_type ($self, $media_type) { ... }
# sub add_encoding ($self, $encoding, $sub) { ... }
# sub get_encoding ($self, $encoding) { ... }
# sub add_vocabulary ($self, $classname) { ... }

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

# current spec version => { keyword => undef, or arrayref of alternatives }
my %removed_keywords = (
  'draft4' => {
  },
  'draft6' => {
    id => [ '$id' ],
  },
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

# {
#   $spec_version => {
#     $vocabulary_class => {
#       traverse => [ [ $keyword => $subref ], [ ... ] ],
#       evaluate => [ [ $keyword => $subref ], [ ... ] ],
#     }
#   }
# }
# If we could serialize coderefs, this could be an object attribute;
# otherwise, we might as well persist this for the lifetime of the process.
our $vocabulary_cache = {};

sub _traverse_subschema ($self, $schema, $state) {
  delete $state->@{'keyword', grep /^_/, keys %$state};

  return E($state, 'EXCEPTION: maximum traversal depth (%d) exceeded', $self->max_traversal_depth)
    if $state->{depth}++ > $self->max_traversal_depth;

  push $state->{subschemas}->@*, $state->{traversed_schema_path}.$state->{schema_path};

  my $schema_type = get_type($schema);
  return 1 if $schema_type eq 'boolean';

  return E($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  return 1 if not keys %$schema;

  my $valid = 1;
  my %unknown_keywords = map +($_ => undef), keys %$schema;

  # we use an index rather than iterating through the lists directly because the lists of
  # vocabularies and keywords can change after we have started. However, only the Core vocabulary
  # and $schema keyword can make this change, and they both come first, therefore a simple index
  # into the list is sufficient.
  ALL_KEYWORDS:
  for (my $vocab_index = 0; $vocab_index < $state->{vocabularies}->@*; $vocab_index++) {
    my $vocabulary = $state->{vocabularies}[$vocab_index];
    my $keyword_list;

    for (my $keyword_index = 0;
        $keyword_index < ($keyword_list //= do {
          use autovivification qw(fetch store);
          $vocabulary_cache->{$state->{spec_version}}{$vocabulary}{traverse} //= [
            map [ $_ => $vocabulary->can('_traverse_keyword_'.($_ =~ s/^\$//r)) ],
              $vocabulary->keywords($state->{spec_version})
          ];
        })->@*;
        $keyword_index++) {
      my ($keyword, $sub) = $keyword_list->[$keyword_index]->@*;
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} =~ /^draft[467]$/;

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;

      my $old_spec_version = $state->{spec_version};
      my $error_count = $state->{errors}->@*;

      if (not $sub->($vocabulary, $schema, $state)) {
        die 'traverse result is false but there are no errors (keyword: '.$keyword.')'
          if $error_count == $state->{errors}->@*;
        $valid = 0;
        next;
      }
      warn 'traverse result is true but there are errors (keyword: '.$keyword.')'
        if $error_count != $state->{errors}->@*;

      # a keyword changed the keyword list for this vocabulary; re-fetch the list before continuing
      undef $keyword_list if $state->{spec_version} ne $old_spec_version;

      if (my $callback = $state->{callbacks}{$keyword}) {
        $error_count = $state->{errors}->@*;

        if (not $callback->($schema, $state)) {
          die 'callback result is false but there are no errors (keyword: '.$keyword.')'
            if $error_count == $state->{errors}->@*;
          $valid = 0;
          next;
        }
        die 'callback result is true but there are errors (keyword: '.$keyword.')'
          if $error_count != $state->{errors}->@*;
      }
    }
  }

  delete $state->{keyword};

  if ($self->strict and keys %unknown_keywords) {
    $valid = E($state, 'unknown keyword%s found: %s', keys %unknown_keywords > 1 ? 's' : '',
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

  abort($state, 'EXCEPTION: maximum evaluation depth (%d) exceeded', $self->max_traversal_depth)
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  # this should never happen, due to checks in traverse
  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  return 1 if not keys %$schema;

  # find all schema locations in effect at this data path + uri combination
  # if any of them are absolute prefix of this schema location, we are in a loop.
  my $canonical_uri = canonical_uri($state);
  my $schema_location = $state->{traversed_schema_path}.$state->{schema_path};
  {
    use autovivification qw(fetch store);
    abort($state, 'EXCEPTION: infinite loop detected (same location evaluated twice)')
      if grep substr($schema_location, 0, length) eq $_,
        keys $state->{seen}{$state->{data_path}}{$canonical_uri}->%*;
    $state->{seen}{$state->{data_path}}{$canonical_uri}{$schema_location}++;
  }

  my $valid = 1;
  my %unknown_keywords = map +($_ => undef), keys %$schema;

  # set aside annotations collected so far; they are not used in the current scope's evaluation
  my $parent_annotations = $state->{annotations};
  $state->{annotations} = [];

  # in order to collect annotations from applicator keywords only when needed, we twiddle the low
  # bit if we see a local unevaluated* keyword, and clear it again as we move on to a new data path.
  # We also set it when _strict_schema_data is set, but only for object data instances.
  $state->{collect_annotations} |=
    0+(exists $schema->{unevaluatedItems} || exists $schema->{unevaluatedProperties}
      || !!$state->{seen_data_properties} && (my $is_object_data = is_plain_hashref($data)));

  # in order to collect annotations for unevaluated* keywords, we sometimes need to ignore the
  # suggestion to short_circuit evaluation at this scope (but lower scopes are still fine)
  $state->{short_circuit} = ($state->{short_circuit} || delete($state->{short_circuit_suggested}))
    && !exists($schema->{unevaluatedItems}) && !exists($schema->{unevaluatedProperties});

  # we use an index rather than iterating through the lists directly because the lists of
  # vocabularies and keywords can change after we have started. However, only the Core vocabulary
  # and $schema keyword can make this change, and they both come first, therefore a simple index
  # into the list is sufficient.

  ALL_KEYWORDS:
  for (my $vocab_index = 0; $vocab_index < $state->{vocabularies}->@*; $vocab_index++) {
    my $vocabulary = $state->{vocabularies}[$vocab_index];
    my $keyword_list;

    for (my $keyword_index = 0;
        $keyword_index < ($keyword_list //= do {
          use autovivification qw(fetch store);
          $vocabulary_cache->{$state->{spec_version}}{$vocabulary}{evaluate} //= [
            map [ $_ => $vocabulary->can('_eval_keyword_'.($_ =~ s/^\$//r)) ],
              $vocabulary->keywords($state->{spec_version})
          ];
        })->@*;
        $keyword_index++) {
      my ($keyword, $sub) = $keyword_list->[$keyword_index]->@*;
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} =~ /^draft[467]$/;

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;

      if ($sub) {
        my $old_spec_version = $state->{spec_version};
        my $error_count = $state->{errors}->@*;

        try {
          if (not $sub->($vocabulary, $data, $schema, $state)) {
            warn 'evaluation result is false but there are no errors (keyword: '.$keyword.')'
              if $error_count == $state->{errors}->@*;
            $valid = 0;

            last ALL_KEYWORDS if $state->{short_circuit};
            next;
          }

          warn 'evaluation result is true but there are errors (keyword: '.$keyword.')'
            if $error_count != $state->{errors}->@*;
        }
        catch ($e) {
          die $e if $e->$_isa('JSON::Schema::Modern::Error');
          abort($state, 'EXCEPTION: '.$e);
        }

        # a keyword changed the keyword list for this vocabulary; re-fetch the list before continuing
        undef $keyword_list if $state->{spec_version} ne $old_spec_version;
      }

      if (my $callback = ($state->{callbacks}//{})->{$keyword}) {
        my $error_count = $state->{errors}->@*;

        if (not $callback->($data, $schema, $state)) {
          warn 'callback result is false but there are no errors (keyword: '.$keyword.')'
            if $error_count == $state->{errors}->@*;
          $valid = 0;

          last ALL_KEYWORDS if $state->{short_circuit};
          next;
        }
        warn 'callback result is true but there are errors (keyword: '.$keyword.')'
          if $error_count != $state->{errors}->@*;
      }
    }
  }

  delete $state->{keyword};

  if ($state->{strict} and keys %unknown_keywords) {
    abort($state, 'unknown keyword%s found: %s', keys %unknown_keywords > 1 ? 's' : '',
      join(', ', sort keys %unknown_keywords));
  }

  # Note: we can remove all of this entirely and just rely on strict mode when we (eventually!) remove
  # the traverse phase and replace with evaluate-against-metaschema.
  if ($state->{seen_data_properties} and $is_object_data) {
    # record the locations of all local properties
    $state->{seen_data_properties}{jsonp($state->{data_path}, $_)} |= 0 foreach keys %$data;

    my @evaluated_properties = map {
      my $keyword = $_->{keyword};
      (grep $keyword eq $_, qw(properties additionalProperties patternProperties unevaluatedProperties))
        ? $_->{annotation}->@* : ();
    } local_annotations($state);

    # tick off properties that were recognized by this subschema
    $state->{seen_data_properties}{jsonp($state->{data_path}, $_)} |= 1 foreach @evaluated_properties;
  }

  if ($valid and $state->{collect_annotations} and $state->{spec_version} !~ /^draft(?:7|2019-09)$/) {
    annotate_self(+{ %$state, keyword => $_, _unknown => 1 }, $schema)
      foreach sort keys %unknown_keywords;
  }

  # only keep new annotations if schema is valid
  push $parent_annotations->@*, $state->{annotations}->@* if $valid;

  return $valid;
}

my $path_type = Str->where('m{^(?:/|$)}');  # JSON pointer relative to the document root
has _resource_index => (
  is => 'bare',
  isa => Map[my $resource_key_type = Str->where('!/#/'), my $resource_type = Dict[
      # may not be stringwise-equal to the top level key
      canonical_uri => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
      path => $path_type,
      specification_version => my $spec_version_type = Enum(SPECIFICATION_VERSIONS_SUPPORTED),
      document => InstanceOf['JSON::Schema::Modern::Document'],
      # the vocabularies used when evaluating instance data against schema
      vocabularies => ArrayRef[my $vocabulary_class_type = ClassName->where(q{$_->DOES('JSON::Schema::Modern::Vocabulary')})],
      anchors => Optional[HashRef[Dict[
        canonical_uri => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment or substr($_->fragment, 0, 1) eq '/'}),
        path => $path_type,
      ]]],
      configs => HashRef,
      Slurpy[HashRef[Undef]],  # no other fields allowed
    ]],
);

sub _get_resource { ($_[0]->{_resource_index}//{})->{$_[1]} }

# does not check for duplicate entries, or for malformed uris
sub _add_resources_unsafe {
  use autovivification 'store';
  $_[0]->{_resource_index}{$resource_key_type->($_->[0])} = $resource_type->($_->[1])
    foreach pairs @_[1..$#_];
}
sub _resource_index { ($_[0]->{_resource_index}//{})->%* }
sub _canonical_resources { values(($_[0]->{_resource_index}//{})->%*) }
sub _resource_pairs { pairs(($_[0]->{_resource_index}//{})->%*) }

sub _add_resource ($self, @kvs) {
  foreach my $pair (sort { $a->[0] cmp $b->[0] } pairs @kvs) {
    my ($key, $value) = @$pair;

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

    use autovivification 'store';
    $self->{_resource_index}{$resource_key_type->($key)} = $resource_type->($value);
  }
}

# $vocabulary uri (not its $id!) => [ spec_version, class ]
has _vocabulary_classes => (
  is => 'bare',
  isa => HashRef[
    my $vocabulary_type = Tuple[
      $spec_version_type,
      $vocabulary_class_type,
    ]
  ],
  reader => '__vocabulary_classes',
  lazy => 1,
  default => sub {
    +{
      map { my $class = $_; pairmap { $a => [ $b, $class ] } $class->vocabulary }
        map load_module('JSON::Schema::Modern::Vocabulary::'.$_),
          qw(Core Applicator Validation FormatAssertion FormatAnnotation Content MetaData Unevaluated)
    }
  },
);

sub _get_vocabulary_class { $_[0]->__vocabulary_classes->{$_[1]} }

sub add_vocabulary ($self, $classname) {
  return if grep $_->[1] eq $classname, values $self->__vocabulary_classes->%*;

  $vocabulary_class_type->(load_module($classname));

  # uri => version, uri => version
  foreach my $pair (pairs $classname->vocabulary) {
    my ($uri_string, $spec_version) = @$pair;
    Str->where(q{my $uri = Mojo::URL->new($_); $uri->is_abs && !defined $uri->fragment})->($uri_string);
    $spec_version_type->($spec_version);
    $self->{_vocabulary_classes}{$uri_string} = $vocabulary_type->([ $spec_version, $classname ]);
  }
}

# $schema uri => [ spec_version, [ vocab classes, in evaluation order ] ].
has _metaschema_vocabulary_classes => (
  is => 'bare',
  isa => HashRef[
    my $mvc_type = Tuple[
      $spec_version_type,
      ArrayRef[$vocabulary_class_type],
    ]
  ],
  reader => '__metaschema_vocabulary_classes',
  lazy => 1,
  default => sub {
    my @modules = map load_module('JSON::Schema::Modern::Vocabulary::'.$_),
      qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated);
    +{
      'https://json-schema.org/draft/2020-12/schema' => [ 'draft2020-12', [ @modules ] ],
      do { pop @modules; () },  # remove Unevaluated
      'https://json-schema.org/draft/2019-09/schema' => [ 'draft2019-09', [ @modules ] ],
      'http://json-schema.org/draft-07/schema' => [ 'draft7', [ @modules ] ],
      do { splice @modules, 4, 1; () }, # remove Content
      'http://json-schema.org/draft-06/schema' => [ 'draft6', \@modules ],
      'http://json-schema.org/draft-04/schema' => [ 'draft4', \@modules ],
    },
  },
);

sub _get_metaschema_vocabulary_classes { $_[0]->__metaschema_vocabulary_classes->{$_[1] =~ s/#$//r} }
sub _set_metaschema_vocabulary_classes { $_[0]->__metaschema_vocabulary_classes->{$_[1] =~ s/#$//r} = $mvc_type->($_[2]) }
sub __all_metaschema_vocabulary_classes { values $_[0]->__metaschema_vocabulary_classes->%* }

# retrieves metaschema info either from cache or by parsing the schema for vocabularies
# throws a JSON::Schema::Modern::Result on error
sub _get_metaschema_info ($self, $metaschema_uri, $for_canonical_uri) {
  # check the cache. specification metaschemas are already populated.
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
          depth => $e->depth,
          mode => 'traverse',
          keyword => $e->keyword eq '$schema' ? '' : $e->keyword,
          instance_location => $e->instance_location,
          keyword_location => ($for_canonical_uri->fragment//'').($e->keyword_location =~ s{^/\$schema\b}{}r),
          length $absolute_location ? ( absolute_keyword_location => $absolute_location ) : (),
          error => $e->error,
        )
      }
      $state->{errors}->@* ],
    exception => 1,
  ) if $state->{errors}->@*;

  return ($state->{spec_version}, $state->{vocabularies});
}

# translate vocabulary URIs into classes, caching the results (if any)
sub _fetch_vocabulary_data ($self, $state, $schema_info) {
  if (not exists $schema_info->{schema}{'$vocabulary'}) {
    # "If "$vocabulary" is absent, an implementation MAY determine behavior based on the meta-schema
    # if it is recognized from the URI value of the referring schema's "$schema" keyword."
    my $metaschema_uri = $self->METASCHEMA_URIS->{$schema_info->{specification_version}};
    return $self->_get_metaschema_vocabulary_classes($metaschema_uri)->@*;
  }

  my $valid = 1;
  $valid = E($state, '$vocabulary can only appear at the document root') if length $schema_info->{document_path};
  $valid = E($state, 'metaschemas must have an $id') if not exists $schema_info->{schema}{'$id'};

  return (undef, []) if not $valid;

  my @vocabulary_classes;

  foreach my $uri (sort keys $schema_info->{schema}{'$vocabulary'}->%*) {
    my $class_info = $self->_get_vocabulary_class($uri);
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

  return ($schema_info->{specification_version}, $valid ? \@vocabulary_classes : []);
}

# used for determining a default '$schema' keyword where there is none
use constant METASCHEMA_URIS => {
  'draft2020-12' => 'https://json-schema.org/draft/2020-12/schema',
  'draft2019-09' => 'https://json-schema.org/draft/2019-09/schema',
  'draft7' => 'http://json-schema.org/draft-07/schema#',
  'draft6' => 'http://json-schema.org/draft-06/schema#',
  'draft4' => 'http://json-schema.org/draft-04/schema#',
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
  'http://json-schema.org/draft-06/schema' => 'draft6/schema.json',
  'http://json-schema.org/draft-04/schema' => 'draft4/schema.json',
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

# returns information necessary to use a schema found at a particular URI or uri-reference:
# - schema: a schema (which may not be at a document root)
# - canonical_uri: the canonical uri for that schema,
# - document: the JSON::Schema::Modern::Document object that holds that schema
# - document_path: the path relative to the document root for this schema
# - specification_version: the specification version that applies to this schema
# - vocabularies: the vocabularies to use when considering schema keywords
# - configs: the config overrides to set when considering schema keywords
# creates a Document and adds it to the resource index, if not already present.
sub _fetch_from_uri ($self, $uri_reference) {
  $uri_reference = Mojo::URL->new($uri_reference) if not is_ref($uri_reference);

  my $resource = $self->_get_or_load_resource($uri_reference->clone->fragment(undef));
  return if not $resource;

  my $fragment = $uri_reference->fragment;
  if (not length($fragment) or $fragment =~ m{^/}) {
    my $subschema = $resource->{document}->get(my $document_path = $resource->{path}.($fragment//''));
    return if not defined $subschema;

    my $closest_resource;
    if (not length $fragment) {
      $closest_resource = [ undef, $resource ];
    }
    else {
      # determine the canonical uri by finding the closest schema resource
      my $doc_addr = refaddr($resource->{document});
      $closest_resource = first { !length($_->[1]{path})       # document root
          || length($document_path)
            && $document_path =~ m{^\Q$_->[1]{path}\E(?:/|\z)} }  # path is above present location
        sort { length($b->[1]{path}) <=> length($a->[1]{path}) }  # sort by length, descending
        grep { refaddr($_->[1]{document}) == $doc_addr }          # in same document
        $self->_resource_pairs;
    }

    my $canonical_uri = $closest_resource->[1]{canonical_uri}->clone
      ->fragment(substr($document_path, length($closest_resource->[1]{path})));
    $canonical_uri->fragment(undef) if not length($canonical_uri->fragment);

    return {
      schema => $subschema,
      canonical_uri => $canonical_uri,
      document_path => $document_path,
      $closest_resource->[1]->%{qw(document specification_version vocabularies configs)}, # reference, not copy
    };
  }
  else {  # we are following a URI with a plain-name fragment
    return if not my $subresource = ($resource->{anchors}//{})->{$fragment};
    return {
      schema => $resource->{document}->get($subresource->{path}),
      canonical_uri => $subresource->{canonical_uri}->clone, # this is *not* the anchor-containing URI
      document_path => $subresource->{path},
      $resource->%{qw(document specification_version vocabularies configs)}, # reference, not copy
    };
  }
}

# Mojo::JSON::JSON_XS is false when the environment variable $MOJO_NO_JSON_XS is set
# and also checks if Cpanel::JSON::XS is installed.
# Mojo::JSON falls back to its own pure-perl encoder/decoder but does not support all the options
# that we require here.
use constant _JSON_BACKEND => Mojo::JSON::JSON_XS ? 'Cpanel::JSON::XS' : 'JSON::PP';

# used for internal encoding as well (when caching serialized schemas)
has _json_decoder => (
  is => 'ro',
  isa => HasMethods[qw(encode decode)],
  lazy => 1,
  default => sub { _JSON_BACKEND->new->allow_nonref(1)->canonical(1)->utf8(1)->allow_bignum(1)->convert_blessed(1) },
);

# since media types are case-insensitive, all type names must be casefolded on insertion.
has _media_type => (
  is => 'bare',
  isa => my $media_type_type = Map[Str->where(q{$_ eq CORE::fc($_)}), CodeRef],
  reader => '__media_type',
  lazy => 1,
  default => sub ($self) {
    my $_json_media_type = sub ($content_ref) {
      # utf-8 decoding is always done, as per the JSON spec.
      # other charsets are not supported: see RFC8259 §11
      \ _JSON_BACKEND->new->allow_nonref(1)->utf8(1)->decode($content_ref->$*);
    };
    +{
      (map +($_ => $_json_media_type),
        qw(application/json application/schema+json application/schema-instance+json)),
      (map +($_ => sub ($content_ref) { $content_ref }),
        qw(text/* application/octet-stream)),
      'application/x-www-form-urlencoded' => sub ($content_ref) {
        \ Mojo::Parameters->new->charset('UTF-8')->parse($content_ref->$*)->to_hash;
      },
      'application/x-ndjson' => sub ($content_ref) {
        my $decoder = _JSON_BACKEND->new->allow_nonref(1)->utf8(1);
        my $line = 0; # line numbers start at 1
        \[ map {
            do {
              try { ++$line; $decoder->decode($_) }
              catch ($e) { die 'parse error at line '.$line.': '.$e }
            }
          }
          split(/\r?\n/, $content_ref->$*)
        ];
      },
    };
  },
);

sub add_media_type { $media_type_type->({ @_[1..2] }); $_[0]->__media_type->{$_[1]} = $_[2]; }

# get_media_type('TExT/bloop') will fall through to matching an entry for 'text/*' or '*/*'
sub get_media_type ($self, $type) {
  my $types = $self->__media_type;
  my $mt = $types->{fc $type};
  return $mt if $mt;

  return $types->{(first { m{([^/]+)/\*$} && fc($type) =~ m{^\Q$1\E/[^/]+$} } keys %$types) // '*/*'};
};

has _encoding => (
  is => 'bare',
  isa => HashRef[CodeRef],
  reader => '__encoding',
  lazy => 1,
  default => sub ($self) {
    +{
      identity => sub ($content_ref) { $content_ref },
      base64 => sub ($content_ref) {
        die "invalid characters\n"
          if $content_ref->$* =~ m{[^A-Za-z0-9+/=]} or $content_ref->$* =~ m{=(?=[^=])};
        require MIME::Base64; \ MIME::Base64::decode_base64($content_ref->$*);
      },
      base64url => sub ($content_ref) {
        die "invalid characters\n"
          if $content_ref->$* =~ m{[^A-Za-z0-9=_-]} or $content_ref->$* =~ m{=(?=[^=])};
        require MIME::Base64; \ MIME::Base64::decode_base64url($content_ref->$*);
      },
    };
  },
);

sub get_encoding { $_[0]->__encoding->{$_[1]} }
sub add_encoding { $_[0]->__encoding->{$_[1]} = CodeRef->($_[2]) }

# callback hook for Sereal::Encoder
sub FREEZE ($self, $serializer) {
  my $data = +{ %$self };
  # Cpanel::JSON::XS doesn't serialize: https://github.com/Sereal/Sereal/issues/266
  # coderefs can't serialize cleanly and must be re-added by the user.
  delete $data->@{qw(_json_decoder _format_validations _media_type _encoding)};
  return $data;
}

# callback hook for Sereal::Decoder
sub THAW ($class, $serializer, $data) {
  my $self = bless($data, $class);

  # load all vocabulary classes, both those used by loaded schemas, as well as all the core modules
  load_module($_)
    foreach uniq(
      (map $_->{vocabularies}->@*, $self->_canonical_resources),
      (map $_->[1], values $self->__vocabulary_classes->%*));

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
    specification_version => 'draft2020-12',
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

Indicates which version of the JSON Schema specification is used during evaluation. This value is
overridden by the value determined from the C<$schema> keyword in the schema used in evaluation
(when present), or defaults to the latest version (currently C<draft2020-12>).

The use of the C<$schema> keyword in your schema is I<HIGHLY> encouraged to ensure continued correct
operation of your schema. The current default value will not stay the same over time.

May be one of:

=for :list
* L<C<draft2020-12> or C<2020-12>|https://json-schema.org/specification-links.html#2020-12>,
  corresponding to metaschema C<https://json-schema.org/draft/2020-12/schema>
* L<C<draft2019-09> or C<2019-09>|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>,
  corresponding to metaschema C<https://json-schema.org/draft/2019-09/schema>
* L<C<draft7> or C<7>|https://json-schema.org/specification-links.html#draft-7>,
  corresponding to metaschema C<http://json-schema.org/draft-07/schema#>
* L<C<draft6> or C<6>|https://json-schema.org/specification-links.html#draft-6>,
  corresponding to metaschema C<http://json-schema.org/draft-06/schema#>
* L<C<draft4> or C<4>|https://json-schema.org/specification-links.html#draft-4>,
  corresponding to metaschema C<http://json-schema.org/draft-04/schema#>

=head2 output_format

One of: C<flag>, C<basic>, C<strict_basic>, C<terse>. Defaults to C<basic>.
C<strict_basic> can only be used with C<specification_version = draft2019-09>.
Passed to L<JSON::Schema::Modern::Result/output_format>.

=head2 short_circuit

When true, evaluation will return early in any execution path as soon as the outcome can be
determined, rather than continuing to find all errors or annotations.
This option is safe to use in all circumstances, even in the presence of
C<unevaluatedItems> and C<unevaluatedProperties> keywords: the validation result will not change;
only some errors will be omitted from the result.

Defaults to true when C<output_format> is C<flag>, and false otherwise.

=head2 max_traversal_depth

The maximum number of levels deep a schema traversal may go, before evaluation is halted. This is to
protect against accidental infinite recursion, such as from two subschemas that each reference each
other, or badly-written schemas that could be optimized. Defaults to 50.

=head2 validate_formats

When true, the C<format> keyword will be treated as an assertion, not merely an annotation. Defaults
to true when specification_version is draft4, draft6 or draft7, and false for all other versions, but this may change in the future.

Note that the use of a format that does not have a defined handler will B<not> be interpreted as an
error in this mode; instead, the undefined format will simply be ignored. If you instead want this
to be treated as an evaluation error, you must define a custom schema dialect that uses the
format-assertion vocabulary (available in specification version C<draft2020-12>) and reference it in
your schema with the C<$schema> keyword.

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
then applied to the schema in C<contentSchema> for validation. (Note that treating these keywords as
anything beyond simple annotations is contrary to the specification, therefore this option defaults
to false.)

See L</add_media_type> and L</add_encoding> for adding additional type support.

=for stopwords shhh

Technically only draft4, draft6 and draft7 allow this and drafts 2019-09 and 2020-12 prohibit ever returning the
subschema evaluation results together with their parent schema's results, so shhh. I'm trying to get this
fixed for the next draft.

=head2 collect_annotations

When true, annotations are collected from keywords that produce them, when validation succeeds.
These annotations are available in the returned result (see L<JSON::Schema::Modern::Result>).
Not operational when L</specification_version> is C<draft4>, C<draft6> or C<draft7>.

Defaults to false.

=head2 scalarref_booleans

When true, any value that is expected to be a boolean B<in the instance data> may also be expressed
as the scalar references C<\0> or C<\1> (which are serialized as booleans by JSON backends).

Defaults to false.

=head2 stringy_numbers

When true, any value that is expected to be a number or integer B<in the instance data> may also be
expressed as a string. This applies only to the following keywords:

=for :list
* C<type> (where both C<string> and C<number> (and possibly C<integer>) are considered valid)
* C<const> and C<enum> (where the string C<"1"> will match with C<"const": 1>)
* C<uniqueItems> (where strings and numbers are compared numerically to each other, if either or
  both are numeric)
* C<multipleOf>
* C<maximum>
* C<exclusiveMaximum>
* C<minimum>
* C<exclusiveMinimum>
* C<format> (for formats defined to validate numbers)

This allows you to write a schema like this (which validates a string representing an integer):

  type: string
  pattern: ^[0-9]$
  multipleOf: 4
  minimum: 16
  maximum: 256

Such keywords are only applied if the value looks like a number, and do not generate a failure
otherwise. Values are determined to be numbers via L<perlapi/looks_like_number>.
This option is only intended to be used for evaluating data from sources that can only be strings,
such as the extracted value of an HTTP header or query parameter.

Defaults to false.

=head2 strict

When true, unrecognized keywords are disallowed in schemas (they will cause an immediate abort
in L</traverse> or L</evaluate>).

Defaults to false.

=head1 METHODS

=for Pod::Coverage BUILDARGS FREEZE THAW
CACHED_METASCHEMAS METASCHEMA_URIS SPECIFICATION_VERSIONS_SUPPORTED SPECIFICATION_VERSION_DEFAULT

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema);
  $result = $js->evaluate_json_string($data_as_json_string, $schema, { collect_annotations => 1 });

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://datatracker.ietf.org/doc/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema must be in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* or a URI string indicating the identity of such a schema.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations>, L</scalarref_booleans>,
L</stringy_numbers>, L</strict>, L</validate_formats>, and/or L</validate_content_schemas>
settings for just this evaluation call.

You can also pass use these keys to alter behaviour (these are generally only used by custom validation
applications that contain embedded JSON Schemas):

=for :list
* C<data_path>: adjusts the effective path of the data instance as of the start of evaluation
* C<traversed_schema_path>: adjusts the accumulated path as of the start of evaluation (or last C<$id> or C<$ref>)
* C<initial_schema_uri>: adjusts the recorded absolute keyword location as of the start of evaluation
* C<effective_base_uri>: locations in errors and annotations are resolved against this URI (only
  useful when providing an inline schema that does not declare an absolute base URI for itself)

The return value is a L<JSON::Schema::Modern::Result> object, which can also be used as a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema);
  $result = $js->evaluate($instance_data, $schema, { short_circuit => 0 });

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows: null, boolean, string, number, object, array. (See L</Types> below.)

The schema must be in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* or a URI string indicating the identity of such a schema.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations>, L</scalarref_booleans>,
L</stringy_numbers>, L</strict>, L</validate_formats>, and/or L</validate_content_schemas>
settings for just this evaluation call.

You can also pass use these keys to alter behaviour (these are generally only used by custom validation
applications that contain embedded JSON Schemas):

=for :list
* C<data_path>: adjusts the effective path of the data instance as of the start of evaluation
* C<traversed_schema_path>: adjusts the accumulated path as of the start of evaluation (or last C<$id> or C<$ref>)
* C<effective_base_uri>: locations in errors and annotations are resolved against this URI (only
  useful when providing an inline schema that does not declare an absolute base URI for itself)

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

The return value is a L<JSON::Schema::Modern::Result> object, which can also be used as a boolean.
Callbacks are not compatible with L</short_circuit> mode.

=head2 validate_schema

  $result = $js->validate_schema($schema);
  $result = $js->validate_schema($schema, $config_override);

Evaluates the provided schema as instance data against its metaschema. Accepts C<$schema> and
C<$config_override> parameters in the same form as L</evaluate>.

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
* C<initial_schema_uri>: adjusts the absolute keyword location as of the start of evaluation
* C<metaschema_uri>: use the indicated URI as the metaschema

You can pass a series of callback subs to this method corresponding to keywords, which is useful for
extracting data from within schemas and skipping properties that may look like keywords but actually
are not (for example C<{"const": {"$ref": "this is not actually a $ref"}}>). This feature is highly
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
  $js->add_schema($schema);

Introduces the (unblessed, nested) Perl data structure
representing a JSON Schema to the implementation, registering it under the indicated URI if
provided, and all identifiers found within the document will be resolved against this URI (if
provided) and added as well. C<''> will be used if no other identifier can be found within.

You B<MUST> call C<add_schema> or L</add_document> (below) for any external resources that a schema may reference via C<$ref>
before calling L</evaluate>, other than the standard metaschemas which are loaded from a local cache
as needed.

If you add multiple schemas (either with this method, or implicitly via L</evaluate>) with no root
identifier (either provided explicitly in the method call, or via an C<$id> keyword at the schema
root), all such previous schemas are removed from memory and can no longer be referenced.

If there were errors in the document, will die with these errors;
otherwise returns the L<JSON::Schema::Modern::Document> that contains the added schema.

=head2 add_document

  $js->add_document($uri => $document);
  $js->add_document($document);

Makes the L<JSON::Schema::Modern::Document> (or subclass)
object, representing a JSON Schema, available to the evaluator. All identifiers known to the
document are added to the evaluator's resource index; if the C<$uri> argument is provided, those
identifiers are resolved against C<$uri> as they are added.

C<$uri> itself is also added to the resource index, referencing the root of the document itself.

If you add multiple documents (either with this method, or implicitly via C</add_schema> or L</evaluate>) with no root
identifier (either provided explicitly in the method call, or via an C<$id> keyword at the schema
root), all such previous schemas are removed from memory and can no longer be referenced.

If there were errors in the document, this method will die with these errors;
otherwise it returns the L<JSON::Schema::Modern::Document> object.

=head2 add_format_validation

  $js->add_format_validation(all_lc => sub ($value) { lc($value) eq $value });

=for comment we are the nine Eleven Deniers

or

  $js->add_format_validation(no_nines => { type => 'number', sub => sub ($value) { $value =~ m/^[0-8]+$/ });

  $js->add_format_validation(8bits => { type => 'string', sub => sub ($value) { $value =~ m/^[\x00-\xFF]+$/ });

Adds support for a custom format. If not supplied, the data type(s) that this format applies to
defaults to string; all values of any other type will automatically be deemed to be valid, and will
not be passed to the subref.

Additionally, you can redefine the definition for any core format (see L</Format Validation>), but
the data type(s) supported by that format may not be changed.

Be careful to not mutate the type of the value while checking it -- for example, if it is a string,
do not apply arithmetic operators to it -- or subsequent type checks on this value may fail.

See L<https://spec.openapis.org/registry/format/> for a registry of known and useful formats; for
compatibility reasons, avoid defining a format listed here with different semantics.

=head2 add_vocabulary

  $js->add_vocabulary('My::Custom::Vocabulary::Class');

Makes a custom vocabulary class available to metaschemas that make use of this vocabulary.
as described in the specification at
L<"Meta-Schemas and Vocabularies"|https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.8.1>.

The class must compose the L<JSON::Schema::Modern::Vocabulary> role and implement the
L<vocabulary|JSON::Schema::Modern::Vocabulary/vocabulary> and
L<keywords|JSON::Schema::Modern::Vocabulary/keywords> methods, as well as
C<< _traverse_keyword_<keyword name> >> methods for each keyword. C<< _eval_keyword_<keyword name> >>
methods are optional; when not provided, evaluation will always return a true result.

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
* C<application/json> - see L<RFC 4627|https://datatracker.ietf.org/doc/html/rfc4627>
* C<application/schema+json> - see L<proposed definition|https://json-schema.org/draft/2020-12/json-schema-core.html#name-application-schemajson>
* C<application/schema-instance+json> - see L<proposed definition|https://json-schema.org/draft/2020-12/json-schema-core.html#name-application-schema-instance>
* C<application/octet-stream> - passes strings through unchanged
* C<application/x-www-form-urlencoded>
* C<application/x-ndjson> - see L<https://github.com/ndjson/ndjson-spec>
* C<text/*> - passes strings through unchanged

=head2 get_media_type

Fetches a decoder sub for the indicated media type. Lookups are performed B<without case sensitivity>.

=for stopwords thusly

You can use it thusly:

  $js->add_media_type('application/furble' => sub { ... }); # as above
  my $decoder = $self->get_media_type('application/furble') or die 'cannot find media type decoder';
  my $content_ref = $decoder->(\$content_string);

=head2 add_encoding

  $js->add_encoding('bloop' => sub ($content_ref) {
    return \ ...;  # data representing the deserialized content for Content-Transfer-Encoding: bloop
  });

Takes an encoding name and a subref which takes a single scalar reference, which is expected to be
a reference to a string, which SHOULD be a 7-bit or 8-bit string. Result values MUST be a scalar-reference
to a string (which is then dereferenced for the C<contentMediaType> keyword).

=for stopwords natively

Encodings handled natively are:

=for :list
* C<identity> - passes strings through unchanged
* C<base64> - see L<RFC 4648 §4|https://datatracker.ietf.org/doc/html/rfc4648#section-4>
* C<base64url> - see L<RFC 4648 §5|https://datatracker.ietf.org/doc/html/rfc4648#section-5>

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

Fetches the Perl data structure represented by the indicated identifier (uri or
uri-reference). When called in list context, the canonical URI of that location is also returned, as
a L<Mojo::URL>. Returns C<undef> if the schema with that URI has not been loaded (or cached).

Note that the data so returned may not be a JSON Schema, if the document encapsulating this location
is a subclass of L<JSON::Schema::Modern::Document> (for example
L<JSON::Schema::Modern::Document::OpenAPI>, which contains addressable locations of various semantic
types).

=head2 get_document

  my $document = $js->get_document($uri_reference);

Fetches the L<JSON::Schema::Modern::Document> object (or subclass) that contains the provided
identifier (uri or uri-reference). C<undef> if the schema with that URI has not been loaded (or
cached).

=head1 CACHING

=for stopwords preforking

Very large documents, particularly those used by L<OpenAPI::Modern>, may take a noticeable time to be
loaded and parsed. You can reduce the impact to your preforking application by loading all necessary
documents at startup, and impact can be further reduced by saving objects to cache and then
reloading them (perhaps by using a timestamp or checksum to determine if a fresh reload is needed).

Custom L<format validations|/add_format_validation>, L<media types|/add_media_type> or
L<encodings|/add_encoding> are not serialized, as they are represented by subroutine references, and
will need to be manually added after thawing.

  sub get_evaluator (...) {
    my $serialized_file = Path::Tiny::path($filename);
    my $schema_file = Path::Tiny::path($schema_filename);
    my $js;
    if ($serialized_file->stat->mtime < $schema_file->stat->mtime)) {
      $js = JSON::Schema::Modern->new;
      $js->add_schema(decode_json($schema_file->slurp_raw));  # your application schema
      my $frozen = Sereal::Encoder->new({ freeze_callbacks => 1 })->encode($js);
      $serialized_file->spew_raw($frozen);
    }
    else {
      my $frozen = $serialized_file->slurp_raw;
      $js = Sereal::Decoder->new->decode($frozen);
    }

    # add custom format validations, media types and encodings here
    $js->add_media_type(...);

    return $js;
  }

See also L<OpenAPI::Modern/CACHING>.

=head1 LIMITATIONS

=head2 Types

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value.
This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.
If you are having difficulties, make sure you are using Perl's fastest and most trusted and
reliable JSON decoder, L<Cpanel::JSON::XS>.
Other JSON decoders are known to produce data with incorrect data types,
and data from other sources may also be problematic.

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
validation will always succeed, unless draft2020-12 is in use with the Format-Assertion vocabulary
declared in the metaschema, in which case use of the format will produce an error).

=for :list
* C<date-time> and C<date> require L<Time::Moment>
* C<date-time> also requires <DateTime::Format::RFC3339>
* C<email> and C<idn-email> require L<Email::Address::XS> version 1.04 (or higher)
* C<hostname> and C<idn-hostname> require L<Data::Validate::Domain> version 0.13 (or higher)
* C<idn-hostname> also requires L<Net::IDN::Encode>

=head2 Specification Compliance

This implementation is now fully specification-compliant (for versions
draft4, draft6, draft7, draft2019-09, draft2020-12),
but until version 1.000 is released, it is
still deemed to be missing some optional but quite useful features, such as:

=for stopwords Mojolicious

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

(In particular, see vulnerability
L<perl5363delta/CVE-2023-47038-Write-past-buffer-end-via-illegal-user-defined-Unicode-property>,
which was fixed in Perl releases 5.34.3, 5.36.3 and 5.38.1.)

=head1 SEE ALSO

=for stopwords OpenAPI

=for :list
* L<json-schema-eval>
* L<https://json-schema.org>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://datatracker.ietf.org/doc/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://datatracker.ietf.org/doc/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>: contains the official JSON Schema test suite
* L<JSON::Schema::Tiny>: a more stripped-down implementation of the specification, with fewer
  dependencies and faster evaluation
* L<https://json-schema.org/draft/2020-12/release-notes.html>
* L<https://json-schema.org/draft/2019-09/release-notes.html>
* L<https://json-schema.org/draft-07/json-schema-release-notes.html>
* L<https://json-schema.org/draft-06#draft-06-release-notes>
* L<https://json-schema.org/draft-04/draft-zyp-json-schema-04>
* L<Understanding JSON Schema|https://json-schema.org/understanding-json-schema>: tutorial-focused documentation
* L<OpenAPI::Modern>: a parser and evaluator for OpenAPI v3.1 documents
* L<Mojolicious::Plugin::OpenAPI::Modern>: a Mojolicious plugin providing OpenAPI functionality
* L<Test::Mojo::Role::OpenAPI::Modern>: test your Mojolicious application's OpenAPI compliance

=head1 AVAILABILITY

This distribution and executable is available on modern Debian versions (via C<apt-get>) as the
C<libjson-schema-modern-perl> package.

=cut
