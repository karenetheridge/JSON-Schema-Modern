use strict;
use warnings;
package JSON::Schema::Draft201909;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: (DEPRECATED) Validate data against a schema
# KEYWORDS: JSON Schema data validation structure specification

our $VERSION = '0.128';

use 5.016;  # for fc, unicode_strings features
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use strictures 2;
use Moo;
use namespace::clean;

extends 'JSON::Schema::Modern';

around BUILDARGS => sub {
  my ($orig, $class, @args) = @_;

  return $class->$orig(
    @args == 1 && ref $args[0] eq 'HASH' ? %{$args[0]} : @args,
    specification_version => 'draft2019-09',
  );
};

1;
__END__

=pod

=head1 DESCRIPTION

This module is deprecated in favour of L<JSON::Schema::Modern>. It is a simple subclass of that module,
adding C<< specification_version => 'draft2019-09' >> to the constructor call to allow existing code
to continue to work.

=for Pod::Coverage BUILDARGS

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern>
* L<https://json-schema.org>
* L<RFC8259: The JavaScript Object Notation (JSON) Data Interchange Format|https://tools.ietf.org/html/rfc8259>
* L<RFC3986: Uniform Resource Identifier (URI): Generic Syntax|https://tools.ietf.org/html/rfc3986>
* L<Test::JSON::Schema::Acceptance>: contains the official JSON Schema test suite
* L<JSON::Schema::Tiny>: a more minimal implementation of the specification, with fewer dependencies
* L<https://json-schema.org/draft/2019-09/release-notes.html>
* L<Understanding JSON Schema|https://json-schema.org/understanding-json-schema>: tutorial-focused documentation

=cut
