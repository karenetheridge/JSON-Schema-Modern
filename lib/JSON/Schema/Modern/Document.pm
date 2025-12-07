use strict;
use warnings;
package JSON::Schema::Modern::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.629';

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
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use Mojo::URL;
use Carp 'croak';
use List::Util 1.29 'pairs';
use builtin::compat qw(refaddr blessed);
use Safe::Isa 1.000008;
use MooX::TypeTiny;
use Types::Standard 1.016003 qw(InstanceOf HashRef Str Map Dict ArrayRef Enum ClassName Undef Slurpy Optional Bool);
use Types::Common::Numeric 'PositiveOrZeroInt';
use JSON::Schema::Modern::Utilities qw(json_pointer_type canonical_uri_type);
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

# this is also known as the retrieval uri in the OpenAPI specification
has original_uri => (
  is => 'rwp',
  isa => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
  init_arg => undef,
);
*retrieval_uri = \&original_uri;

has metaschema_uri => (
  is => 'rwp',
  isa => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
  predicate => '_has_metaschema_uri',
  # default not defined here, but might be defined in a subclass
);

# "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.3.5
has resource_index => (
  is => 'bare',
  isa => Map[my $resource_key_type = Str->where('!/#/'), my $resource_type = Dict[
      canonical_uri => (InstanceOf['Mojo::URL'])->where(q{not defined $_->fragment}),
      path => json_pointer_type,  # JSON pointer relative to the document root
      specification_version => Enum[qw(draft4 draft6 draft7 draft2019-09 draft2020-12)],
      # the vocabularies used when evaluating instance data against schema
      vocabularies => ArrayRef[ClassName->where(q{$_->DOES('JSON::Schema::Modern::Vocabulary')})],
      anchors => Optional[HashRef[Dict[
        canonical_uri => canonical_uri_type,  # equivalent uri with json pointer fragment
        path => json_pointer_type,  # JSON pointer relative to the document root
        dynamic => Optional[Bool],
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
  isa => Map[json_pointer_type, PositiveOrZeroInt],
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
  ($self->__entities)[ $self->_entities->{$location} ] // croak "missing mapping for ", $self->_entities->{$location};
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
  # note! not a clone! Please don't change canonical_uri in-place.
  $self->_set_original_uri($self->canonical_uri);

  # this should extract all identifiers and entities, and set canonical_uri, metaschema_uri
  my $state = $self->traverse(
    $args->{evaluator} // JSON::Schema::Modern->new,
    $args->{specification_version} ? +{ $args->%{specification_version} } : (),
  );

  if ($state->{errors}->@*) {
    $self->_set_errors($state->{errors});
    return;
  }

  my $seen_root;
  foreach my $key (keys $state->{identifiers}->%*) {
    my $value = $state->{identifiers}{$key};
    $self->_add_resource($key => $value);

    # we're adding a non-anchor entry for the document root
    ++$seen_root if $value->{path} eq '';
  }

  # we only index the original uri if nothing in the schema itself identified a root resource:
  # otherwise the top of the document would be unreferenceable.
  $self->_add_resource($self->original_uri.'' => {
      path => '',
      canonical_uri => $self->canonical_uri,
      $state->%{qw(specification_version vocabularies)},
    })
  if not $seen_root;
}

# a subclass's method will override this one
sub traverse ($self, $evaluator, $config_override = {}) {
  die 'wrong class - use JSON::Schema::Modern::Document::OpenAPI instead'
    if ref $self->schema eq 'HASH' and exists $self->schema->{openapi};

  my $original_uri = $self->original_uri;

  my $state = $evaluator->traverse($self->schema,
    {
      initial_schema_uri => $original_uri,
      $self->_has_metaschema_uri ? (metaschema_uri => $self->metaschema_uri) : (),
      %$config_override,
    }
  );

  die 'original_uri has changed' if $self->original_uri ne $original_uri
    or refaddr($self->original_uri) != refaddr($original_uri);

  # if the document identified a canonical uri for itself via '$id', or metaschema uri via '$schema',
  # they overrides the initial values
  # Note that subclasses of this class may choose to identify these values in a different way
  # (e.g. "$self" in OpenAPI)
  $self->_set_canonical_uri($state->{initial_schema_uri});
  $self->_set_metaschema_uri($state->{metaschema_uri});

  $self->_add_entity_location($_, 'schema') foreach $state->{subschemas}->@*;

  return $state;
}

sub validate ($class, @args) {
  croak 'bad argument list' if blessed($args[0]);

  my $args = $class->Moo::Object::BUILDARGS(@args);
  my $document = blessed($class) ? $class : $class->new($args);

  my $doc_result = JSON::Schema::Modern::Result->new(errors => [ $document->errors ]);

  # ideally, the traverse phase run during document construction should have found all errors that a
  # simple metaschema evaluation would reveal, but we'll do both just to make sure.
  my $evaluator = $args->{evaluator} // JSON::Schema::Modern->new(validate_formats => 1);
  my $eval_result = $evaluator->evaluate($document->schema, $document->metaschema_uri);

  return $doc_result & $eval_result;
}

# callback hook for Sereal::Encoder
sub FREEZE ($self, $serializer) { +{ %$self } }

# callback hook for Sereal::Decoder
sub THAW ($class, $serializer, $data) {
  delete $data->{evaluator};

  my $self = bless($data, $class);

  foreach my $attr (qw(schema _entities)) {
    croak "serialization missing attribute '$attr' on document for identifier '$self->{canonical_uri}': perhaps your serialized data was produced for an older version of $class?"
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
      schema => $schema,
    );
    my $foo_definition = $document->get('/$defs/foo');
    my %resource_index = $document->resource_index;
    my $metaschema_uri = $document->metaschema_uri;

=head1 DESCRIPTION

This class represents one JSON Schema document, to be used by L<JSON::Schema::Modern>.

=head1 CONSTRUCTOR ARGUMENTS

Unless otherwise noted, these are also available as read-only accessors.

=head2 schema

The actual raw data representing the schema. Required.

=head2 canonical_uri

As a constructor value, represents the initial URI by which the document should be known, or a base
URI to use to determine that value. The URI found in the root schema's C<$id> keyword is resolved
against this URI to determine the final value, which is then stored in this accessor. As such, it
can be considered the canonical URI for the document as a whole, from which subsequent C<$ref>
keywords are resolved.

The original passed-in value is saved in L</original_uri>.

=head2 metaschema_uri

=for stopwords metaschema schemas

Sets the metaschema that is used to describe the document (or more specifically, any JSON Schemas
contained within the document), which determines the
specification version and vocabularies used during evaluation.
Does not override any C<$schema> keyword actually present in the schema document, and normally you
should use this keyword instead.

=head2 specification_version

Only a constructor argument, not an accessor method.

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

A L<JSON::Schema::Modern> object. Optional, unless custom metaschemas are used (see notes below
under L</validate>).

This argument is not preserved by the constructor, so it is not available as an accessor.

=head1 METHODS

=for Pod::Coverage FOREIGNBUILDARGS BUILDARGS BUILD FREEZE THAW traverse has_errors path_to_resource
resource_pairs get_entity_at_location get_entity_locations retrieval_uri

=head2 errors

Returns a list of L<JSON::Schema::Modern::Error> objects that resulted when the schema document was
originally parsed. (If a syntax error occurred, usually there will be just one error, as parse
errors halt the parsing process.) Documents with errors cannot be used for evaluation.

=head2 original_uri

Returns the original value of L</canonical_uri> that was passed to the document constructor (which
C<$id> keywords within the document would have been resolved against, if they were not already
absolute). Some subclasses may make use of this value for resolving URIs when matching HTTP requests
at runtime.

This URI is B<not> added to the document's resource index, so if you want the document to be
addressable at this location you must add it to the evaluator yourself with the two-argument form of
L<JSON::Schema::Modern/add_document>.

Read-only.

=head2 resource_index

An index of URIs to subschemas (JSON pointer to reach the location, and the canonical URI of that
location) for all identifiable subschemas found in the document. An entry for URI C<''> is added
only when no other suitable identifier can be found for the root schema.

This attribute should only be used by L<JSON::Schema::Modern> and not intended for use
externally (you should use the public accessors in L<JSON::Schema::Modern> instead).

When called as a method, returns the flattened list of tuples (path, uri). You can also use
C<resource_pairs> which returns a list of tuples as arrayrefs.

=head2 contains

Check if L</"schema"> contains a value that can be identified with the given JSON Pointer.
See L<Mojo::JSON::Pointer/contains>.

=head2 get

Extract value from L</"schema"> identified by the given JSON Pointer.
See L<Mojo::JSON::Pointer/get>.

=head2 validate

  $result = JSON::Schema::Modern::Document->validate(<normal constructor arguments>);

Constructs the document object, and then performs a further sanity check by evaluating the document
against its metaschema. (See L<JSON::Schema::Modern/evaluate>.) This is preferred to simply
attempting to add the document to the evaluator with L<JSON::Schema::Modern/add_schema> in cases
where the document's sanity is not known, as that method will die if errors are encountered.

As with calling C<new>, if the document's metaschema is one of the core bundled metaschemas (see
L<JSON::Schema::Modern/BUNDLED META-SCHEMAS>), the C<$evaluator> argument is optional, as these
metaschemas are available to all evaluator instances; otherwise (you are using a custom metaschema),
you must provide the same evaluator instance as would be used to construct the document object.

Returns a L<JSON::Schema::Modern::Result> object containing the final result.

See also L<JSON::Schema::Modern/validate_schema>, which is nearly equivalent but only works for
JSON Schemas, not any potential subclass of JSON::Schema::Modern::Document.

=head2 TO_JSON

Returns a data structure suitable for serialization. See L</schema>.

=head1 SUBCLASSING

=for stopwords OpenAPI referenceable

This class can be subclassed to describe documents of other types, which follow the same basic model
(has a document-level identifier and may contain internal referenceable identifiers). The overall
document itself may not be a JSON Schema, but it may contain JSON Schemas internally. Referenceable
entities may or may not be JSON Schemas. As long as the C<traverse> method is implemented and the
C<$state> object is respected, any other functionality may be contained by this subclass. The
C<traverse> method is responsible for finding any identifiers within the document, setting
L</canonical_uri> and L</metaschema_uri>, and finding any C<$ref>abble entities within the document.

To date, there is one subclass of JSON::Schema::Modern::Document:
L<JSON::Schema::Modern::Document::OpenAPI>, which contains entities of type C<schema> as well as
others (e.g. C<request-body>, C<response>, C<path-item>, etc). An object of this class represents
one OpenAPI document, used by L<OpenAPI::Modern> to specify application APIs.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern>
* L<Mojo::JSON::Pointer>

=cut
