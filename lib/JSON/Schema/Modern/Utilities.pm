use strict;
use warnings;
package JSON::Schema::Modern::Utilities;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Internal utilities for JSON::Schema::Modern

our $VERSION = '0.640';

use 5.020;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
use if "$]" < 5.025002, experimental => 'lexical_subs';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use B;
use Carp qw(carp croak);
use builtin::compat qw(blessed created_as_number);
use Scalar::Util 'looks_like_number';
use if "$]" < 5.041010, 'List::Util' => 'any';
use if "$]" >= 5.041010, experimental => 'keyword_any';
use Clone 'clone';
use Feature::Compat::Try;
use Mojo::JSON ();
use Mojo::JSON::Pointer ();
use JSON::PP ();
use Types::Standard qw(Str InstanceOf Enum);
use Mojo::File 'path';
use namespace::clean;

use Exporter 'import';

our @EXPORT_OK = qw(
  is_type
  get_type
  is_bool
  is_schema
  is_bignum
  is_equal
  is_elements_unique
  jsonp
  unjsonp
  jsonp_get
  jsonp_elements
  jsonp_set
  local_annotations
  canonical_uri
  E
  A
  abort
  assert_keyword_exists
  assert_keyword_type
  assert_pattern
  assert_uri_reference
  assert_uri
  annotate_self
  sprintf_num
  true
  false
  json_pointer_type
  canonical_uri_type
  core_types_type
  core_formats_type
  register_schema
  load_cached_document
  add_media_type
  delete_media_type
  decode_media_type
  encode_media_type
  match_media_type
);

use constant HAVE_BUILTIN => "$]" >= 5.035010;
use if HAVE_BUILTIN, experimental => 'builtin';

use constant _BUILTIN_BOOLS => 0;
use constant {
  _BUILTIN_BOOLS && HAVE_BUILTIN
      && Mojo::JSON::JSON_XS && eval { Cpanel::JSON::XS->VERSION(4.38); 1 }
    ? (true => builtin::true, false => builtin::false)
    : (true => JSON::PP::true, false => JSON::PP::false)
};

# Mojo::JSON::JSON_XS is false when the environment variable $MOJO_NO_JSON_XS is set
# and also checks if Cpanel::JSON::XS is installed.
# Mojo::JSON falls back to its own pure-perl encoder/decoder but does not support all the options
# that we require here.
use constant _JSON_BACKEND =>
    Mojo::JSON::JSON_XS && eval { Cpanel::JSON::XS->VERSION('4.38'); 1 } ? 'Cpanel::JSON::XS'
  : eval { JSON::PP->VERSION('4.11'); 1 } ? 'JSON::PP'
  : croak 'Cpanel::JSON::XS 4.38 or JSON::PP 4.11 is required';

# supports the six core types, plus integer (which is also a number)
# we do NOT check stringy_numbers here -- you must do that in the caller
# note that sometimes a value may return true for more than one type, e.g. integer+number,
# or number+string, depending on its internal flags.
# pass { legacy_ints => 1 } in $config to use draft4 integer behaviour
# behaviour is consistent with get_type() (where integers are also numbers).
sub is_type ($type, $value, $config = {}) {
  if ($type eq 'null') {
    return !(defined $value);
  }
  if ($type eq 'boolean') {
    return is_bool($value);
  }
  if ($type eq 'object') {
    return ref $value eq 'HASH';
  }
  if ($type eq 'array') {
    return ref $value eq 'ARRAY';
  }

  if ($type eq 'string' or $type eq 'number' or $type eq 'integer') {
    return 0 if not defined $value;
    my $flags = B::svref_2object(\$value)->FLAGS;

    # dualvars with the same string and (stringified) numeric value could be either a string or a
    # number, and before 5.36 we can't tell the difference, so we will answer yes for both.
    # in 5.36+, stringified numbers still get a PV but don't have POK set, whereas
    # numified strings do have POK set, so we can tell which one came first.

    if ($type eq 'string') {
      # like created_as_string, but rejects dualvars with stringwise-unequal string and numeric parts
      return !length ref($value)
        && !(HAVE_BUILTIN && builtin::is_bool($value))
        && $flags & B::SVf_POK
        && (!($flags & (B::SVf_IOK | B::SVf_NOK))
            || do { no warnings 'numeric'; 0+$value eq $value });
    }

    if ($type eq 'number') {
      # floats in json will always be parsed into Math::BigFloat, when allow_bignum is enabled
      return is_bignum($value) || created_as_number($value);
    }

    if ($type eq 'integer') {
      if ($config->{legacy_ints}) {
        # in draft4, an integer is "A JSON number without a fraction or exponent part.",
        # therefore 2.0 is NOT an integer
        return ref($value) eq 'Math::BigInt'
          || ($flags & B::SVf_IOK) && !($flags & B::SVf_NOK) && created_as_number($value);
      }
      else {
        # note: values that are larger than $Config{ivsize} will be represented as an NV, not IV,
        # therefore they will fail this check -- which is why use of Math::BigInt is recommended
        # if the exact type is important, or loss of any accuracy is unacceptable
        return is_bignum($value) && $value->is_int
          # if dualvar, PV and stringified NV/IV must be identical
          || created_as_number($value) && int($value) == $value;
      }
    }
  }

  if ($type =~ /^reference to (.+)\z/) {
    return !blessed($value) && ref($value) eq $1;
  }

  return ref($value) eq $type;
}

