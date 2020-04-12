use strict;
use warnings;
package JSON::Schema::Draft201909::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use experimental 'signatures';
use Moo;
use Types::Standard qw(Ref Bool);

# has canonical_uri - section 8.2.1 - uri doc was found at; if base $id is present, that overrides this
#   (but we then shift the initial uri into 'ids')
# has ids ... TBD. possibly 'uris' or 'refs'.
# has anchors - all plain-name fragments ($anchor keywords) found in the document, with a pointer to that
#      part of the data.

has data => ( is => 'ro' isa => Ref );

#has scanned => ( is => 'rw', isa => Bool );  # have we traversed the doc yet, looking for $refs, $id etc?

# has refs -- index of schema_location (json pointer) => Ref of metaschema so referenced (may be in this or
# another document). should be weakreffed.

# has ids -- index of schema_location (json pointer) => Ref where $id or $anchor appears

# probably need a weakref'd link back to main object, e.g. for loading additional documents and storing
# them in additional ::Document objects.

sub BUILD ($self) {
  # scan for top level '$id' and store in canonical_uri.
  # if there was a canonical_uri provided, shift that into 'ids'.

  # TODO: fetch document at '$schema' key and handle '$vocabulary' keyword.
  # use this to populate 'vacabulary' attribute, which alters evaluation behaviour.
}

sub collect_identifiers ($self) {
  # traverse document, looking for $schema, $id, $anchor
  # they need to be recorded somehow in this object
  # and also returned back to the main object upon request
}

# maybe need to move evaluate, _evaluate logic into here
# but then we need to carefully track what document we are in the middle of executing
# at any time so we can make sure to call evaluate on the right object
# e.g. if we switch to a Draft07 object, that implementation will ignore $anchor

1;
__END__

=pod

=head1 SYNOPSIS

    use JSON::Schema::Draft2019::Document;

    ...

=head1 DESCRIPTION

This class represents one JSON Schema document, to be used by L<JSON::Schema::Draft2019>.

=head1 ATTRIBUTES

=head2 data

The actual raw data representing the schema.

=cut
