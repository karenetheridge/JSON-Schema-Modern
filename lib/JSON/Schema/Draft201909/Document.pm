use strict;
use warnings;
package JSON::Schema::Draft201909::Document;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Contains a single error from a JSON Schema evaluation

our $VERSION = '0.001';

no if "$]" >= 5.031009, feature => 'indirect';
use Moo;
use MooX::TypeTiny;
use Types::Standard 'Str';
use Mojo::JSON::Pointer;  # or do we inherit from this?   we could just defer 'get' and '_pointer' to that class.
use namespace::clean;


has canonical_uri => (
  is => 'rw',
  isa => InstanceOf['Mojo::URL'],
);

# during construction, we might instantiate like this:
# ->new(canonical_uri => 'http://...', data => $data)
# or
# my $uri = Mojo::URL->new("foo/bar/baz.json")->base($js->base_uri);
# my $doc = ::Document->new(canonical_uri => $uri, data => ...);
# $js->add_to_index($uri => $doc);
# $js->add_to_index($_ => $doc) foreach $doc->caonical_uri, $doc->all_ids;
# (in ::Document::BUILD, we examine $self->data->{'$id'} to get the *real* canonical URI
#   and also traverse the document looking for all other identifiers.)


# TODO: when we start looking at the $schema property
#has metaschema => (
#  is => 'lazy',
#  isa => InstanceOf['JSON::Schema::Draft201909::Document'],
#  weak_ref => 1,
#);

# $js->add_schema('https://json-schema.org/draft/2019-09/schema')
#   -> it's in our sharedir list, so load the document from disk
#   (otherwise, we need the raw data)
# my $doc = ::Document->new(data => $schema_data);
# my $canonical_uri = $doc->canonical_uri;  # -> top level $id is examined for its uri.
#   # if none is found, we use $master->base_uri.
#   # (test: we had a schema document already with this uri - error! or maybe we should allow this if we had no recorded $ids from that document.))
# my @ids = $doc->ids;
#   # triggers a full scan of the document looking for anchors and ids.
#   # this should return back (either? both) the json pointer to the schema resource and/or the memory reference to the location
#   # and we record this next to an absolute URI pointing to that location.

1;
__END__

=pod

=cut

__END__

# to scan a document and record all the values found for a particular key:
# need to record the path (json pointer) we found it at, in case it later proves to be
# invalid and we need to nullify it?
#
# do we need to modify our _eval_keyword_* subs so they don't actually perform validation,
# but just traverse the tree and do what was requested?
# we could control this with $state->{validate} = 0.

# returns all hash values with the name '$key'.
use feature 'current_sub';
sub _find_all_key ($data, $key) {
    if (ref $data eq 'ARRAY') {
        return map __SUB__->($_, $key), $data->@*;
    }
    elsif (ref $data eq 'HASH') {
        return
            exists $data->{$key} ? $data->{$key} : (),
            map __SUB__->($_, $key), values $data->%*;
    }
    return;
}