# returns one of the six core types, plus integer
# we do NOT check stringy_numbers here -- you must do that in the caller
# pass { legacy_ints => 1 } in $config to use draft4 integer behaviour
# behaviour is consistent with is_type().
sub get_type ($value, $config = {}) {
  return 'object' if ref $value eq 'HASH';
  return 'boolean' if is_bool($value);
  return 'null' if not defined $value;
  return 'array' if ref $value eq 'ARRAY';

  # floats in json will always be parsed into Math::BigFloat, when allow_bignum is enabled
  if (length(my $ref = ref $value)) {
    return $ref eq 'Math::BigInt' ? 'integer'
      : $ref eq 'Math::BigFloat' ? (!$config->{legacy_ints} && $value->is_int ? 'integer' : 'number')
      : (defined blessed($value) ? '' : 'reference to ').$ref;
  }

  my $flags = B::svref_2object(\$value)->FLAGS;

  # dualvars with the same string and (stringified) numeric value could be either a string or a
  # number, and before 5.36 we can't tell the difference, so we choose number because it has been
  # evaluated as a number already.
  # in 5.36+, stringified numbers still get a PV but don't have POK set, whereas
  # numified strings do have POK set, so we can tell which one came first.

  # like created_as_string, but rejects dualvars with stringwise-unequal string and numeric parts
  return 'string'
    if $flags & B::SVf_POK
      && (!($flags & (B::SVf_IOK | B::SVf_NOK))
        || do { no warnings 'numeric'; 0+$value eq $value });

  if ($config->{legacy_ints}) {
    # in draft4, an integer is "A JSON number without a fraction or exponent part.",
    # therefore 2.0 is NOT an integer
    return ($flags & B::SVf_IOK) && !($flags & B::SVf_NOK) ? 'integer' : 'number'
      if created_as_number($value);
  }
  else {
    # note: values that are larger than $Config{ivsize} will be represented as an NV, not IV,
    # therefore they will fail this check -- which is why use of Math::BigInt is recommended
    # if the exact type is important, or loss of any accuracy is unacceptable
    return int($value) == $value ? 'integer' : 'number' if created_as_number($value);
  }

  # this might be a scalar with POK|IOK or POK|NOK set
  return 'ambiguous type';
}

# lifted from JSON::MaybeXS
# note: unlike builtin::compat::is_bool on older perls, we do not accept
# dualvar(0,"") or dualvar(1,"1") because JSON::PP and Cpanel::JSON::XS
# do not encode these as booleans.
sub is_bool ($value) {
  HAVE_BUILTIN and builtin::is_bool($value)
  or
  !!blessed($value)
    and ($value->isa('JSON::PP::Boolean')
      or $value->isa('Cpanel::JSON::XS::Boolean')
      or $value->isa('JSON::XS::Boolean'));
}

sub is_schema ($value) {
  ref $value eq 'HASH' || is_bool($value);
}

sub is_bignum ($value) {
  ref($value) =~ /^Math::Big(?:Int|Float)\z/;
}

# compares two arbitrary data payloads for equality, as per
# https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.2.2
# $state hashref supports the following fields:
# - scalarref_booleans (input): treats \0 and \1 as boolean values
# - stringy_numbers (input): strings will also be compared numerically
# - path (output): location of the first difference
# - error (output): description of the first difference
sub is_equal ($x, $y, $state = {}) {
  $state->{path} //= '';

  my @types = map get_type($_), $x, $y;

  $state->{error} = 'ambiguous type encountered', return 0
    if grep $types[$_] eq 'ambiguous type', 0..1;

  if ($state->{scalarref_booleans}) {
    ($x, $types[0]) = (0+!!$$x, 'boolean') if $types[0] eq 'reference to SCALAR';
    ($y, $types[1]) = (0+!!$$y, 'boolean') if $types[1] eq 'reference to SCALAR';
  }

  if ($state->{stringy_numbers}) {
    ($x, $types[0]) = (0+$x, int(0+$x) == $x ? 'integer' : 'number')
      if $types[0] eq 'string' and looks_like_number($x);

    ($y, $types[1]) = (0+$y, int(0+$y) == $y ? 'integer' : 'number')
      if $types[1] eq 'string' and looks_like_number($y);
  }

  $state->{error} = "wrong type: $types[0] vs $types[1]", return 0 if $types[0] ne $types[1];
  return 1 if $types[0] eq 'null';
  ($x eq $y and return 1), $state->{error} = 'strings not equal', return 0
    if $types[0] eq 'string';
  ($x == $y and return 1), $state->{error} = "$types[0]s not equal", return 0
    if grep $types[0] eq $_, qw(boolean number integer);

  my $path = $state->{path};
  if ($types[0] eq 'object') {
    $state->{error} = 'property count differs: '.keys(%$x).' vs '.keys(%$y), return 0
      if keys %$x != keys %$y;

    if (not is_equal(my $arr_x = [ sort keys %$x ], my $arr_y = [ sort keys %$y ], my $s={})) {
      my $pos = substr($s->{path}, 1);
      $state->{error} = 'property names differ starting at position '.$pos.' ("'.$arr_x->[$pos].'" vs "'.$arr_y->[$pos].'")';
      return 0;
    }

    foreach my $property (sort keys %$x) {
      $state->{path} = jsonp($path, $property);
      return 0 if not is_equal($x->{$property}, $y->{$property}, $state);
    }

    return 1;
  }

  if ($types[0] eq 'array') {
    $state->{error} = 'element count differs: '.@$x.' vs '.@$y, return 0 if @$x != @$y;
    foreach my $idx (0 .. $x->$#*) {
      $state->{path} = $path.'/'.$idx;
      return 0 if not is_equal($x->[$idx], $y->[$idx], $state);
    }
    return 1;
  }

  $state->{error} = 'got surprising type: '.$types[0], return 0; # should never get here
}

# checks array elements for uniqueness. short-circuits on first pair of matching elements
# $state hashref supports the following fields:
# - scalarref_booleans (input): treats \0 and \1 as boolean values
# - stringy_numbers (input): strings will also be compared numerically
# - path (output): location of the first difference
# - error (output): description of the first difference
# - equal_indices (output): the indices of identical items
sub is_elements_unique ($array, $state = {}) {
  foreach my $idx0 (0 .. $array->$#*-1) {
    foreach my $idx1 ($idx0+1 .. $array->$#*) {
      if (is_equal($array->[$idx0], $array->[$idx1], $state)) {
        push $state->{equal_indices}->@*, $idx0, $idx1 if exists $state->{equal_indices};
        return 0;
      }
    }
  }
  return 1;
}

