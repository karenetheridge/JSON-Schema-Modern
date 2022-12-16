use strict;
use warnings;
package JSON::Schema::Modern::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.560';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
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
use MooX::HandlesVia;
use Types::Standard 1.016003 qw(InstanceOf HashRef Str Dict ArrayRef Enum ClassName Undef Slurpy);
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
  isa => InstanceOf['Mojo::URL'],
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

has evaluator => (
  is => 'rwp',
  isa => InstanceOf['JSON::Schema::Modern'],
  weak_ref => 1,
);

# "A JSON Schema resource is a schema which is canonically identified by an absolute URI."
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.3.5
has resource_index => (
  is => 'bare',
  isa => HashRef[my $resource_type = Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,  # always a JSON pointer, relative to the document root
      specification_version => Str, # not an Enum due to module load ordering
      # the vocabularies used when evaluating instance data against schema
      vocabularies => ArrayRef[ClassName->where(q{$_->DOES('JSON::Schema::Modern::Vocabulary')})],
      configs => HashRef,
      Slurpy[HashRef[Undef]],  # no other fields allowed
    ]],
  handles_via => 'Hash',
  handles => {
    resource_index => 'elements',
    resource_pairs => 'kv',
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _canonical_resources => 'values',
  },
  init_arg => undef,
  lazy => 1,
  default => sub { {} },
);

has _path_to_resource => (
  is => 'bare',
  isa => HashRef[$resource_type],
  handles_via => 'Hash',
  handles => {
    path_to_resource => 'get',
  },
  init_arg => undef,
  lazy => 1,
  default => sub { +{ map +($_->{path} => $_), shift->_canonical_resources } },
);

# for internal use only
has _serialized_schema => (
  is => 'rw',
  isa => Str,
  init_arg => undef,
);

has errors => (
  is => 'bare',
  handles_via => 'Array',
  handles => {
    errors => 'elements',
    has_errors => 'count',
  },
  writer => '_set_errors',
  isa => ArrayRef[InstanceOf['JSON::Schema::Modern::Error']],
  lazy => 1,
  default => sub { [] },
);

around _add_resources => sub {
  my $orig = shift;
  my $self = shift;

  foreach my $pair (pairs @_) {
    my ($key, $value) = @$pair;

    $resource_type->($value); # check type of hash value against Dict

    if (my $existing = $self->_get_resource($key)) {
      croak 'uri "'.$key.'" conflicts with an existing schema resource'
        if $existing->{path} ne $value->{path}
          or $existing->{canonical_uri} ne $value->{canonical_uri}
          or $existing->{specification_version} ne $value->{specification_version};
    }

    # this will never happen, if we parsed $id correctly
    croak sprintf('a resource canonical uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($value->{canonical_uri}->fragment // '') =~ m{^[^/]};

    $self->$orig($key, $value);
  }
};

# shims for Mojo::JSON::Pointer
sub data { shift->schema(@_) }
sub FOREIGNBUILDARGS { () }

# for JSON serializers
sub TO_JSON { shift->schema }

sub BUILD ($self, $args) {
  my $original_uri = $self->canonical_uri->clone;
  my $state = $self->traverse($self->evaluator // JSON::Schema::Modern->new);

  # if the schema identified a canonical uri for itself, it overrides the initial value
  $self->_set_canonical_uri($state->{initial_schema_uri}) if $state->{initial_schema_uri} ne $original_uri;

  if ($state->{errors}->@*) {
    foreach my $error ($state->{errors}->@*) {
      $error->mode('traverse') if not defined $error->mode;
    }

    $self->_set_errors($state->{errors});
    return;
  }

  # make sure the root schema is always indexed against *something*.
  $self->_add_resources($original_uri => {
      path => '',
      canonical_uri => $self->canonical_uri,
      specification_version => $state->{spec_version},
      vocabularies => $state->{vocabularies},
      configs => $state->{configs},
    })
    if (not "$original_uri" and $original_uri eq $self->canonical_uri)
      or "$original_uri";

  $self->_add_resources($state->{identifiers}->@*);
}

sub traverse ($self, $evaluator) {
  die 'wrong class - use JSON::Schema::Modern::Document::OpenAPI instead'
    if is_plain_hashref($self->schema) and exists $self->schema->{openapi};

  my $state = $evaluator->traverse($self->schema,
    {
      initial_schema_uri => $self->canonical_uri->clone,
      $self->metaschema_uri ? ( metaschema_uri => $self->metaschema_uri) : (),
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
be known. It is overwritten with the root schema's C<$id> property when one exists, and as such
can be considered the canonical URI for the document as a whole.

=head2 metaschema_uri

=for stopwords metaschema schemas

Sets the metaschema that is used to describe the document (or more specifically, any JSON Schemas
contained within the document), which determines the
specification version and vocabularies used during evaluation. Does not override any
C<$schema> keyword actually present in the schema document.

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

=for Pod::Coverage FOREIGNBUILDARGS BUILDARGS BUILD traverse

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

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern>
* L<Mojo::JSON::Pointer>

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
