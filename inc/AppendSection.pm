# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
package inc::AppendSection;

use Moose;
extends 'Pod::Weaver::Section::AllowOverride';

# Warning: dirty hack ahead!
# This chicanery is to allow for [GenerateSection] followed by [AllowOverride],
# where the intention is the content added by that GenerateSection should be appended to the
# original section that was generated by a weaver bundle (as opposed to appearing in the literal
# .pm file).
# This plugin does its initial work (to find the node to pluck out and later append) in
# transform_document, and the Transformer phase is run before GenerateSection's weave_section
# has a chance to create the node.
# So this hack just runs the plugin's transform_document again if nothing was found the first time.
# Because it picks the first node it finds (to relocate to the location of the second match), we
# will now run GenerateSection first, before calling the weaver bundle.

# All of this really should be replaced by a new plugin called something like AppendSection,
# which subclasses GenerateSection to add the options provided by AllowOverride, letting us
# append (or prepend) to an existing section rather than generating a new one.

before weave_section => sub {
  my ($self, $document, $input) = @_;

  # if we haven't already found a matching section, look again now
  $self->transform_document($document) if not $self->_override_with;
};

1;