# shorthand for creating and appending json pointers
# the first argument is an already-encoded json pointer; remaining arguments are path segments to be
# encoded and appended
sub jsonp {
  carp q{first argument to jsonp should be '' or start with '/'} if length($_[0]) and substr($_[0],0,1) ne '/';
  return join('/', shift, map s!~!~0!gr =~ s!/!~1!gr, grep defined, @_);
}

# splits a json pointer apart into its path segments
sub unjsonp {
  carp q{argument to unjsonp should be '' or start with '/'} if length($_[0]) and substr($_[0],0,1) ne '/';
  return map s!~0!~!gr =~ s!~1!/!gr, split m!/!, $_[0];
}

sub jsonp_get ($data, $pointer) {
  Mojo::JSON::Pointer->new($data)->get($pointer);
}

# flatten the data structure into a hashref of { pointer => value, ... }
# (essentially the reverse of jsonp_set($data, $foo->%{$_}) foreach keys $foo)
sub jsonp_elements ($data, $prefix = '') {
  # recursively walk the structure..
  my $hash = +{
      ref $data eq '' ? ($prefix => $data)
    : ref $data eq 'HASH' ? map jsonp_elements($data->{$_}, $prefix.'/'.$_)->%*, keys %$data
    : ref $data eq 'ARRAY' ? map jsonp_elements($data->[$_], $prefix.'/'.$_)->%*, 0..$data->$#*
    : croak 'unrecognized type: '. ref $data
  };
}

