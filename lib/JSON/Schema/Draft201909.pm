use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.016';

use 5.016;  # for fc, unicode_strings features
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::MaybeXS;
use Syntax::Keyword::Try 0.11;
use Carp qw(croak carp);
use List::Util 1.55 qw(pairs first uniqint);
use Ref::Util 0.100 qw(is_ref is_plain_hashref is_plain_coderef is_plain_arrayref);
use Mojo::URL;
use Safe::Isa;
use Path::Tiny;
use Storable 'dclone';
use File::ShareDir 'dist_dir';
use Module::Runtime 'use_module';
use Moo;
use strictures 2;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(Bool Int Str HasMethods Enum InstanceOf HashRef Dict CodeRef);
use JSON::Schema::Draft201909::Error;
use JSON::Schema::Draft201909::Result;
use JSON::Schema::Draft201909::Document;
use JSON::Schema::Draft201909::Utilities qw(get_type canonical_schema_uri E abort);
use namespace::clean;

has output_format => (
  is => 'ro',
  isa => Enum(JSON::Schema::Draft201909::Result->OUTPUT_FORMATS),
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
  default => 0,
);

sub BUILD {
  my ($self, $args) = @_;

  if (exists $args->{format_validations}) {
    croak 'format_validations must be a hashref'
      if not is_plain_hashref($args->{format_validations});

    foreach my $format (keys %{$args->{format_validations}}) {
      if (my $existing = $self->_get_format_validation($format)) {
        croak 'overrides to existing format_validations must be coderefs'
          if not is_plain_coderef($args->{format_validations}{$format});
        $self->_set_format_validation($format,
          +{ type => $existing->{type}, sub => $args->{format_validations}{$format} });
      }
      else {
        my $type = Dict[type => Enum[qw(null object array boolean string number integer)], sub => CodeRef];
        croak $type->get_message($args->{format_validations}{$format})
          if not $type->check($args->{format_validations}{$format});

        $self->_set_format_validation($format => $args->{format_validations}{$format});
      }
    }
  }
}

sub add_schema {
  my $self = shift;
  die 'insufficient arguments' if @_ < 1;

  # TODO: resolve $uri against $self->base_uri
  my $uri = !is_ref($_[0]) ? Mojo::URL->new(shift)
    : $_[0]->$_isa('Mojo::URL') ? shift : Mojo::URL->new;

  croak 'cannot add a schema with a uri with a fragment' if defined $uri->fragment;

  if (not @_) {
    my ($schema, $canonical_uri, $document, $document_path) = $self->_fetch_schema_from_uri($uri);
    return if not defined $schema or not defined wantarray;
    return $document;
  }

  my $document = $_[0]->$_isa('JSON::Schema::Draft201909::Document') ? shift
    : JSON::Schema::Draft201909::Document->new(
      schema => shift,
      $uri ? (canonical_uri => $uri) : (),
      _evaluator => $self,
    );

  die [ $document->errors ] if $document->has_errors;

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
        $document->_resource_pairs);
    }
  }

  if ("$uri") {
    $document->_add_resources($uri, { path => '', canonical_uri => $document->canonical_uri });
    $self->_add_resources($uri => { path => '', canonical_uri => $document->canonical_uri, document => $document });
  }

  return $document;
}

