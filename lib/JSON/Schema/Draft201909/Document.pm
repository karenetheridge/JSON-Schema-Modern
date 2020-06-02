use strict;
use warnings;
package JSON::Schema::Draft201909::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.003';

no if "$]" >= 5.031009, feature => 'indirect';
use feature 'current_sub';
use Mojo::URL;
use Carp 'croak';
use JSON::MaybeXS 1.004001 'is_bool';
use List::Util 1.29 'pairs';
use Moo;
use MooX::TypeTiny;
use MooX::HandlesVia;
use Types::Standard qw(InstanceOf HashRef Str Dict HasMethods);
use namespace::clean;

extends 'Mojo::JSON::Pointer';

has schema => (
  is => 'ro',
  required => 1,
);

has canonical_uri => (
  is => 'rwp',
  isa => InstanceOf['Mojo::URL'],
  lazy => 1,
  default => sub { Mojo::URL->new },
);

has resource_index => (
  is => 'bare',
  isa => HashRef[Dict[
      canonical_uri => InstanceOf['Mojo::URL'], # always fragmentless
      path => Str,  # always a json pointer
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

before _add_resources => sub {
  my $self = shift;
  foreach my $pair (pairs @_) {
    my ($key, $value) = @$pair;
    if (my $existing = $self->_get_resource($key)) {
      croak 'a schema resource is already indexed with uri "'.$key.'"'
        if $existing->{path} != $value->{path}
          or $existing->{canonical_uri} ne $value->{canonical_uri};
    }

    croak sprintf('canonical_uri cannot contain a plain-name fragment (%s)', $value->{canonical_uri})
      if ($value->{canonical_uri}->fragment // '') =~ m{^[^/]};
  }
};

# shims for Mojo::JSON::Pointer
sub data { goto \&schema }
sub FOREIGNBUILDARGS { () }

sub BUILD {
  my $self = shift;

  croak 'canonical_uri cannot contain a fragment' if defined $self->canonical_uri->fragment;

  my $original_uri = $self->canonical_uri->clone;
  my $schema = $self->data;
  my %identifiers = _traverse_for_identifiers($schema, $original_uri);

  if (ref $self->schema eq 'HASH' and my $id = $self->get('/$id')) {
    $self->_set_canonical_uri(Mojo::URL->new($id)) if $id ne $self->canonical_uri;
  }

  # make sure the root schema is always indexed against *something*.
  $identifiers{$original_uri} = { path => '', canonical_uri => $self->canonical_uri }
    if (not "$original_uri" and $original_uri eq $self->canonical_uri)
      or ("$original_uri" and not exists $identifiers{$original_uri});

  $self->_add_resources(%identifiers);
}

sub _traverse_for_identifiers {
  my ($data, $canonical_uri) = @_;
  my $uri_fragment = $canonical_uri->fragment // '';
  my %identifiers;
  if (ref $data eq 'ARRAY') {
    return map
      __SUB__->($data->[$_], $canonical_uri->clone->fragment($uri_fragment.'/'.$_)),
      0 .. $#{$data};
  }
  elsif (ref $data eq 'HASH') {
    if (exists $data->{'$id'} and _is_type(undef, 'string', $data->{'$id'})) {
      $canonical_uri = Mojo::URL->new($data->{'$id'})->base($canonical_uri)->to_abs;
      # this might not be a real $id... wait for it to be encountered at runtime before dying
      if (not length $canonical_uri->fragment) {
        $canonical_uri->fragment(undef);
        $identifiers{$canonical_uri} = { path => $uri_fragment, canonical_uri => $canonical_uri };
      };
    }
    if (exists $data->{'$anchor'} and _is_type(undef, 'string', $data->{'$anchor'})) {
      # we cannot change the canonical uri, or we won't be able to properly identify
      # paths within this resource
      my $uri = Mojo::URL->new->base($canonical_uri)->to_abs->fragment($data->{'$anchor'});
      $identifiers{$uri} = { path => $uri_fragment, canonical_uri => $canonical_uri };
    }

    return
      %identifiers,
      map __SUB__->($data->{$_}, $canonical_uri->clone->fragment($uri_fragment.'/'.$_)), keys %$data;
  }

  return ();
}

# copied from JSON::Schema::Draft201909 (ugh)
sub _is_type {
  my (undef, $type, $value) = @_;

  if ($type eq 'null') {
    return !(defined $value);
  }
  if ($type eq 'boolean') {
    return is_bool($value);
  }
  if ($type eq 'object') {
    return ref $value eq 'HASH';
  }
  if ($type eq 'array') {
    return ref $value eq 'ARRAY';
  }

  if ($type eq 'string' or $type eq 'number' or $type eq 'integer') {
    return 0 if not defined $value or ref $value;
    my $flags = B::svref_2object(\$value)->FLAGS;

    if ($type eq 'string') {
      return $flags & B::SVf_POK && !($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'number') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK));
    }

    if ($type eq 'integer') {
      return !($flags & B::SVf_POK) && ($flags & (B::SVf_IOK | B::SVf_NOK))
        && int($value) == $value;
    }
  }

  croak sprintf('unknown type "%s"', $type);
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

=head2 data

The actual raw data representing the schema.

=head2 canonical_uri

When passed in during construction, this represents the initial URI by which the document should
be known. It is overwritten with the root schema's C<$id> property when one exists, and as such
can be considered the canonical URI for the document as a whole.

=head2 resource_index

An index of URIs to subschemas (json path to reach the location, and the canonical uri of that
location) for all identifiable subschemas found in the document. An entry for URI C<''> is added
only when no other suitable identifier can be found for the root schema.

This attribute should only be used by L<JSON::Schema::Draft201909> and not intended for use
externally (you should use the public accessors in L<JSON::Schema::Draft201909> instead).

=head1 METHODS

=for Pod::Coverage BUILD FOREIGNBUILDARGS

=head2 contains

See L<Mojo::JSON::Pointer/contains>.

=head2 get

See L<Mojo::JSON::Pointer/get>.

=cut
