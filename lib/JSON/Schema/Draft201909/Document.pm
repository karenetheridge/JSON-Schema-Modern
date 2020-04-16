use strict;
use warnings;
package JSON::Schema::Draft201909::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: One JSON Schema document

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use experimental 'signatures';
use Moo;
use MooX::TypeTiny;
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

# scan for top level '$schema' and make sure it's what we expect. if not, either throw exception or try to construct one of the other ::DraftXX::Document objects.

  # scan for top level '$id' and store in canonical_uri.
  # if there was a canonical_uri provided, shift that into 'ids'.

  # TODO: fetch document at '$schema' key and handle '$vocabulary' keyword.
  # use this to populate 'vacabulary' attribute, which alters evaluation behaviour.



}


sub collect_identifiers ($self) {
  # traverse document, looking for $id, $anchor
  # they need to be recorded somehow in this object:
  #    absolute uri => [ document object, json pointer ]
  # and also returned back to the main object upon request

#    extract_identifiers: scan for all '$id', '$anchor':
#        record them locally as absolute uris with pointer to their document locations (master caller object will then ask for them to add to its master index)
}

sub extract_references ($self ) {
# scan for all '$ref' (not '$recursiveRef':we need to look for those and remember them as we traverse)
# and record them locally as unresolved destinations for the master caller object to then go load fragment handling:
  # if the fragment is empty or starts with '/', it is a json pointer; otherwise it is an anchor
  # If the evaluation logic resides in the ::Document class, then we definitely need a reference back to the master object, because that's where the index of all known $refs (to other documents) resides, as well as the logic for loading new documents. the ::Result object also needs an index back to the schema used for evaluation, as well as a reference to the instance data. This would be used for generating the various output formats like detailed and verbose. strict mode should also flag the presence of keywords that are not supported by the indicated $vocabularies (nearly the same as "assume additionalProperties:false on everything")

}


# maybe need to move evaluate, _evaluate logic into here
# but then we need to carefully track what document we are in the middle of executing
# at any time so we can make sure to call evaluate on the right object
# e.g. if we switch to a Draft07 object, that implementation will ignore $anchor

# this object should be serializable - Sereal, Storable etc
# for easy re-loading and sharing in an application.
# then a JSON::Schema::Draft201909 object can just add pre-constructed Document objects
# to itself for very fast loading.

1;
__END__

=pod

=head1 SYNOPSIS

    use JSON::Schema::Draft201909::Document;

    ...

=head1 DESCRIPTION

This class represents one JSON Schema document, to be used by L<JSON::Schema::Draft201909>.

=head1 ATTRIBUTES

=head2 data

The actual raw data representing the schema.

=cut
