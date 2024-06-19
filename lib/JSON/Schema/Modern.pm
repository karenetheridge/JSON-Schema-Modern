use strict;
use warnings;
package JSON::Schema::Modern;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema using a JSON Schema
# KEYWORDS: JSON Schema validator data validation structure specification

our $VERSION = '0.586';

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
use Scalar::Util 'refaddr';
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use Module::Runtime qw(use_module require_module);
use MooX::TypeTiny 0.002002;
use Types::Standard 1.016003 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef Optional Slurpy ArrayRef Undef ClassName Tuple Map);
use Digest::MD5 'md5';
use Feature::Compat::Try;
use JSON::Schema::Modern::Error;
use JSON::Schema::Modern::Result;
use JSON::Schema::Modern::Document;
use JSON::Schema::Modern::Utilities qw(get_type canonical_uri E abort annotate_self jsonp is_type assert_uri);
use namespace::clean;

our @CARP_NOT = qw(
  JSON::Schema::Modern::Document
  JSON::Schema::Modern::Vocabulary
  JSON::Schema::Modern::Vocabulary::Applicator
  JSON::Schema::Modern::Document::OpenAPI
  OpenAPI::Modern
);

use constant SPECIFICATION_VERSION_DEFAULT => 'draft2020-12';
use constant SPECIFICATION_VERSIONS_SUPPORTED => [qw(draft7 draft2019-09 draft2020-12)];

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
  default => sub { ($_[0]->specification_version//SPECIFICATION_VERSION_DEFAULT) eq 'draft7' ? 1 : 0 },
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
  lazy => 1,
  default => sub { {} },
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

  croak 'collect_annotations cannot be used with specification_version draft7'
    if $args->{collect_annotations} and ($args->{specification_version}//'') eq 'draft7';

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
    );
    die $result;
  }

  if (not grep refaddr($_->{document}) == refaddr($document), $self->_canonical_resources) {
    my $schema_checksum = $document->_checksum
      // $document->_checksum(md5($self->_json_decoder->encode($document->schema)));

    if (my $existing_doc = first {
          my $existing_checksum = $_->_checksum
            // $_->_checksum(md5($self->_json_decoder->encode($_->schema)));
          $existing_checksum eq $schema_checksum
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
          depth => 0,
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
    initial_schema_uri => $initial_uri,     # the canonical URI as of the start of this method or last $id
    traversed_schema_path => $initial_path, # the accumulated traversal path as of the start or last $id
    schema_path => '',                      # the rest of the path, since the start of this method or last $id
    effective_base_uri => Mojo::URL->new(''),
    errors => [],
    identifiers => [],
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
    traversed_schema_path => $initial_path, # the accumulated path as of the start of evaluation or last $id or $ref
    initial_schema_uri => Mojo::URL->new,   # the canonical URI as of the start of evaluation or last $id or $ref
    schema_path => '',                  # the rest of the path, since the start of evaluation or last $id or $ref
    effective_base_uri => $effective_base_uri, # resolve locations against this for errors and annotations
    errors => [],
    depth => 0,
    configs => {},
  };

  exists $config_override->{$_} and die $_.' not supported as a config override'
    foreach qw(output_format specification_version);

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
    abort($state, 'EXCEPTION: %s is not a schema', $schema_reference)
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
      } qw(validate_formats validate_content_schemas short_circuit collect_annotations scalarref_booleans stringy_numbers strict)),
    };

    # we're going to set collect_annotations during evaluation when we see an unevaluated* keyword,
    # but after we pass to a new data scope we'll clear it again.. unless we've got the config set
    # globally for the entire evaluation, so we store that value in a high bit.
    $state->{collect_annotations} = ($state->{collect_annotations}//0) << 8;

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

  return $self->evaluate($schema, $metaschema_uri, $config_override);
}

sub get ($self, $uri_reference) {
  my $schema_info = $self->_fetch_from_uri($uri_reference);
  return if not $schema_info;
  my $subschema = is_ref($schema_info->{schema}) ? dclone($schema_info->{schema}) : $schema_info->{schema};
  return wantarray ? ($subschema, $schema_info->{canonical_uri}) : $subschema;
}