sub evaluate_json_string {
  my ($self, $json_data, $schema, $config_override) = @_;
  die 'insufficient arguments' if @_ < 3;

  my $data;
  try {
    $data = $self->_json_decoder->decode($json_data)
  }
  catch {
    return JSON::Schema::Draft201909::Result->new(
      output_format => $self->output_format,
      result => 0,
      errors => [
        JSON::Schema::Draft201909::Error->new(
          keyword => undef,
          instance_location => '',
          keyword_location => '',
          error => $@,
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
  my ($self, $schema_reference, $config_override) = @_;
  die 'insufficient arguments' if @_ < 2;

  my $base_uri = Mojo::URL->new($config_override->{canonical_schema_uri} // '');

  my $state = {
    depth => 0,
    data_path => '',                    # this never changes since we don't have an instance yet
    traversed_schema_path => '',        # the accumulated path up to the last $ref traversal
    canonical_schema_uri => $base_uri,  # the canonical path of the last traversed $ref
    schema_path => '',                  # the rest of the path, since the last traversed $ref
    errors => [],
    # for now, this is hardcoded, but in the future we will start off only with the Core vocabulary
    # and then determine the actual value(s) from the '$schema' keyword in the schema and the
    # '$vocabulary' keyword in the metaschema.
    vocabularies => [
      (map use_module($_)->new(evaluator => $self),
        map 'JSON::Schema::Draft201909::Vocabulary::'.$_,
          qw(Core Validation Applicator Format Content MetaData)),
      $self,  # for discontinued keywords defined in the base schema
    ],
    identifiers => [],
    callbacks => $config_override->{callbacks} // {},
  };

  try {
    $self->_traverse($schema_reference, $state);
  }
  catch {
    if ($@->$_isa('JSON::Schema::Draft201909::Error')) {
      push @{$state->{errors}}, $@;
    }
    else {
      E($state, 'EXCEPTION: '.$@);
    }
  }

  return $state;
}

sub evaluate {
  my ($self, $data, $schema_reference, $config_override) = @_;
  die 'insufficient arguments' if @_ < 3;

  my $base_uri = Mojo::URL->new;  # TODO: will be set by a global attribute

  my $state = {
    short_circuit => $config_override->{short_circuit} // $self->short_circuit,
    collect_annotations => $config_override->{collect_annotations} // $self->collect_annotations,
    validate_formats => $config_override->{validate_formats} // $self->validate_formats,
    depth => 0,
    data_path => '',
    traversed_schema_path => '',        # the accumulated path up to the last $ref traversal
    canonical_schema_uri => $base_uri,  # the canonical path of the last traversed $ref
    document => 'SEE BELOW',            # the ::Document object containing this schema
    document_path => 'SEE BELOW',       # the *initial* path within the document of this schema
    schema_path => '',                  # the rest of the path, since the last traversed $ref
    errors => [],
    annotations => [],
    seen => {},
    # for now, this is hardcoded, but in the future we will start off only with the Core vocabulary
    # and then determine the actual value(s) from the '$schema' keyword in the schema and the
    # '$vocabulary' keyword in the metaschema.
    vocabularies => [
      (map use_module($_)->new(evaluator => $self),
        map 'JSON::Schema::Draft201909::Vocabulary::'.$_,
          qw(Core Validation Applicator Format Content MetaData)),
      $self,  # for discontinued keywords defined in the base schema
    ],
  };

  my $result;
  try {
    my ($schema, $canonical_uri, $document, $document_path);

    if (not is_ref($schema_reference) or $schema_reference->$_isa('Mojo::URL')) {
      # TODO: resolve $uri against base_uri
      ($schema, $canonical_uri, $document, $document_path) = $self->_fetch_schema_from_uri($schema_reference);
    }
    else {
      $document = $self->add_schema($state->{canonical_schema_uri}, $schema_reference);
      ($schema, $canonical_uri) = map $document->$_, qw(schema canonical_uri);
      $document_path = '';
    }

    abort($state, 'unable to find resource %s', $schema_reference) if not defined $schema;

    @$state{qw(canonical_schema_uri document document_path)} = ($canonical_uri, $document, $document_path);

    $result = $self->_eval($data, $schema, $state);
  }
  catch {
    if (is_plain_arrayref($@)) {
      push @{$state->{errors}}, @{$@};
    }
    elsif ($@->$_isa('JSON::Schema::Draft201909::Error')) {
      push @{$state->{errors}}, $@;
    }
    else {
      E($state, 'EXCEPTION: '.$@);
    }

    $result = 0;
  }

  return JSON::Schema::Draft201909::Result->new(
    output_format => $self->output_format,
    result => $result,
    $result
      ? ($state->{collect_annotations} ? (annotations => $state->{annotations}) : ())
      : (errors => $state->{errors}),
  );
}

sub get {
  my ($self, $uri) = @_;
  die 'insufficient arguments' if @_ < 2;

  my ($subschema, $canonical_uri) = $self->_fetch_schema_from_uri($uri);
  $subschema = dclone($subschema) if is_ref($subschema);
  return !defined $subschema ? () : wantarray ? ($subschema, $canonical_uri) : $subschema;
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

sub _traverse {
  my ($self, $schema, $state) = @_;

  delete $state->{keyword};

  return E($state, 'maximum traversal depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  my $schema_type = get_type($schema);
  return if $schema_type eq 'boolean';

  return E($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  foreach my $vocabulary (@{$state->{vocabularies}}) {
    foreach my $keyword ($vocabulary->keywords) {
      next if not exists $schema->{$keyword};

      $state->{keyword} = $keyword;
      my $method = '_traverse_keyword_'.($keyword =~ s/^\$//r);

      $vocabulary->$method($schema, $state) if $vocabulary->can($method);

      if (my $sub = $state->{callbacks}{$keyword}) {
        $sub->($schema, $state);
      }
    }
  }
}

sub _eval {
  my ($self, $data, $schema, $state) = @_;

  $state = { %$state };     # changes to $state should only affect subschemas, not parents
  my @parent_annotations = @{$state->{annotations}};
  delete $state->{keyword};

  abort($state, 'maximum evaluation depth exceeded')
    if $state->{depth}++ > $self->max_traversal_depth;

  abort($state, 'infinite loop detected (same location evaluated twice)')
    if $state->{seen}{$state->{data_path}}{canonical_schema_uri($state)}++;

  my $schema_type = get_type($schema);
  return $schema || E($state, 'subschema is false') if $schema_type eq 'boolean';

  # this should never happen, due to checks in traversal
  abort($state, 'invalid schema type: %s', $schema_type) if $schema_type ne 'object';

  my $result = 1;

  foreach my $vocabulary (@{$state->{vocabularies}}) {
    foreach my $keyword ($vocabulary->keywords) {
      next if not exists $schema->{$keyword};

      $state->{keyword} = $keyword;
      my $method = '_eval_keyword_'.($keyword =~ s/^\$//r);
      $result = 0 if $vocabulary->can($method) and not $vocabulary->$method($data, $schema, $state);

      last if not $result and $state->{short_circuit};
    }
  }

  @{$state->{annotations}} = @parent_annotations if not $result;
  return $result;
}

# it's a bit gross keeping this here rather than with the Format vocabulary,
# but it would be messier passing the data over when we instantiate the vocabulary
# during evaluation.
has _format_validations => (
  is => 'bare',
  isa => HashRef[Dict[
      type => Enum[qw(null object array boolean string number integer)],
      sub => CodeRef,
    ]],
  handles_via => 'Hash',
  handles => {
    _get_format_validation => 'get',
    _set_format_validation => 'set',
  },
  lazy => 1,
  default => sub {
    my $is_datetime = sub {
      eval { require Time::Moment; 1 } or return 1;
      eval { Time::Moment->from_string($_[0]) } ? 1 : 0,
    };
    my $is_email = sub {
      eval { require Email::Address::XS; Email::Address::XS->VERSION(1.01); 1 } or return 1;
      Email::Address::XS->parse($_[0])->is_valid;
    };
    my $is_hostname = sub {
      eval { require Data::Validate::Domain; 1 } or return 1;
      Data::Validate::Domain::is_domain($_[0]);
    };
    my $idn_decode = sub {
      eval { require Net::IDN::Encode; 1 } or return $_[0];
      try { return Net::IDN::Encode::domain_to_ascii($_[0]) } catch { return $_[0]; }
    };
    my $is_ipv4 = sub {
      my @o = split(/\./, $_[0], 5);
      @o == 4 && (grep /^[0-9]{1,3}$/, @o) == 4 && (grep $_ < 256, @o) == 4;
    };
    # https://tools.ietf.org/html/rfc3339#appendix-A with some additions for the 2000 version
    # as defined in https://en.wikipedia.org/wiki/ISO_8601#Durations
    my $duration_re = do {
      my $num = qr{[0-9]+(?:[.,][0-9]+)?};
      my $second = qr{${num}S};
      my $minute = qr{${num}M};
      my $hour = qr{${num}H};
      my $time = qr{T(?=[0-9])(?:$hour)?(?:$minute)?(?:$second)?};
      my $day = qr{${num}D};
      my $month = qr{${num}M};
      my $year = qr{${num}Y};
      my $week = qr{${num}W};
      my $date = qr{(?=[0-9])(?:$year)?(?:$month)?(?:$day)?};
      qr{^P(?:(?=.)(?:$date)?(?:$time)?|$week)$};
    };

    +{
      'date-time' => { type => 'string', sub => $is_datetime },
      date => { type => 'string', sub => sub { $is_datetime->($_[0].'T00:00:00Z') } },
      time => { type => 'string', sub => sub { $is_datetime->('2000-01-01T'.$_[0]) } },
      duration => { type => 'string', sub => sub {
        $_[0] =~ $duration_re && $_[0] !~ m{[.,][0-9]+[A-Z].};
      } },
      email => { type => 'string', sub => sub { $is_email->($_[0]) && $_[0] !~ /[^[:ascii:]]/ } },
      'idn-email' => { type => 'string', sub => $is_email },
      hostname => { type => 'string', sub => $is_hostname },
      'idn-hostname' => { type => 'string', sub => sub { $is_hostname->($idn_decode->($_[0])) } },
      ipv4 => { type => 'string', sub => $is_ipv4 },
      ipv6 => { type => 'string', sub => sub {
        ($_[0] =~ /^(?:[[:xdigit:]]{0,4}:){0,7}[[:xdigit:]]{0,4}$/
          || $_[0] =~ /^(?:[[:xdigit:]]{0,4}:){1,6}((?:[0-9]{1,3}\.){3}[0-9]{1,3})$/
              && $is_ipv4->($1))
          && $_[0] !~ /:::/
          && $_[0] !~ /^:[^:]/
          && $_[0] !~ /[^:]:$/
          && do {
            my $double_colons = ()= ($_[0] =~ /::/g);
            my $colon_components = grep length, split(/:+/, $_[0], -1);
            $double_colons < 2 && ($double_colons > 0
              || ($colon_components == 8 && !defined $1)
              || ($colon_components == 7 && defined $1))
          };
      } },
      uri => { type => 'string', sub => sub {
        my $uri = Mojo::URL->new($_[0]);
        fc($uri->to_unsafe_string) eq fc($_[0]) && $uri->is_abs && $_[0] !~ /[^[:ascii:]]/;
      } },
      'uri-reference' => { type => 'string', sub => sub {
        fc(Mojo::URL->new($_[0])->to_unsafe_string) eq fc($_[0]) && $_[0] !~ /[^[:ascii:]]/;
      } },
      iri => { type => 'string', sub => sub { Mojo::URL->new($_[0])->is_abs } },
      'iri-reference' => { type => 'string', sub => sub { 1 } },
      uuid => { type => 'string', sub => sub {
        $_[0] =~ /^[[:xdigit:]]{8}-(?:[[:xdigit:]]{4}-){3}[[:xdigit:]]{12}$/;
      } },
      'uri-template' => { type => 'string', sub => sub { 1 } },
      'json-pointer' => { type => 'string', sub => sub {
        (!length($_[0]) || $_[0] =~ m{^/}) && $_[0] !~ m{~(?![01])};
      } },
      'relative-json-pointer' => { type => 'string', sub => sub {
        $_[0] =~ m{^[0-9]+(?:#$|$|/)} && $_[0] !~ m{~(?![01])};
      } },
      regex => { type => 'string', sub => sub { eval { qr/$_[0]/; 1 } ? 1 : 0 } },
    }
  },
);

sub keywords { qw(definitions dependencies) }

sub _eval_keyword_definitions {
  my ($self, $schema, $state) = @_;
  carp 'no-longer-supported "definitions" keyword present (at '
    .canonical_schema_uri($state).'): this should be rewritten as "$defs"';
  return 1;
}

sub _eval_keyword_dependencies {
  my ($self, $schema, $state) = @_;
  carp 'no-longer-supported "dependencies" keyword present (at'
    .canonical_schema_uri($state)
    .'): this should be rewritten as "dependentSchemas" or "dependentRequired"';
  return 1;
}

has _resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,
      document => InstanceOf['JSON::Schema::Draft201909::Document'],
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
      if ($key eq '') {
        # we allow overwriting canonical_uri = '' to allow for ad hoc evaluation of schemas that
        # lack all identifiers altogether; we drop *all* resources from that document
        $self->_remove_resource(
          grep $self->_get_resource($_)->{document} == $existing->{document}, $self->_resource_keys);
      }
      else {
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
  'https://json-schema.org/draft/2019-09/hyper-schema'        => '2019-09/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/links'               => '2019-09/links.json',
  'https://json-schema.org/draft/2019-09/meta/applicator'     => '2019-09/meta/applicator.json',
  'https://json-schema.org/draft/2019-09/meta/content'        => '2019-09/meta/content.json',
  'https://json-schema.org/draft/2019-09/meta/core'           => '2019-09/meta/core.json',
  'https://json-schema.org/draft/2019-09/meta/format'         => '2019-09/meta/format.json',
  'https://json-schema.org/draft/2019-09/meta/hyper-schema'   => '2019-09/meta/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/meta/meta-data'      => '2019-09/meta/meta-data.json',
  'https://json-schema.org/draft/2019-09/meta/validation'     => '2019-09/meta/validation.json',
  'https://json-schema.org/draft/2019-09/output/hyper-schema' => '2019-09/output/hyper-schema.json',
  'https://json-schema.org/draft/2019-09/output/schema'       => '2019-09/output/schema.json',
  'https://json-schema.org/draft/2019-09/schema'              => '2019-09/schema.json',
};

# returns the same as _get_resource
sub _get_or_load_resource {
  my ($self, $uri) = @_;

  my $resource = $self->_get_resource($uri);
  return $resource if $resource;

  if (my $local_filename = $self->CACHED_METASCHEMAS->{$uri}) {
    my $file = path(dist_dir('JSON-Schema-Draft201909'), $local_filename);
    my $schema = $self->_json_decoder->decode($file->slurp_raw);
    my $document = JSON::Schema::Draft201909::Document->new(schema => $schema, _evaluator => $self);
    die [ $document->errors ] if $document->has_errors;

    # we have already performed the appropriate collision checks, so we bypass them here
    $self->_add_resources_unsafe(
      map +($_->[0] => +{ %{$_->[1]}, document => $document }),
        $document->_resource_pairs
    );

    return $self->_get_resource($uri);
  }

  # TODO:
  # - load from network or disk
  # - handle such resources with $anchor fragments

  return;
};

# returns a schema (which may not be at a document root), the canonical uri for that schema,
# the JSON::Schema::Draft201909::Document object that holds that schema, and the path relative
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
      undef $fragment if not length $fragment;
      $canonical_uri = $resource->{canonical_uri}->clone->fragment($fragment);
      $document = $resource->{document};
    }
  }
  else {
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
=for stopwords schema subschema metaschema validator evaluator

=head1 SYNOPSIS

  use JSON::Schema::Draft201909;

  $js = JSON::Schema::Draft2019->new(
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

=head2 output_format

One of: C<flag>, C<basic>, C<detailed>, C<verbose>, C<terse>. Defaults to C<basic>. Passed to
L<JSON::Schema::Draft201909::Result/output_format>.

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
These annotations are available in the returned result (see L<JSON::Schema::Draft201909::Result>).
Defaults to false.

=head1 METHODS

=for Pod::Coverage BUILD keywords

=head2 evaluate_json_string

  $result = $js->evaluate_json_string($data_as_json_string, $schema_data);
  $result = $js->evaluate_json_string($data_as_json_string, $schema_data, { collect_annotations => 1});

Evaluates the provided instance data against the known schema document.

The data is in the form of a JSON-encoded string (in accordance with
L<RFC8259|https://tools.ietf.org/html/rfc8259>). B<The string is expected to be UTF-8 encoded.>

The schema must represent a JSON Schema that respects the Draft 2019-09 meta-schema at
L<https://json-schema.org/draft/2019-09/schema>, in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Draft201909::Document> object,
* or a URI string indicating the location where such a schema is located.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations> and/or L</validate_formats> settings for just this
evaluation call.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 evaluate

  $result = $js->evaluate($instance_data, $schema_data);
  $result = $js->evaluate($instance_data, $schema_data, { short_circuit => 0 });

Evaluates the provided instance data against the known schema document.

The data is in the form of an unblessed nested Perl data structure representing any type that JSON
allows (null, boolean, string, number, object, array).

The schema must represent a JSON Schema that respects the Draft 2019-09 meta-schema at
L<https://json-schema.org/draft/2019-09/schema>, in one of these forms:

=for :list
* a Perl data structure, such as what is returned from a JSON decode operation,
* a L<JSON::Schema::Draft201909::Document> object,
* or a URI string indicating the location where such a schema is located.

Optionally, a hashref can be passed as a third parameter which allows changing the values of the
L</short_circuit>, L</collect_annotations> and/or L</validate_formats> settings for just this
evaluation call.

The result is a L<JSON::Schema::Draft201909::Result> object, which can also be used as a boolean.

=head2 traverse

  $result = $js->traverse($schema_data);
  $result = $js->traverse($schema_data, { canonical_schema_uri => 'http://foo.com' });

Traverses the provided schema data without evaluating it against any instance data. Returns the
internal state object accumulated during the traversal, including any identifiers found therein, and
any errors found during parsing. For internal purposes only.

You can pass a series of callback subs to this method corresponding to keywords, which is useful for
extracting data from within schemas and skipping properties that may look like keywords but actually
are not (for example C<{"const":{"$ref": "this is not actually a $ref"}}>). This feature is highly
experimental and is highly likely to change in the future.

For example, to find the resolved targets of all C<$ref> keywords in a schema document:

  my @refs;
  JSON::Schema::Draft201909->new->traverse($schema, {
    callbacks => {
      '$ref' => sub ($schema, $state) {
        push @refs, Mojo::URL->new($schema->{'$ref'})
          ->to_abs(JSON::Schema::Draft201909::Utilities::canonical_schema_uri($state));
      }
    },
  });

=head2 add_schema

  $js->add_schema($uri => $schema);
  $js->add_schema($uri => $document);
  $js->add_schema($schema);
  $js->add_schema($document);

Introduces the (unblessed, nested) Perl data structure or L<JSON::Schema::Draft201909::Document>
object, representing a JSON Schema, to the implementation, registering it under the indicated URI if
provided (and if not, C<''> will be used if no other identifier can be found within).

You B<MUST> call C<add_schema> for any external resources that a schema may reference via C<$ref>
before calling L</evaluate>, other than the standard metaschemas which are loaded from a local cache
as needed.

Returns the L<JSON::Schema::Draft201909::Document> that contains the added schema, or C<undef>
if the resource could not be found.

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

To date, missing components (some of which are optional, but still quite useful) include:

=for :list
* loading schema documents from disk
* loading schema documents from the network
* loading schema documents from a local web application (e.g. L<Mojolicious>)
* additional output formats beyond C<flag>, C<basic> and C<terse>
  (L<https://json-schema.org/draft/2019-09/json-schema-core.html#rfc.section.10>)
* examination of the C<$schema> keyword for deviation from the standard metaschema, including
  changes to vocabulary behaviour

Additionally, some small errors in the specification (which have been fixed in the next draft
specification version) are fixed here rather than implementing the precise but unintended behaviour,
most notably in the use of json pointers rather than fragment-only URIs in C<instanceLocation> and
C<keywordLocation> in annotations and errors.

=head1 SECURITY CONSIDERATIONS

The C<pattern> and C<patternProperties> keywords, and the C<regex> format validator,
evaluate regular expressions from the schema.
No effort is taken (at this time) to sanitize the regular expressions for embedded code or
potentially pathological constructs that may pose a security risk, either via denial of service
or by allowing exposure to the internals of your application. B<DO NOT USE SCHEMAS FROM UNTRUSTED
SOURCES.>

=head1 SEE ALSO

=for :list
* L<https://json-schema.org/>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://tools.ietf.org/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://tools.ietf.org/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>

=cut
