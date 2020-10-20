use strict;
use warnings;
package JSON::Schema::Draft201909::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.016';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use Mojo::URL;
use Carp 'croak';
use Ref::Util 0.100 qw(is_plain_arrayref is_plain_hashref);
use List::Util 1.29 'pairs';
use Safe::Isa;
use Moo;
use strictures 2;
use MooX::TypeTiny;
use MooX::HandlesVia;
use Types::Standard qw(InstanceOf HashRef Str Dict);
use namespace::clean;

extends 'Mojo::JSON::Pointer';

has schema => (
  is => 'ro',
  required => 1,
);

has canonical_uri => (
  is => 'rwp',
  isa => InstanceOf['Mojo::URL'], # always fragmentless
  lazy => 1,
  default => sub { Mojo::URL->new },
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
);

has resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      canonical_uri => InstanceOf['Mojo::URL'],
      path => Str,  # always a json pointer, relative to the document root
    ]],
  handles_via => 'Hash',
  handles => {
    resource_index => 'elements',
    _add_resources => 'set',
    _get_resource => 'get',
    _remove_resource => 'delete',
    _resource_pairs => 'kv',
  },
  init_arg => undef,
  lazy => 1,
  default => sub { {} },
);

has canonical_uri_index => (
  is => 'bare',
  isa => HashRef[InstanceOf['Mojo::URL']],
  handles_via => 'Hash',
  handles => {
    _add_canonical_uri => 'set',
    _path_to_canonical_uri => 'get',
  },
  init_arg => undef,
  lazy => 1,
  default => sub { {} },
);

# for internal use only
has _serialized_schema => (
  is => 'rw',
  isa => Str,
  init_arg => undef,
);

around _add_resources => sub {
  my $orig = shift;
  my $self = shift;
  foreach my $pair (pairs @_) {
    my ($key, $value) = @$pair;
    if (my $existing = $self->_get_resource($key)) {
      croak 'uri "'.$key.'" conflicts with an existing schema resource'
        if $existing->{path} ne $value->{path}
          or $existing->{canonical_uri} ne $value->{canonical_uri};
    }

    # this will never happen, if we parsed $id correctly
    croak sprintf('a resource canonical uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($value->{canonical_uri}->fragment // '') =~ m{^[^/]};

    $self->$orig($key, $value);
    $self->_add_canonical_uri($value->{path}, $value->{canonical_uri});
  }
};

# shims for Mojo::JSON::Pointer
sub data { goto \&schema }
sub FOREIGNBUILDARGS { () }

sub BUILD {
  my $self = shift;

  croak 'canonical_uri cannot contain a fragment' if defined $self->canonical_uri->fragment;

  my $original_uri = $self->canonical_uri->clone;
  my $schema = $self->schema;
  my @identifiers = _traverse_for_identifiers($schema, '', $original_uri->clone);

  if (is_plain_hashref($self->schema) and my $id = $self->get('/$id')) {
    $self->_set_canonical_uri(Mojo::URL->new($id)) if $id ne $self->canonical_uri;
  }

  # make sure the root schema is always indexed against *something*.
  $self->_add_resources($original_uri => { path => '', canonical_uri => $self->canonical_uri })
    if (not "$original_uri" and $original_uri eq $self->canonical_uri)
      or "$original_uri";

  $self->_add_resources(@identifiers);
}

sub _traverse_for_identifiers {
  my ($data, $path, $canonical_uri) = @_;
  my @identifiers;
  if (is_plain_arrayref($data)) {
    return map
      __SUB__->($data->[$_], jsonp($path, $_),
        $canonical_uri->clone->fragment($canonical_uri->fragment.'/'.$_)),
      0 .. $#{$data};
  }
  elsif (is_plain_hashref($data)) {
    if (exists $data->{'$id'} and JSON::Schema::Draft201909->_is_type('string', $data->{'$id'})) {
      my $uri = Mojo::URL->new($data->{'$id'});
      if (not length $uri->fragment) {
        $canonical_uri = $uri->is_abs ? $uri : $uri->to_abs($canonical_uri);
        $canonical_uri->fragment(undef);
        push @identifiers, $canonical_uri => { path => $path, canonical_uri => $canonical_uri->clone };
      }
    }
    if (exists $data->{'$anchor'} and JSON::Schema::Draft201909->_is_type('string', $data->{'$anchor'})
        and $data->{'$anchor'} =~ /^[A-Za-z][A-Za-z0-9_:.-]+$/) {
      my $uri = Mojo::URL->new->to_abs($canonical_uri)->fragment($data->{'$anchor'});
      push @identifiers, $uri => { path => $path, canonical_uri => $canonical_uri->clone };
    }

    return
      @identifiers,
      map
        __SUB__->($data->{$_}, jsonp($path, $_),
          $canonical_uri->clone->fragment(jsonp($canonical_uri->fragment, $_))),
        keys %$data;
  }

  return ();
}

# shorthand for creating and appending json pointers
use namespace::clean 'jsonp';
sub jsonp {
  return join('/', (shift // ''), map s/~/~0/gr =~ s!/!~1!gr, @_);
}

1;
__END__

=pod

=for :header
=for stopwords subschema

=head1 SYNOPSIS

    use JSON::Schema::Draft201909::Document;

    my $document = JSON::Schema::Draft201909::Document->new(
      canonical_uri => 'https://example.com/v1/schema',
      schema => $schema,
    );
    my $foo_definition = $document->get('/$defs/foo');
    my %resource_index = $document->resource_index;

=head1 DESCRIPTION

This class represents one JSON Schema document, to be used by L<JSON::Schema::Draft201909>.

=head1 ATTRIBUTES

=head2 schema

The actual raw data representing the schema.

=head2 canonical_uri

When passed in during construction, this represents the initial URI by which the document should
be known. It is overwritten with the root schema's C<$id> property when one exists, and as such
can be considered the canonical URI for the document as a whole.

=head2 resource_index

An index of URIs to subschemas (json path to reach the location, and the canonical URI of that
location) for all identifiable subschemas found in the document. An entry for URI C<''> is added
only when no other suitable identifier can be found for the root schema.

This attribute should only be used by L<JSON::Schema::Draft201909> and not intended for use
externally (you should use the public accessors in L<JSON::Schema::Draft201909> instead).

=head2 canonical_uri_index

An index of json paths (from the document root) to canonical URIs. This is the inversion of
L</resource_index> and is constructed as that is built up.

=head1 METHODS

=for Pod::Coverage BUILD FOREIGNBUILDARGS

=head2 contains

Check if L</"schema"> contains a value that can be identified with the given JSON Pointer.
See L<Mojo::JSON::Pointer/contains>.

=head2 get

Extract value from L</"schema"> identified by the given JSON Pointer.
See L<Mojo::JSON::Pointer/get>.

=cut
