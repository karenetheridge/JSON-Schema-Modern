use strict;
use warnings;
package JSON::Schema::Draft201909::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: (DEPRECATED) Internal utilities for JSON::Schema::Draft201909

our $VERSION = '0.128';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use JSON::Schema::Modern::Utilities;
use namespace::clean;
use Import::Into;

sub import {
  my ($self, @functions) = @_;
  my $target = caller;
  JSON::Schema::Modern::Utilities->import::into($target, @functions);
}

1;
__END__

=pod

=head1 DESCRIPTION

This module is deprecated in favour of L<JSON::Schema::Modern::Utilities>.

=cut
