use strict;
use warnings;
package JSON::Schema::Modern::ResultNode;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Common code for nodes of a JSON::Schema::Modern::Result

our $VERSION = '0.596';

use 5.020;
use Moo::Role;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Safe::Isa;
use Types::Standard qw(Str Undef InstanceOf);
use Types::Common::Numeric 'PositiveOrZeroInt';
use JSON::Schema::Modern::Utilities 'jsonp';
use namespace::clean;

has [qw(
  instance_location
  keyword_location
)] => (
  is => 'ro',
  isa => Str,
  required => 1,
);

has absolute_keyword_location => (
  is => 'ro',
  isa => InstanceOf['Mojo::URL']|Undef,
  lazy => 1,
  default => sub ($self) {
    # _uri contains data as populated from A() and E():
    # [ $state->{initial_schema_uri}, $state->{schema_path}, @extra_path, $state->{effective_base_uri} ]
    # we do the equivalent of:
    # canonical_uri($state, @extra_path)->to_abs($state->{effective_base_uri});
    if (my $uri_bits = delete $self->{_uri}) {
      my $effective_base_uri = pop @$uri_bits;
      my ($initial_schema_uri, $schema_path, @extra_path) = @$uri_bits;

      return $initial_schema_uri if not @extra_path and not length($schema_path);
      my $uri = $initial_schema_uri->clone;
      my $fragment = ($uri->fragment//'').(@extra_path ? jsonp($schema_path, @extra_path) : $schema_path);
      undef $fragment if not length($fragment);
      $uri->fragment($fragment);

      $uri = $uri->to_abs($effective_base_uri);

      undef $uri if $uri eq '' and $self->{keyword_location} eq ''
        or ($uri->fragment // '') eq $self->{keyword_location} and $uri->clone->fragment(undef) eq '';
      return $uri;
    }

    return;
  },
);

has keyword => (
  is => 'ro',
  isa => Str|Undef,
  required => 1,
);

has depth => (
  is => 'ro',
  isa => PositiveOrZeroInt,
  required => 1,
);

# TODO: maybe need to support being passed an already-blessed object

sub BUILD ($self, $args) {
  $self->{_uri} = $args->{_uri} if exists $args->{_uri};
}

sub TO_JSON ($self) {
  my $thing = $self->__thing;  # annotation or error

  return +{
    # note that locations are JSON pointers, not uri fragments!
    instanceLocation => $self->instance_location,
    keywordLocation => $self->keyword_location,
    !defined($self->absolute_keyword_location) ? ()
      : ( absoluteKeywordLocation => $self->absolute_keyword_location->to_string ),
    $thing => $self->$thing,  # TODO: allow localization in error message
  };
}

sub dump ($self) {
  my $encoder = JSON::Schema::Modern::_JSON_BACKEND()->new
    ->utf8(0)
    ->convert_blessed(1)
    ->canonical(1)
    ->indent(1)
    ->space_after(1);
  $encoder->indent_length(2) if $encoder->can('indent_length');
  $encoder->encode($self);
}

1;
__END__

=pod

=head1 SYNOPSIS

  use Moo;
  with JSON::Schema::Modern::ResultNode;

=for Pod::Coverage BUILD TO_JSON absolute_keyword_location depth dump instance_location keyword keyword_location

=head1 DESCRIPTION

This module is for internal use only.

=pod
