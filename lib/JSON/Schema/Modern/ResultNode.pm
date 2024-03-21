use strict;
use warnings;
package JSON::Schema::Modern::ResultNode;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Common code for nodes of a JSON::Schema::Modern::Result

our $VERSION = '0.583';

use 5.020;
use Moo::Role;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use Safe::Isa;
use Types::Standard qw(Str Undef InstanceOf);
use Types::Common::Numeric 'PositiveOrZeroInt';
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
  isa => InstanceOf['Mojo::URL'],
  coerce => sub { $_[0]->$_isa('Mojo::URL') ? $_[0] : Mojo::URL->new($_[0]) },
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

around BUILDARGS => sub ($orig, $class, @args) {
  # TODO: maybe need to support being passed an already-blessed object
  my $args = $class->$orig(@args);

  if (my $uri = delete $args->{_uri}) {
    # as if we did canonical_uri(..)->to_abs($state->{effective_base_uri} in E(..) or A(..)
    $uri = $uri->[0]->to_abs($uri->[1]);
    undef $uri if $uri eq '' and $args->{keyword_location} eq ''
      or ($uri->fragment // '') eq $args->{keyword_location} and $uri->clone->fragment(undef) eq '';
    $args->{absolute_keyword_location} = $uri if defined $uri;
  }

  return $args;
};

sub TO_JSON ($self) {
  my $thing = lcfirst((reverse split /::/, ref $self)[0]);
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

=for Pod::Coverage TO_JSON absolute_keyword_location depth dump instance_location keyword keyword_location

=head1 DESCRIPTION

This module is for internal use only.

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=pod
