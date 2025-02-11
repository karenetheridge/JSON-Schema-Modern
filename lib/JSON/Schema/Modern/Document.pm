use strict;
use warnings;
package JSON::Schema::Modern::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.602';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Mojo::URL;
use Carp 'croak';
use List::Util 1.29 'pairs';
use Ref::Util 0.100 'is_plain_hashref';
use Safe::Isa 1.000008;
use MooX::TypeTiny;
use Types::Standard 1.016003 qw(InstanceOf HashRef Str Map Dict ArrayRef Enum ClassName Undef Slurpy Optional);
use Types::Common::Numeric 'PositiveOrZeroInt';
use namespace::clean;

extends 'Mojo::JSON::Pointer';

has schema => (
  is => 'ro',
  required => 1,
);

has canonical_uri => (
  is => 'rwp',
  isa => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
  lazy => 1,
  default => sub { Mojo::URL->new },
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

has metaschema_uri => (
  is => 'rwp',
  isa => (InstanceOf['Mojo::URL'])->where(q{not length $_->fragment}), # allow for .../draft-07/schema#
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

has evaluator => (
  is => 'rwp',
  isa => InstanceOf['JSON::Schema::Modern'],
  weak_ref => 1,
);

# "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.3.5
my $path_type = Str->where('m{^(?:/|$)}');  # JSON pointer relative to the document root
has resource_index => (
  is => 'bare',
  isa => Map[my $resource_key_type = Str->where('!/#/'), my $resource_type = Dict[
      # always stringwise-equal to the top level key
      canonical_uri => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
      path => $path_type,
      specification_version => Enum[qw(draft4 draft6 draft7 draft2019-09 draft2020-12)],
      # the vocabularies used when evaluating instance data against schema
      vocabularies => ArrayRef[ClassName->where(q{$_->DOES('JSON::Schema::Modern::Vocabulary')})],
      configs => HashRef,
      anchors => Optional[HashRef[Dict[
        canonical_uri => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment or substr($_->fragment, 0, 1) eq '/'}),
        path => $path_type,
      ]]],
      Slurpy[HashRef[Undef]],  # no other fields allowed
    ]],
  init_arg => undef,
  default => sub { {} },
);

sub resource_index { $_[0]->{resource_index}->%* }
sub resource_pairs { pairs $_[0]->{resource_index}->%* }
sub _get_resource { $_[0]->{resource_index}{$_[1]} }
sub _canonical_resources { values $_[0]->{resource_index}->%* }
sub _add_resource {
  croak 'uri "'.$_[1].'" conflicts with an existing schema resource' if $_[0]->{resource_index}{$_[1]};
  $_[0]->{resource_index}{$resource_key_type->($_[1])} = $resource_type->($_[2]);
}

has _path_to_resource => (
  is => 'ro',
  isa => HashRef[$resource_type],
  init_arg => undef,
  lazy => 1,
  default => sub { +{ map +($_->{path} => $_), shift->_canonical_resources } },
);

sub path_to_resource { $_[0]->_path_to_resource; $_[0]->{_path_to_resource}{$_[1]} }

# for internal use only
has _checksum => (
  is => 'rw',
  isa => Str,
  init_arg => undef,
);

has errors => (
  is => 'bare',
  writer => '_set_errors',
  isa => ArrayRef[InstanceOf['JSON::Schema::Modern::Error']],
  lazy => 1,
  default => sub { [] },
);

