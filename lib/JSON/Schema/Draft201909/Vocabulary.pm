use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: (DEPRECATED) Base role for JSON Schema vocabulary classes

our $VERSION = '0.128';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use Moo::Role;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

1;
__END__

=pod

=head1 DESCRIPTION

This module is deprecated in favour of L<JSON::Schema::Modern::Vocabulary>.

=cut