sub get_document ($self, $uri_reference) {
  my $schema_info = $self->_fetch_from_uri($uri_reference);
  return if not $schema_info;
  return $schema_info->{document};
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

  # First, we must determine the dialect to use. This is given to us in metaschema_uri
  # and can also be indicated with the '$schema' keyword. We need to do this now, before iterating
  # over vocabulary classes and keywords, because these can change depending on the dialect.
  if (exists $schema->{'$schema'}) {
    return if not $self->_parse_keyword_schema($state, $schema->{'$schema'});

    # This is a bit of a chicken-and-egg situation. If we start off at draft2020-12, then all
    # keywords are valid, so we inspect and process the $schema keyword; this switches us to draft7
    # but now only the $ref keyword is respected and everything else should be ignored, so the
    # $schema keyword never happened, so now we're back to draft2020-12 again, and...?!
    # The only winning move is not to play.
    return E($state, '$schema and $ref cannot be used together in older drafts')
      if exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';
  }

  ALL_KEYWORDS:
  foreach my $vocabulary ($state->{vocabularies}->@*) {
    # [ [ $keyword => $subref ], [ ... ] ]
    my $keyword_list = do {
      use autovivification qw(fetch store);
      $vocabulary_cache->{$state->{spec_version}}{$vocabulary}{traverse} //= [
        map [ $_ => $vocabulary->can('_traverse_keyword_'.($_ =~ s/^\$//r)) ],
          $vocabulary->keywords($state->{spec_version})
      ];
    };

    foreach my $keyword_tuple ($keyword_list->@*) {
      my ($keyword, $sub) = $keyword_tuple->@*;
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;

      if (not $sub->($vocabulary, $schema, $state)) {
        die 'traverse result is false but there are no errors (keyword: '.$keyword.')' if not $state->{errors}->@*;
        $valid = 0;
        next;
      }

      if (my $callback = $state->{callbacks}{$keyword}) {
        if (not $callback->($schema, $state)) {
          die 'callback result is false but there are no errors (keyword: '.$keyword.')' if not $state->{errors}->@*;
          $valid = 0;
          next;
        }
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

  abort($state, 'EXCEPTION: maximum evaluation depth (%d) exceeded', $self->max_traversal_depth)
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  # this should never happen, due to checks in traverse
  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  return 1 if not keys %$schema;

  # find all schema locations in effect at this data path + canonical_uri combination
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
  $state->{collect_annotations} |= 0+(exists $schema->{unevaluatedItems} || exists $schema->{unevaluatedProperties});

  # in order to collect annotations for unevaluated* keywords, we sometimes need to ignore the
  # suggestion to short_circuit evaluation at this scope (but lower scopes are still fine)
  $state->{short_circuit} = ($state->{short_circuit} || delete($state->{short_circuit_suggested}))
    && !exists($schema->{unevaluatedItems}) && !exists($schema->{unevaluatedProperties});

  ALL_KEYWORDS:
  foreach my $vocabulary ($state->{vocabularies}->@*) {
    # [ [ $keyword => $subref|undef ], [ ... ] ]
    my $keyword_list = do {
      use autovivification qw(fetch store);
      $vocabulary_cache->{$state->{spec_version}}{$vocabulary}{evaluate} //= [
        map [ $_ => $vocabulary->can('_eval_keyword_'.($_ =~ s/^\$//r)) ],
          $vocabulary->keywords($state->{spec_version})
      ];
    };

    foreach my $keyword_tuple ($keyword_list->@*) {
      my ($keyword, $sub) = $keyword_tuple->@*;
      next if not exists $schema->{$keyword};

      # keywords adjacent to $ref are not evaluated before draft2019-09
      next if $keyword ne '$ref' and exists $schema->{'$ref'} and $state->{spec_version} eq 'draft7';

      delete $unknown_keywords{$keyword};
      $state->{keyword} = $keyword;

      if ($sub) {
        my $error_count = $state->{errors}->@*;

        if (not $sub->($vocabulary, $data, $schema, $state)) {
          warn 'evaluation result is false but there are no errors (keyword: '.$keyword.')'
            if $error_count == $state->{errors}->@*;
          $valid = 0;

          last ALL_KEYWORDS if $state->{short_circuit};
          next;
        }
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
      }
    }
  }

  delete $state->{keyword};

  if ($state->{strict} and keys %unknown_keywords) {
    abort($state, 'unknown keyword%s found: %s', keys %unknown_keywords > 1 ? 's' : '',
      join(', ', sort keys %unknown_keywords));
  }

  if ($valid and $state->{collect_annotations} and $state->{spec_version} !~ qr/^draft(7|2019-09)$/) {
    annotate_self(+{ %$state, keyword => $_, _unknown => 1 }, $schema)
      foreach sort keys %unknown_keywords;
  }

  # only keep new annotations if schema is valid
  push $parent_annotations->@*, $state->{annotations}->@* if $valid;

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
      Slurpy[HashRef[Undef]],  # no other fields allowed
    ]],
  lazy => 1,
  default => sub { {} },
);

sub _get_resource { ($_[0]->{_resource_index}//{})->{$_[1]} }
sub _add_resources {
  use autovivification 'store';
  $_[0]->{_resource_index}{$_->[0]} = $resource_type->($_->[1]) foreach pairs @_[1..$#_];
}
sub _add_resources_unsafe {
  use autovivification 'store';
  $_[0]->{_resource_index}{$_->[0]} = $resource_type->($_->[1]) foreach pairs @_[1..$#_];
}
sub _resource_index { $_[0]->{_resource_index}->%* }
sub _canonical_resources { values(($_[0]->{_resource_index}//{})->%*) }

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
        map use_module('JSON::Schema::Modern::Vocabulary::'.$_),
          qw(Core Applicator Validation FormatAssertion FormatAnnotation Content MetaData Unevaluated)
    }
  },
);

sub _get_vocabulary_class { $_[0]->__vocabulary_classes->{$_[1]} }

sub add_vocabulary ($self, $classname) {
  return if grep $_->[1] eq $classname, values $self->__vocabulary_classes->%*;

  $vocabulary_class_type->(use_module($classname));

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
    my @modules = map use_module('JSON::Schema::Modern::Vocabulary::'.$_),
      qw(Core Validation FormatAnnotation Applicator Content MetaData Unevaluated);
    +{
      'https://json-schema.org/draft/2020-12/schema' => [ 'draft2020-12', [ @modules ] ],
      do { pop @modules; () },
      'https://json-schema.org/draft/2019-09/schema' => [ 'draft2019-09', \@modules ],
      'http://json-schema.org/draft-07/schema' => [ 'draft7', \@modules ],
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

# we can't do this work in the context of looping over vocabularies and keywords, because this
# keyword changes which vocabularies and keywords we're going to use. Additionally we may need to
# fetch and parse the referenced schema to discover what vocabularies it defines.
sub _parse_keyword_schema ($self, $state, $metaschema_uri) {
  $state->{keyword} = '$schema';

  return E($state, '$schema value is not a string') if not is_type('string', $metaschema_uri);
  return if not assert_uri($state, { '$schema' => $metaschema_uri });

  my ($spec_version, $vocabularies);

  if (my $metaschema_info = $self->_get_metaschema_vocabulary_classes($metaschema_uri)) {
    ($spec_version, $vocabularies) = @$metaschema_info;
  }
  else {
    my $schema_info = $self->_fetch_from_uri($metaschema_uri);
    return E($state, 'EXCEPTION: unable to find resource %s', $metaschema_uri) if not $schema_info;
    # this cannot happen unless there are other entity types in the index
    return E($state, 'EXCEPTION: bad reference to $schema %s: not a schema', $schema_info->{canonical_uri})
      if $schema_info->{document}->get_entity_at_location($schema_info->{document_path}) ne 'schema';

    if (not is_plain_hashref($schema_info->{schema})) {
      ()= E($state, 'metaschemas must be objects');
    }
    else {
      ($spec_version, $vocabularies) = $self->_fetch_vocabulary_data({ %$state,
          keyword => '$vocabulary', initial_schema_uri => Mojo::URL->new($metaschema_uri),
          traversed_schema_path => jsonp($state->{schema_path}, '$schema'),
        }, $schema_info);
    }
  }

  return E($state, '"%s" is not a valid metaschema', $metaschema_uri)
    if not $vocabularies or not @$vocabularies;

  $state->@{qw(spec_version vocabularies)} = ($spec_version, $vocabularies);
  return 1;
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

  $self->_set_metaschema_vocabulary_classes($schema_info->{canonical_uri},
    [ $schema_info->{specification_version}, \@vocabulary_classes ]) if $valid;

  return ($schema_info->{specification_version}, $valid ? \@vocabulary_classes : []);
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

# returns information necessary to use a schema found at a particular URI or uri-reference:
# - a schema (which may not be at a document root)
# - the canonical uri for that schema,
# - the JSON::Schema::Modern::Document object that holds that schema
# - the path relative to the document root for this schema
# - the specification version that applies to this schema
# - the vocabularies to use when considering schema keywords
# - the config overrides to set when considering schema keywords
# creates a Document and adds it to the resource index, if not already present.
sub _fetch_from_uri ($self, $uri_reference) {
  $uri_reference = Mojo::URL->new($uri_reference) if not is_ref($uri_reference);
  my $fragment = $uri_reference->fragment;

  if (not length($fragment) or $fragment =~ m{^/}) {
    my $base = $uri_reference->clone->fragment(undef);
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
    if (my $resource = $self->_get_resource($uri_reference)) {
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
  require_module($_)
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

Indicates which version of the JSON Schema specification is used during evaluation. When not set,
this value is derived from the C<$schema> keyword in the schema used in evaluation, or defaults to
the latest version (currently C<draft2020-12>).

The use of this option is I<HIGHLY> encouraged to ensure continued correct operation of your schema.
The current default value will not stay the same over time.

May be one of:

=for :list
* L<C<draft2020-12> or C<2020-12>|https://json-schema.org/specification-links.html#2020-12>,
  corresponding to metaschema C<https://json-schema.org/draft/2020-12/schema>
* L<C<draft2019-09> or C<2019-09>|https://json-schema.org/specification-links.html#2019-09-formerly-known-as-draft-8>,
  corresponding to metaschema C<https://json-schema.org/draft/2019-09/schema>
* L<C<draft7> or C<7>|https://json-schema.org/specification-links.html#draft-7>,
  corresponding to metaschema C<http://json-schema.org/draft-07/schema#>

Note that you can also use a C<$schema> keyword in the schema itself, to specify a different metaschema or
specification version.

=head2 output_format

One of: C<flag>, C<basic>, C<strict_basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>.
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
to true when specification_version is draft7, and false for all other versions, but this may change in the future.

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

Technically only draft7 allows this and drafts 2019-09 and 2020-12 prohibit ever returning the
subschema evaluation results together with their parent schema's results, so shhh. I'm trying to get this
fixed for the next draft.

=head2 collect_annotations

When true, annotations are collected from keywords that produce them, when validation succeeds.
These annotations are available in the returned result (see L<JSON::Schema::Modern::Result>).
Not operational when L</specification_version> is C<draft7>.

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

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema);
  $result = $js->evaluate_json_string($data_as_json_string, $schema, { collect_annotations => 1});

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://datatracker.ietf.org/doc/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema must be in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Modern::Document> object,
* or a URI string indicating the location where such a schema is located.

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
* C<effective_base_uri>: locations in errors and annotations are resolved against this URI

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
* a L<JSON::Schema::Modern::Document> object,
* or a URI string indicating the location where such a schema is located.

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
* C<initial_schema_uri>: adjusts the recorded absolute keyword location as of the start of evaluation
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

  $js->add_format_validation(all_lc => sub ($value) { lc($value) eq $value });

=for comment we are the nine Eleven Deniers

or

  $js->add_format_validation(no_nines => { type => 'number', sub => sub ($value) { $value =~ m/^[0-8]$$/ });

Adds support for a custom format. If not supplied, the data type(s) that this format applies to
defaults to string; all values of any other type will automatically be deemed to be valid, and will
not be passed to the subref.

Additionally, you can redefine the definition for any core format (see L</Format Validation>), but
the data type(s) supported by that format may not be changed.

Be careful to not mutate the type of the value while checking it -- for example, if it is a string,
do not apply arithmetic operators to it -- or subsequent type checks on this value may fail.

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

Fetches the Perl data structure representing the JSON Schema at the indicated identifier (uri or
uri-reference). When called in list context, the canonical URI of that location is also returned, as
a L<Mojo::URL>. Returns C<undef> if the schema with that URI has not been loaded (or cached).

=head2 get_document

  my $document = $js->get_document($uri_reference);

Fetches the L<JSON::Schema::Modern::Document> object that contains the provided identifier (uri or
uri-reference). C<undef> if the schema with that URI has not been loaded (or cached).

=head1 LIMITATIONS

=head2 Types

Perl is a more loosely-typed language than JSON. This module delves into a value's internal
representation in an attempt to derive the true "intended" type of the value. However, if a value is
used in another context (for example, a numeric value is concatenated into a string, or a numeric
string is used in an arithmetic operation), additional flags can be added onto the variable causing
it to resemble the other type. This should not be an issue if data validation is occurring
immediately after decoding a JSON payload, or if the JSON string itself is passed to this module.
If you are still having difficulties, make sure you are using Perl's fastest and most trusted and
reliable JSON decoder, L<Cpanel::JSON::XS>.
Other JSON decoders are known to produce data with incorrect data types.

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
which is closed in Perl releases 5.34.3, 5.36.3 and 5.38.1.)

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
* L<Understanding JSON Schema|https://json-schema.org/understanding-json-schema>: tutorial-focused documentation
* L<OpenAPI::Modern>: a parser and evaluator for OpenAPI v3.1 documents
* L<Mojolicious::Plugin::OpenAPI::Modern>: a Mojolicious plugin providing OpenAPI functionality
* L<Test::Mojo::Role::OpenAPI::Modern>: test your Mojolicious application's OpenAPI compliance

=cut