# assigns a value to a data structure at a specific json pointer location
# operates destructively, in place, unless the root data or type is being modified
sub jsonp_set ($data, $pointer, $value) {
  croak 'cannot write into a non-reference in void context'
    if not grep ref $data eq $_, qw(HASH ARRAY) and not defined wantarray;

  # assigning to the root overwrites existing data
  if (not length $pointer) {
    if (not ref $data or ref $data ne ref $value) {
      return $value if defined wantarray;
      croak 'cannot write into a reference of a different type in void context';
    }

    if (ref $value eq 'HASH') {
      $data = {} if not ref $data;
      $data->%* = $value->%*;
    }
    if (ref $value eq 'ARRAY') {
      $data = [] if not ref $data;
      $data->@* = $value->@*;
    }

    return $data;
  }

  my @keys = map +(s!~0!~!gr =~ s!~1!/!gr),
    (length $pointer ? (split /\//, $pointer, -1) : ($pointer));

  croak 'cannot write a hashref into a reference to an array in void context'
    if @keys >= 2 and $keys[1] !~ /^(?:\d+|-)\z/a and ref $data eq 'ARRAY' and not defined wantarray;

  shift @keys;  # always '', indicating the root
  my $curp = \$data;

  foreach my $key (@keys) {
    # if needed, first remove the existing data so we can replace with a new hash key or array index
    undef $curp->$*
      if not ref $curp->$*
        or ref $curp->$* eq 'ARRAY' and $key !~ /^(?:\d+|-)\z/a;

    # use this existing hash key or array index location, or create new position
    use autovivification 'store';
    $curp = \(
      ref $curp->$* eq 'HASH' || $key !~ /^(?:\d+|-)\z/a
        ? $curp->$*->{$key}
        : $key =~ /^\d+\z/a
        ? $curp->$*->[$key]
        : $curp->$*->[$curp->$*->$#* + 1]);
  }

  $curp->$* = $value;
  return $data;
}

# returns a reusable Types::Standard type for json pointers
# TODO: move this off into its own distribution, see JSON::Schema::Types
sub json_pointer_type () { Str->where('!length || m{^/} && !m{~(?![01])}'); }

# a URI without a fragment, or with a json pointer fragment
sub canonical_uri_type () {
  (InstanceOf['Mojo::URL'])->where(q{!defined($_->fragment) || $_->fragment =~ m{^/} && $_->fragment !~ m{~(?![01])}});
}

# Validation §7.1-2: "Note that the "type" keyword in this specification defines an "integer" type
# which is not part of the data model. Therefore a format attribute can be limited to numbers, but
# not specifically to integers."
sub core_types_type () {
  Enum[qw(null object array boolean string number)];
}

sub core_formats_type () {
  Enum[qw(date-time date time duration email idn-email hostname idn-hostname ipv4 ipv6 uri uri-reference iri iri-reference uuid uri-template json-pointer relative-json-pointer regex)];
}

# simple runtime-wide cache of $ids to schema document objects that are sourced from disk
{
  my $document_cache = {};

  # Fetches a document from the cache (reading it from disk and creating the document if necessary),
  # and add it to the evaluator.
  # Normally this will just be a cache of schemas that are bundled with this distribution or a related
  # distribution (such as OpenAPI-Modern), as duplicate identifiers are not checked for, unlike for
  # normal schema additions.
  # Only JSON-encoded files are supported at this time.
  sub load_cached_document ($evaluator, $uri) {
    $uri =~ s/#\z//; # older draft $ids use an empty fragment

    # see if it already exists as a document in the cache
    my $document = $document_cache->{$uri};

    # otherwise, load it from disk using our filename cache and create the document
    if (not $document and my $filename = get_schema_filename($uri)) {
      my $file = path($filename);
      croak "uri $uri maps to file $file which does not exist" if not -f $file;
      my $schema = $evaluator->_json_decoder->decode($file->slurp);

      # avoid calling add_schema, which checksums the file to look for duplicates
      $document = JSON::Schema::Modern::Document->new(
        schema => $schema,
        evaluator => $evaluator,
        skip_ref_checks => 1,
      );

      # avoid calling add_document, which checks for duplicate identifiers (and would result in an
      # infinite loop)
      die JSON::Schema::Modern::Result->new(
        output_format => $evaluator->output_format,
        valid => 0,
        errors => [ $document->errors ],
        exception => 1,
      ) if $document->has_errors;

      $document_cache->{$uri} = $document;
    }

    return if not $document;

    # bypass the normal collision checks, to avoid an infinite loop: these documents are presumed safe
    $evaluator->_add_resources_unsafe(
      map +($_->[0] => +{ $_->[1]->%*, document => $document }),
        $document->resource_pairs
    );

    return $document;
  }
}

###### media-type mayhem below!

{
  # a hashref that indexes a media-type or media-range string to a decoder, encoder, and
  # denormalized representation of the string.
  # prepopulated list must match the list of definitions in _predefined_media_types
  my $MEDIA_TYPES = {
    map +(join('/', @$_) => { type => $_->[0], subtype => $_->[1] }), (
      [ qw(application json) ],
      [ qw(application octet-stream) ],
      [ qw(text *) ],
      [ qw(application x-www-form-urlencoded) ],
      [ qw(application x-ndjson) ],
      # multipart/form-data and multipart/* are special-cased in OpenAPI::Modern: do not add here
    )
  };

  # see RFC9110 §8.3.1 for ABNF
  my $OWS = q{[\x09\x20]*};
  my $TOKEN = q{[a-zA-Z0-9!#$%&'*+.^_`|~-]+};
  my $QUOTED_STRING = q{"((?:[\x09\20\x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\x5C[\x09\x20-\x7E\x80-\xFF])*)"};

  # parses into hashref: { type => .., subtype => .., params => { .. } }
  my sub _parse_media_type ($media_type_string) {
    my ($type_subtype, @params) = split /$OWS;$OWS/, $media_type_string;
    my ($type, $subtype) = ($type_subtype//'') =~ m{^($TOKEN)/($TOKEN)\z};
    return if not defined $type or not defined $subtype;

    # RFC9110 §5.6.4: "The backslash octet ("\") can be used as a single-octet quoting mechanism
    # within quoted-string and comment constructs. Recipients that process the value of a
    # quoted-string MUST handle a quoted-pair as if it were replaced by the octet following the
    # backslash."
    my $params = {
      map +(m{^($TOKEN)=($TOKEN|$QUOTED_STRING)\z}
        ? (fc($1) => defined $3 ? ($3 =~ s/\x5C(.)/$1/gr) : $2)
        : ()),
      @params
    };

    # some parameter values are case-insensitive; enumerate them here
    $params->{$_} = fc($params->{$_}) foreach grep exists $params->{$_}, qw(charset);

    croak 'cannot parse more than 64 parameters' if keys $params->%* > 64;
    +{
      type => fc($type),
      subtype => fc($subtype),
      keys %$params ? (parameters => $params) : (),
    };
  }

  # wrapped in a sub so we don't define them until needed
  my sub _predefined_media_types ($media_type_string) {
    return +{
      type => 'application',
      subtype => 'json',
      # UTF-8 decoding and encoding is always done, as per the JSON spec.
      # other charsets are not supported: see RFC8259 §11
      decode => sub ($content_ref, @) {
        \ _JSON_BACKEND->new->allow_nonref(1)->utf8(1)->decode($content_ref->$*);
      },
      encode => sub ($content_ref, @) {
        \ _JSON_BACKEND->new->allow_nonref(1)->utf8(1)->allow_blessed(1)->convert_blessed(1)->encode($content_ref->$*);
      },
      owner_addr => 1,
    }
    if $media_type_string eq 'application/json';

    return +{
      type => 'application',
      subtype => 'octet-stream',
      (map +($_ => sub ($content_ref, @) { $content_ref }), qw(decode encode)),
      owner_addr => 1,
    }
    if $media_type_string eq 'application/octet-stream';

    # identity function, with charset support
    return +{
      type => 'text', subtype => '*',
      decode => sub ($content_ref, $parameters = {}, @) {
        # RFC2046 §4.1.2: charset is case-insensitive
        return $parameters->{charset} ?
          \ Encode::decode($parameters->{charset}, $content_ref->$*, Encode::DIE_ON_ERR | Encode::LEAVE_SRC)
          : $content_ref;
      },
      encode => sub ($content_ref, $parameters = {}, @) {
        return $parameters->{charset} ?
          \ Encode::encode($parameters->{charset}, $content_ref->$*, Encode::DIE_ON_ERR | Encode::LEAVE_SRC)
          : $content_ref;
      },
      owner_addr => 1,
    }
    if $media_type_string eq 'text/*';

    return +{
      type => 'application',
      subtype => 'x-www-form-urlencoded',
      decode => sub ($content_ref, @) {
        \ Mojo::Parameters->new->charset('UTF-8')->parse($content_ref->$*)->to_hash;
      },
      encode => sub ($content_ref, @) {
        \ Mojo::Parameters->new->charset('UTF-8')
          ->parse(map +($_ => $content_ref->$*->{$_}), sort keys $content_ref->$*->%*)->to_string;
      },
      owner_addr => 1,
    }
    if $media_type_string eq 'application/x-www-form-urlencoded';

    return +{
      type => 'application',
      subtype => 'x-ndjson',
      decode => sub ($content_ref, @) {
        my $decoder = _JSON_BACKEND->new->allow_nonref(1)->utf8(1);
        my $line = 0; # line numbers start at 1
        \[ map {
            do {
              try { ++$line; $decoder->decode($_) }
              catch ($e) { croak 'parse error at line '.$line.': '.$e }
            }
          }
          split(/\r?\n/, $content_ref->$*)
        ];
      },
      encode => sub ($content_ref, @) {
        my $encoder = _JSON_BACKEND->new->allow_nonref(1)->utf8(1)->allow_blessed(1)->convert_blessed(1);
        \ join "\n", map $encoder->encode($_), $content_ref->$*->@*;
      },
      owner_addr => 1,
    }
    if $media_type_string eq 'application/x-ndjson';
  }

  # for internal use by JSON::Schema::Modern only! may be removed without notice!
  sub _get_media_type_decoder ($media_type_string) {
    my $matched_string = match_media_type($media_type_string);
    return undef if not defined $matched_string;

    my $definition = $MEDIA_TYPES->{$matched_string};
    $definition = $MEDIA_TYPES->{$matched_string} = _predefined_media_types($matched_string)
      if not exists $definition->{decode};

    return $definition->{decode};
  }

  sub add_media_type ($media_type_string, $decoder_sub = undef, $encoder_sub = undef, $owner_addr = 1) {
    croak 'decoder is not a subref' if defined $decoder_sub and ref $decoder_sub ne 'CODE';
    croak 'encoder is not a subref' if defined $encoder_sub and ref $encoder_sub ne 'CODE';

    my $type = _parse_media_type($media_type_string);
    croak "bad media-type string \"$media_type_string\"" if not $type;

    # populate the cache if it's a bundled type that hasn't been defined yet
    _predefined_media_types($media_type_string) if not exists $MEDIA_TYPES->{$media_type_string};

    if (any { is_equal($type, { $_->%{qw(type subtype parameters)} }) } values %$MEDIA_TYPES) {
      croak 'duplicate media-type found' if $owner_addr == 1;

      # track evaluator object that used the deprecated add_media_type interface
      push $MEDIA_TYPES->{$media_type_string}{owner_addr}->@*, $owner_addr;
      return;
    }

    $MEDIA_TYPES->{$media_type_string} = {
      decode => $decoder_sub,
      encode => $encoder_sub,
      %$type,
      owner_addr => [ $owner_addr ],    # refaddr of the evaluator object that added us
    };

    return;
  }

  sub delete_media_type ($media_type_string, $owner_addr = 1) {
    return if not exists $MEDIA_TYPES->{$media_type_string};

    delete $MEDIA_TYPES->{$media_type_string}
      if $owner_addr == 1
        or $MEDIA_TYPES->{$media_type_string}{owner_addr} = [
          grep +($_ != 1 && $_ != $owner_addr), $MEDIA_TYPES->{$media_type_string}{owner_addr}->@*
        ];
  }

  # wildcards, parameters supported
  # always returns a reference to the decoded data, or undef if no decoder is found
  sub decode_media_type ($media_type_string, $content_ref) {
    croak 'decoder payload must be a reference to a string (not ',
        (length ref $content_ref ? ref $content_ref : 'a non-reference')
      if ref $content_ref ne 'SCALAR';

    my $matched_string = match_media_type($media_type_string);
    return if not $matched_string;

    my $definition = $MEDIA_TYPES->{$matched_string};
    $definition = $MEDIA_TYPES->{$matched_string} = _predefined_media_types($matched_string)
      if not exists $definition->{decode};

    return if not $definition->{decode};

    my $type = _parse_media_type($media_type_string);
    $definition->{decode}->($content_ref, $type->{parameters}//());
  }

  # wildcards, parameters supported
  sub encode_media_type ($media_type_string, $content_ref) {
    croak 'encoder payload must be a reference' if ref $content_ref ne 'REF' and ref $content_ref ne 'SCALAR';

    my $matched_string = match_media_type($media_type_string);
    return if not $matched_string;

    my $definition = $MEDIA_TYPES->{$matched_string};
    $definition = $MEDIA_TYPES->{$matched_string} = _predefined_media_types($matched_string)
      if not exists $definition->{encode};

    return if not $definition->{encode};

    my $type = _parse_media_type($media_type_string);
    $definition->{encode}->($content_ref, $type->{parameters}//());
  }

  # finds best match for a media-type against a list of media-types. if parameter(s) are included in
  # the media-type to be matched, all parameters must be present in the match value.
  sub match_media_type ($media_type_string, $media_types = []) {
    # return immediately if exact match exists
    return $media_type_string
      if @$media_types and any { $_ eq $media_type_string } @$media_types
        or not @$media_types and exists $MEDIA_TYPES->{$media_type_string};

    my $mt = _parse_media_type($media_type_string);
    return if not $mt;

    my $types = @$media_types ? +{ map +($_ => _parse_media_type($_)), @$media_types } : $MEDIA_TYPES;

    my @matches;  # [ rank, candidate ]

    # iterate through each provided MT and compare it to the string for matchability..
    CANDIDATE:
    foreach my $candidate (keys %$types) {
      # if candidate has parameters, all parameters must match; missing parameters ok.
      # the more parameters match the higher the score.
      my $params_matched = 0;
      foreach my $param (keys(($types->{$candidate}{parameters}//{})->%*)) {
        next CANDIDATE if not exists(($mt->{parameters}//{})->{$param})
          or $types->{$candidate}{parameters}{$param} ne $mt->{parameters}{$param};

        ++$params_matched;
      }

      push(@matches, [ 0+$params_matched, $candidate ]), next if $candidate eq '*/*';
      push(@matches, [ 2**8 + $params_matched, $candidate ]), next
        if $types->{$candidate}{subtype} eq '*'
          and $types->{$candidate}{type} eq $mt->{type};

      # exact type + subtype match: best overall
      if ($types->{$candidate}{type} eq $mt->{type}) {
        push(@matches, [ 2**10 + $params_matched, $candidate ]), next
          if $types->{$candidate}{subtype} eq $mt->{subtype};

        # text/foo+plain matches text/plain but not text/bar+plain
        push(@matches, [ 2**9 + $params_matched, $candidate ]), next
          if $mt->{subtype} =~ m{^.+\+(.+)\z} and $types->{$candidate}{subtype} eq $1;
      }
    }

    return if not @matches;
    my @sorted = sort { $b->[0] <=> $a->[0] } @matches;
    return $sorted[0]->[1];
  }
}

######## NO PUBLIC INTERFACES FOLLOW THIS POINT ########

# get all annotations produced for the current instance data location (that are visible to this
# schema location) - remember these are hashrefs, not Annotation objects
sub local_annotations ($state) {
  grep $_->{instance_location} eq $state->{data_path}, $state->{annotations}->@*;
}

# shorthand for finding the current uri of the present schema location
# ensure that this code is kept consistent with the absolute_keyword_location builder in ResultNode
# Note that this may not be canonical if keyword_path has not yet been reset via the processing of a
# local identifier keyword (e.g. '$id').
sub canonical_uri ($state, @extra_path) {
  return $state->{initial_schema_uri} if not @extra_path and not length($state->{keyword_path});
  my $uri = $state->{initial_schema_uri}->clone;
  my $fragment = ($uri->fragment//'').(@extra_path ? jsonp($state->{keyword_path}, @extra_path) : $state->{keyword_path});
  undef $fragment if not length($fragment);
  $uri->fragment($fragment);
  $uri;
}

# shorthand for creating error objects
# uses these keys from $state:
# - initial_schema_uri
# - keyword (optional)
# - data_path
# - traversed_keyword_path
# - keyword_path
# - _keyword_path_suffix (optional)
# - errors
# - exception (optional; set by abort())
# - recommended_response (optional)
# - depth
# - traverse (boolean, used for mode)
# returns defined-false, so callers can use 'return;' to differentiate between
# failed-with-no-error from failed-with-error.
sub E ($state, $error_string, @args) {
  croak 'E called in void context' if not defined wantarray;

  # sometimes the keyword shouldn't be at the very end of the schema path
  my $sps = delete $state->{_keyword_path_suffix};
  my @keyword_path_suffix = defined $sps && ref $sps eq 'ARRAY' ? $sps->@* : $sps//();

  # we store the absolute uri in unresolved form until needed,
  # and perform the rest of the calculations later.
  my $uri = [ $state->@{qw(initial_schema_uri keyword_path)}, $state->{keyword}//(), @keyword_path_suffix ];

  my $keyword_location = $state->{traversed_keyword_path}
    .jsonp($state->@{qw(keyword_path keyword)}, @keyword_path_suffix);

  require JSON::Schema::Modern::Error;
  push $state->{errors}->@*, JSON::Schema::Modern::Error->new(
    depth => $state->{depth} // 0,
    keyword => $state->{keyword},
    $state->{traverse} ? () : (instance_location => $state->{data_path}),
    keyword_location => $keyword_location,
    # we calculate absolute_keyword_location when instantiating the Error object for Result
    _uri => $uri,
    error => @args ? sprintf($error_string, @args) : $error_string,
    exception => $state->{exception},
    ($state->%{recommended_response})x!!$state->{recommended_response},
    mode => $state->{traverse} ? 'traverse' : 'evaluate',
  );

  return 0;
}

# shorthand for creating annotations
# uses these keys from $state:
# - initial_schema_uri
# - keyword (mandatory)
# - data_path
# - traversed_keyword_path
# - keyword_path
# - annotations
# - collect_annotations
# - _unknown (boolean)
# - depth
sub A ($state, $annotation) {
  # even if the user requested annotations, we only collect them for later drafts
  # ..but we always collect them if the lowest bit is set, indicating the presence of unevaluated*
  # keywords necessary for accurate validation
  return 1 if not ($state->{collect_annotations}
    & ($state->{specification_version} =~ /^draft[467]\z/ ? ~(1<<8) : ~0));

  # we store the absolute uri in unresolved form until needed,
  # and perform the rest of the calculations later.
  my $uri = [ $state->@{qw(initial_schema_uri keyword_path keyword)} ];

  my $keyword_location = $state->{traversed_keyword_path}.jsonp($state->@{qw(keyword_path keyword)});

  push $state->{annotations}->@*, {
    depth => $state->{depth} // 0,
    keyword => $state->{keyword},
    instance_location => $state->{data_path},
    keyword_location => $keyword_location,
    # we calculate absolute_keyword_location when instantiating the Annotation object for Result
    _uri => $uri,
    annotation => $annotation,
    $state->{_unknown} ? (unknown => 1) : (),
  };

  return 1;
}

# creates an error object, but also aborts evaluation immediately
# only this error is returned, because other errors on the stack might not actually be "real"
# errors (consider if we were in the middle of evaluating a "not" or "if").
# Therefore this is only appropriate during the evaluation phase, not the traverse phase.
sub abort ($state, $error_string, @args) {
  ()= E({ %$state, exception => 1 }, $error_string, @args);
  croak 'abort() called during traverse' if $state->{traverse};
  die pop $state->{errors}->@*;
}

sub assert_keyword_exists ($state, $schema) {
  croak 'assert_keyword_exists called in void context' if not defined wantarray;
  return E($state, '%s keyword is required', $state->{keyword}) if not exists $schema->{$state->{keyword}};
  return 1;
}

sub assert_keyword_type ($state, $schema, $type) {
  croak 'assert_keyword_type called in void context' if not defined wantarray;
  return 1 if is_type($type, $schema->{$state->{keyword}});
  E($state, '%s value is not a%s %s', $state->{keyword}, ($type =~ /^[aeiou]/ ? 'n' : ''), $type);
}

sub assert_pattern ($state, $pattern) {
  croak 'assert_pattern called in void context' if not defined wantarray;
  try {
    local $SIG{__WARN__} = sub { die @_ };
    qr/$pattern/;
  }
  catch ($e) { return E($state, $e); };
  return 1;
}

# this is only suitable for checking URIs within schemas themselves
# note that we cannot use $state->{specification_version} to more tightly constrain the plain-name
# fragment syntax, as we could be checking a $ref to a schema using a different version
sub assert_uri_reference ($state, $schema) {
  croak 'assert_uri_reference called in void context' if not defined wantarray;

  my $string = $schema->{$state->{keyword}};
  return E($state, '%s value is not a valid URI-reference', $state->{keyword})
    # see also uri-reference format sub
    if fc(Mojo::URL->new($string)->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/            # ascii characters only
      or $string =~ /#/                       # no fragment, except...
        and $string !~ m{#\z}                          # allow empty fragment
        and $string !~ m{#[A-Za-z_][A-Za-z0-9_:.-]*\z} # allow plain-name fragment, superset of all drafts
        and $string !~ m{#/(?:[^~]|~[01])*\z};         # allow json pointer fragment

  return 1;
}

# this is only suitable for checking URIs within schemas themselves,
# which have fragments consisting of plain names (anchors) or json pointers
sub assert_uri ($state, $schema, $override = undef) {
  croak 'assert_uri called in void context' if not defined wantarray;

  my $string = $override // $schema->{$state->{keyword}};
  my $uri = Mojo::URL->new($string);

  return E($state, '"%s" is not a valid URI', $string)
    # see also uri format sub
    if fc($uri->to_unsafe_string) ne fc($string)
      or $string =~ /[^[:ascii:]]/            # ascii characters only
      or not $uri->is_abs                     # must have a scheme
      or $string =~ /#/                       # no fragment, except...
        and $string !~ m{#\z}                          # empty fragment
        and $string !~ m{#[A-Za-z][A-Za-z0-9_:.-]*\z}  # plain-name fragment
        and $string !~ m{#/(?:[^~]|~[01])*\z};         # json pointer fragment

  return 1;
}

# produces an annotation whose value is the same as that of the current schema keyword
# makes a copy as this is passed back to the user, who cannot be trusted to not mutate it
sub annotate_self ($state, $schema) {
  A($state, ref $schema->{$state->{keyword}} ? clone($schema->{$state->{keyword}})
    : $schema->{$state->{keyword}});
}

# use original value as stored in the NV, without losing precision
sub sprintf_num ($value) {
  is_bignum($value) ? $value->bstr : sprintf('%s', $value);
}

{
  # simple runtime-wide cache of $ids to filenames that are sourced from disk
  my $schema_filename_cache = {};

  # adds a mapping from a URI to an absolute filename in the global runtime
  # (available to all instances of the evaluator running in the same process).
  sub register_schema ($uri, $filename) {
    $schema_filename_cache->{$uri} = $filename;
  }

  sub get_schema_filename ($uri) {
    $schema_filename_cache->{$uri};
  }
}

1;
__END__

=pod

=head1 SYNOPSIS

  use JSON::Schema::Modern::Utilities qw(func1 func2..);

=head1 DESCRIPTION

This class contains internal utilities to be used by L<JSON::Schema::Modern>, and other useful helpers.

=for Pod::Coverage is_bignum local_annotations
canonical_uri E A abort assert_keyword_exists assert_keyword_type assert_pattern assert_uri_reference assert_uri
annotate_self sprintf_num HAVE_BUILTIN true false
register_schema get_schema_filename

=head1 FUNCTIONS

=for stopwords schema metaschema dualvar jsonp unjsonp OpenAPI subref

=head2 is_type

  if (is_type('string', $value)) { ... }

Returns a boolean indicating whether the provided value is of the specified core type (C<null>,
C<boolean>, C<string>, C<number>, C<object>, C<array>) or C<integer>. Also optionally takes a hashref
C<{ legacy_ints => 1 }> indicating that draft4 number semantics should apply (where unlike later
drafts, C<2.0> is B<not> an integer).

=head2 get_type

  my $type = get_type($value);

Returns one of the core types (C<null>, C<boolean>, C<string>, C<number>, C<object>, C<array>) or
C<integer>. Also optionally takes a hashref C<{ legacy_ints => 1 }> indicating that draft4 number
semantics should apply. Behaviour is consistent with L</is_type>.

=head2 is_bool

  if (is_bool($value)) { ... }

Equivalent to C<is_type('boolean', $value)>.
Accepts JSON booleans and L<builtin> booleans, but not dualvars (because JSON encoders do not
recognize these as booleans).

=head2 is_schema

  if (is_schema($value)) { ... }

Equivalent to C<is_type('object') || is_type('boolean')>.

=head2 is_equal

  if (not is_equal($x, $y, my $state = {})) {
    say "values differ starting at $state->{path}: $state->{error}";
  }

Compares two arbitrary data payloads for equality, as per
L<Instance Equality in the JSON Schema draft2020-12 specification|https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.4.2.2>.

The optional third argument hashref supports the following fields:

=for :list
* C<scalarref_booleans> (provided by caller input): as in L<JSON::Schema::Modern/scalarref_booleans>
* C<stringy_numbers> (provided by caller input): when set, strings will also be compared numerically,
  as in L<JSON::Schema::Modern/stringy_numbers>
* C<path> (populated by function): if result is false, the json pointer location of the first difference
* C<error> (populated by function): if result is false, an error description of the first difference

=head2 is_elements_unique

  if (not is_elements_unique($arrayref, my $state = {}) {
    say "lists differ starting at $state->{path}: $state->{error}";
  }

Compares all elements of an arrayref for uniqueness.

The optional second argument hashref supports the same options as L</is_equal>, plus:

=for :list
* C<equal_indices> (populated by function): if result is false, the list of indices of the (first
  set of) equal items found.

=head2 jsonp

  # '/paths/~1foo~1{foo_id}/get/responses'
  my $jsonp = jsonp(qw(/paths /foo/{foo_id} get responses));

Constructs a json pointer string from a list of path components, with correct escaping; the first
argument must be C<''> or an already-escaped json pointer, to which the rest of the path components
are appended.

=head2 unjsonp

  # ('', 'paths', '/foo/{foo_id}', 'get', 'responses')
  my @components = unjsonp('/paths/~1foo~1{foo_id}/get/responses');

Splits a json pointer string into its path components, with correct unescaping.

=head2 jsonp_get

  # 4
  my $val = jsonp_get({ a => 1, b => { c => 3, d => 4 } }, '/b/d');

Fetches the value of a data structure at a particular json pointer location.

=head2 jsonp_elements

  # {
  #   '/a/b/0' => 'x',
  #   '/a/b/1' => 'y',
  #   '/a/c/d' => 'e',
  # }
  jsonp_elements({ a => { b => [ 'x', 'y' ], c => { d => 'e' } } });

Fetches all the ( json pointer => value ) tuples of a data structure as a hashref.

=head2 jsonp_set

  my $data = { a => 1, b => { c => 3, d => 4 } };
  my $defaults = {
    '/b/d' => 5,
    '/b/e' => 6,
    '/f' => 7,
    '/g/h/i/1' => [ 10 ],
  };
  jsonp_set($data, $_, $defaults->{$_}) foreach keys %$defaults;

  # data is now:
  # { a => 1, b => { c => 3, d => 5, e => 6 }, f => 7, g => { h => { i => [ undef, [ 10 ] ] } } }

Given an arbitrary data structure, a json pointer string, and an arbitrary value, assigns that value
to the given position in the data structure. This is a destructive operation, overwriting whatever
data was there before if needed (even if an incompatible type: e.g. a hash key will overwrite an
existing arrayref). Intermediary keys or indexes will spring into existence as needed.

=head2 json_pointer_type

A L<Type::Tiny> type representing a json pointer string.

=head2 canonical_uri_type

A L<Type::Tiny> type representing a canonical URI: a L<Mojo::URL> with either no fragment, or with a
json pointer fragment.

=head2 core_types_type

A L<Type::Tiny> type representing the core JSON Schema types.

=head2 core_formats_type

A L<Type::Tiny> type representing the core JSON Schema formats (across all supported versions).

=head2 load_cached_document

  my $evaluator = JSON::Schema::Modern->new;
  my $uri = 'https://json-schema.org/draft-07/schema#';
  my $document = load_cached_document($evaluator, $uri);

  my $result = $evaluator->evaluate($data, $uri);

Loads a document object from global cache, loading data from disk if needed. This should only be
used for officially-published schemas and metaschemas that are bundled with this distribution or
another related one.

=head2 add_media_type

  add_media_type('application/my_zip', $decoder_sub, $encoder_sub);
  add_media_type('audio/*; version=1', $decoder_sub, $encoder_sub);

Adds a media-type entry to the registry, or replaces an existing one. This registry is runtime-global,
available to any code running in this process.

Either or both of the subrefs are optional (use C<undef> for the decoder sub if you only want an
encoder); the subref is expected to have the following signature:

  sub ($content_ref, $parameters = {}, @)

The subref will be called with a reference to the content string, and a hashref of the parameters
that were parsed from the C<Content-Type> header (if any). Extra arguments are allowed to allow for
future flexibility with this interface.

These media types are already defined:

=for stopwords WHATWG

=for :list
* C<application/json> L<(RFC 4627)|https://datatracker.ietf.org/doc/html/rfc4627>
* C<application/schema+json> L<(proposed definition)|https://json-schema.org/draft/2020-12/json-schema-core.html#name-application-schemajson>
* C<application/schema-instance+json> L<(proposed definition)|https://json-schema.org/draft/2020-12/json-schema-core.html#name-application-schema-instance>
* C<application/octet-stream> - passes strings through unchanged
* C<application/x-www-form-urlencoded> L<(WHATWG)|https://url.spec.whatwg.org/#application/x-www-form-urlencoded>
* C<application/x-ndjson> L<(spec)|https://github.com/ndjson/ndjson-spec>
* C<text/*> - passes strings through unchanged; supports the charset parameter

Media-type definitions can be overridden with a new call to C<add_media_type>.

See the official L<OpenAPI Media Type Registry|https://spec.openapis.org/registry/media-type>
for a registry of known and useful media types; for
compatibility reasons, avoid defining a media type listed here with different semantics.

=head2 delete_media_type

  delete_media_type('application/my_zip');

Removes a media-type entry from the registry. The string must match exactly, including case and
whitespace.

=head2 decode_media_type

  my $content_ref = decode_media_type('text/plain; charset=UTF-8', \'encoded text');

Finds the best-matching media-type decoder for the given media-type and decodes the content (which
must be passed as a reference); returns a reference to the decoded content, or C<undef> if no
matching decoder could be found. An exception might be thrown if the data could not be successfully
decoded.

=head2 encode_media_type

  my $content_ref = encode_media_type('text/plain; charset=UTF-8', \[ 'decoded content' ]);

Finds the best-matching media-type encoder for the given media-type and encodes the content (which
must be passed as a reference); returns a reference to the encoded content, or C<undef> if no
matching encoder could be found. An exception might be thrown if the data could not be successfully
encoded.

=head2 match_media_type

  my $registered_media_type = match_media_type('text/html');
  my $ad_hoc_media_type = match_media_type('text/html', [ 'text/plain', 'text/*' ]);

Finds the best match for a C<Content-Type> header value from the media-types in the registry,
or from an ad-hoc list reference provided in the remaining arguments.

Types with structured suffixes will match more generic types when an exact match is not available
(e.g. C<application/schema+json> will match an entry for C<application/json>).

Exact matches to the C<type/subtype> name are preferred over wildcard matches (e.g. C<text/*>);
if parameters are present in the value being matched against (the list of registered media-types,
or the list provided to this sub), all parameters must be present and match exactly.

All comparisons are done case-insensitively.

=cut