sub errors { ($_[0]->{errors}//[])->@* }
sub has_errors { scalar(($_[0]->{errors}//[])->@*) }

# json pointer => entity name (indexed by integer)
has _entities => (
  is => 'ro',
  isa => HashRef[PositiveOrZeroInt],
  lazy => 1,
  default => sub { {} },
);

# in this class, the only entity type is 'schema', but subclasses add more
sub __entities ($) { qw(schema) }
sub __entity_type { Enum[$_[0]->__entities] }
sub __entity_index ($self, $entity) {
  my @e = $self->__entities;
  foreach my $i (0..$#e) { return $i if $e[$i] eq $entity; }
  return undef;
}

sub _add_entity_location ($self, $location, $entity) {
  $self->__entity_type->($entity); # verify string
  $self->_entities->{$location} = $self->__entity_index($entity); # store integer-mapped value
}

sub get_entity_at_location ($self, $location) {
  return '' if not exists $self->_entities->{$location};
  ($self->__entities)[ $self->_entities->{$location} ] // die "missing mapping for ", $self->_entities->{$location};
}

# note: not sorted
sub get_entity_locations ($self, $entity) {
  $self->__entity_type->($entity); # verify string
  my $index = $self->__entity_index($entity);
  grep $self->{_entities}{$_} == $index, keys $self->{_entities}->%*;
}

# shims for Mojo::JSON::Pointer
sub data { shift->schema(@_) }
sub FOREIGNBUILDARGS { () }

# for JSON serializers
sub TO_JSON { shift->schema }

# note that this is always called, even in subclasses
sub BUILD ($self, $args) {
  my $original_uri = $self->canonical_uri->clone;
  my $state = $self->traverse(
    $self->evaluator // $self->_set_evaluator(JSON::Schema::Modern->new),
    $args->{specification_version} ? +{ $args->%{specification_version} } : (),
  );

  # if the schema identified a canonical uri for itself, it overrides the initial value
  $self->_set_canonical_uri($state->{initial_schema_uri}) if $state->{initial_schema_uri} ne $original_uri;

  if ($state->{errors}->@*) {
    $self->_set_errors($state->{errors});
    return;
  }

  my $seen_root;
  foreach my $key (keys $state->{identifiers}->%*) {
    my $value = $state->{identifiers}{$key};
    $self->_add_resource($key => $value);

    # we're adding a non-anchor entry for the document root
    ++$seen_root if $value->{path} eq '' and $key !~ /#./
  }

  $self->_add_resource($original_uri.'' => {
      path => '',
      canonical_uri => $self->canonical_uri,
      specification_version => $state->{spec_version},
      vocabularies => $state->{vocabularies},
      configs => $state->{configs},
    })
  if not $seen_root;

  $self->_add_entity_location($_, 'schema') foreach $state->{subschemas}->@*;
}

# a subclass's method will override this one
sub traverse ($self, $evaluator, $config_override = {}) {
  die 'wrong class - use JSON::Schema::Modern::Document::OpenAPI instead'
    if is_plain_hashref($self->schema) and exists $self->schema->{openapi};

  my $state = $evaluator->traverse($self->schema,
    {
      initial_schema_uri => $self->canonical_uri->clone,
      $self->metaschema_uri ? ( metaschema_uri => $self->metaschema_uri ) : (),
      %$config_override,
    }
  );

  return $state if $state->{errors}->@*;

  # we don't store the metaschema_uri in $state nor in resource_index, but we can figure it out
  # easily enough.
  my $metaschema_uri = (is_plain_hashref($self->schema) ? $self->schema->{'$schema'} : undef)
    // $self->metaschema_uri // $evaluator->METASCHEMA_URIS->{$state->{spec_version}};

  $self->_set_metaschema_uri($metaschema_uri) if $metaschema_uri ne ($self->metaschema_uri//'');

  return $state;
}

sub validate ($self) {
  my $js = $self->$_call_if_can('evaluator') // JSON::Schema::Modern->new;

  return $js->evaluate($self->schema, $self->metaschema_uri);
}

# callback hook for Sereal::Decoder
sub THAW ($class, $serializer, $data) {
  my $self = bless($data, $class);
  foreach my $attr (qw(schema _entities _checksum)) {
    die "serialization missing attribute '$attr': perhaps your serialized data was produced for an older version of $class?"
      if not exists $self->{$attr};
  }
  return $self;
}

1;
__END__

=pod

=for :header
=for stopwords subschema

=head1 SYNOPSIS

    use JSON::Schema::Modern::Document;

    my $document = JSON::Schema::Modern::Document->new(
      canonical_uri => 'https://example.com/v1/schema',
      metaschema_uri => 'https://example.com/my/custom/metaschema',
      schema => $schema,
    );
    my $foo_definition = $document->get('/$defs/foo');
    my %resource_index = $document->resource_index;

    my sanity_check = $document->validate;

=head1 DESCRIPTION

This class represents one JSON Schema document, to be used by L<JSON::Schema::Modern>.

=head1 ATTRIBUTES

=head2 schema

The actual raw data representing the schema.

=head2 canonical_uri

When passed in during construction, this represents the initial URI by which the document should
be known. It is overwritten with the (resolved form of the) root schema's C<$id> property when one
exists, and as such can be considered the canonical URI for the document as a whole.

=head2 metaschema_uri

=for stopwords metaschema schemas

Sets the metaschema that is used to describe the document (or more specifically, any JSON Schemas
contained within the document), which determines the
specification version and vocabularies used during evaluation. Does not override any
C<$schema> keyword actually present in the schema document.

=head2 specification version

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

=head2 evaluator

A L<JSON::Schema::Modern> object. Optional, unless custom metaschemas are used.

=head2 resource_index

An index of URIs to subschemas (JSON pointer to reach the location, and the canonical URI of that
location) for all identifiable subschemas found in the document. An entry for URI C<''> is added
only when no other suitable identifier can be found for the root schema.

This attribute should only be used by L<JSON::Schema::Modern> and not intended for use
externally (you should use the public accessors in L<JSON::Schema::Modern> instead).

When called as a method, returns the flattened list of tuples (path, uri). You can also use
C<resource_pairs> which returns a list of tuples as arrayrefs.

=head2 canonical_uri_index

An index of JSON pointers (from the document root) to canonical URIs. This is the inversion of
L</resource_index> and is constructed as that is built up.

=head2 errors

A list of L<JSON::Schema::Modern::Error> objects that resulted when the schema document was
originally parsed. (If a syntax error occurred, usually there will be just one error, as parse
errors halt the parsing process.) Documents with errors cannot be evaluated.

=head1 METHODS

=for Pod::Coverage FOREIGNBUILDARGS BUILDARGS BUILD THAW traverse has_errors path_to_resource resource_pairs get_entity_at_location get_entity_locations

=head2 path_to_canonical_uri

=for stopwords fragmentless

Given a JSON pointer (a path) within this document, returns the canonical URI corresponding to that location.
Only fragmentless URIs can be looked up in this manner, so it is only suitable for finding the
canonical URI corresponding to a subschema known to have an C<$id> keyword.

=head2 contains

Check if L</"schema"> contains a value that can be identified with the given JSON Pointer.
See L<Mojo::JSON::Pointer/contains>.

=head2 get

Extract value from L</"schema"> identified by the given JSON Pointer.
See L<Mojo::JSON::Pointer/get>.

=head2 validate

Evaluates the document against its metaschema. See L<JSON::Schema::Modern/evaluate>.
For regular JSON Schemas this is redundant with creating the document in the first place (which also
includes a validation check), but for some subclasses of this class, additional things might be
checked that are not caught by document creation.

=head2 TO_JSON

Returns a data structure suitable for serialization. See L</schema>.

=head1 SUBCLASSING

=for stopwords OpenAPI referenceable

This class can be subclassed to describe documents of other types, which follow the same basic model
(has a document-level identifier and may contain internal referenceable identifiers). The overall
document itself may not be a JSON Schema, but it may contain JSON Schemas internally. Referenceable
entities may or may not be JSON Schemas. As long as the C<traverse> method is implemented and the
C<$state> object is respected, any other functionality may be contained by this subclass.

To date, there is one subclass of JSON::Schema::Modern::Document:
L<JSON::Schema::Modern::Document::OpenAPI>, which contains entities of type C<schema> as well as
others (e.g. C<request-body>, C<response>, C<path-item>, etc). An object of this class represents
one OpenAPI document, used by L<OpenAPI::Modern> to specify application APIs.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern>
* L<Mojo::JSON::Pointer>

=cut
