use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Validation;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: (DEPRECATED) Implementation of the JSON Schema Draft 2019-09 Validation vocabulary

our $VERSION = '0.128';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use Moo;
use namespace::clean;

extends 'JSON::Schema::Modern::Vocabulary::Validation';

1;
__END__

=pod

=head1 DESCRIPTION

This module is deprecated in favour of L<JSON::Schema::Modern::Vocabulary::Validation>.

=cut
