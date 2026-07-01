# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8
use utf8;

use lib 't/lib';
use Helper;

use JSON::Schema::Modern::Utilities qw(match_media_type add_media_type delete_media_type decode_media_type encode_media_type);

subtest 'new media-type handler' => sub {
  my @types = (
    '*/*',
    'mytext/*',
    'mytext/plAin',
    'mytext/foo+plain',
    'mytext/bar+plain',
    'mytext/plain; charset=iso8891-1',
    'mytext/plain;charset=utf-8',
    'mytext/PLAIN;  charset=utf-8; x=y',
    'mytext/foo; x="\1y"',  # equivalent to text/foo; x=1y
    'foo/bar',
  );

  my @tests = (
    # media-type => best candidate match from media-types added above
    [ '*/*', '*/*' ],                                             # wildcards match themselves
    [ 'any/thing', '*/*' ],                                       # anything matches */*
    [ 'MYTEXT/*', 'mytext/*' ],                                   # ""
    [ 'mytext/PLaiN', 'mytext/plAin' ],                           # exact type + subtype match
    [ 'mytext/html', 'mytext/*' ],                                # wildcard subtype match
    [ 'myapplication/json', '*/*' ],                              # wildcard match
    [ 'mytext/plain; x=y; charset=UtF-8', 'mytext/PLAIN;  charset=utf-8; x=y' ], # full param match (2)
    [ 'mytext/plain; charset=UTF-8' => 'mytext/plain;charset=utf-8' ],    # full param match (1)
    [ 'mytext/plain; a=b; charset=UtF-8', 'mytext/plain;charset=utf-8' ], # partial param match
    [ 'mytext/foo+plain', 'mytext/foo+plain' ],                           # match with subtype qualifier
    [ 'mytext/baz+plain', 'mytext/plAin' ],                       # subtype qualifier mismatch
    [ 'mytext/foo; x="\1\y"', 'mytext/foo; x="\1y"' ],            # quoted-pair in parameter
    [ 'mytext/foo; x=1y', 'mytext/foo; x="\1y"' ],                # no quotes still matches
  );

  # first, run the tests by passing in the list of candidate types
  foreach my $test (@tests) {
    is_equal(
      (match_media_type($test->[0], \@types) // undef),
      $test->[1],
      "using ad-hoc list: $test->[0] matches $test->[1]",
    );
  }

  # then run the tests using our global registry of types
  add_media_type($_) foreach @types;

  foreach my $test (@tests) {
    is_equal(
      (match_media_type($test->[0]) // undef),
      $test->[1],
      "using registry: $test->[0] matches $test->[1]",
    );
  }

  delete_media_type('*/*');
  is_equal(
    (match_media_type('any/thing') // undef),
    undef,
    'after deleting */* entry, this lookup fails',
  );

  like(
    dies { add_media_type('FOO-BAR' => sub {}) },
    qr/^bad media-type string "FOO-BAR"/,
    'bad media-type strings are rejected',
  );

  like(
    dies { add_media_type('MYTEXT/PLAIN; CHARSET=UTF-8' => sub {}) },
    qr/^duplicate media-type found/,
    'cannot add a type twice (when comparing normalized forms)',
  );

  is_equal(
    scalar decode_media_type('foo/bar', \'hi'),
    undef,
    'unknown media-type decoder returns undef, not a reference',
  );

  is_equal(
    scalar encode_media_type('foo/bar', \'hi'),
    undef,
    'unknown media-type encoder returns undef, not a reference',
  );

  like(
    dies { add_media_type('multipart/furble' => sub {}) },
    qr{^multipart encoders/decoders cannot be defined here: use OpenAPI::Modern},
    'cannot create an entry for anything multipart here',
  );
};

subtest 'application/json' => sub {
  is_equal(
    decode_media_type($_, \'{"a":1,"b":2}')->$*,
    { a => 1, b => 2 },
    "decoder for $_",
  ) foreach 'application/json', 'application/json; charset=UTF-8';

  is_equal(
    encode_media_type($_, \[ 0, 1, 2, 3, 4 ])->$*,
    '[0,1,2,3,4]',
    "encoder for $_",
  ) foreach 'application/json', 'application/json; charset=UTF-8';

  die_result(
    sub { decode_media_type('application/json', \'blargh') },
    qr/^malformed JSON string/,
    'decoder for "application/json" throws an exception for bad data',
  );

  die_result(
    sub { encode_media_type('application/json', \ sub { 1 }) },
    qr/JSON can only represent references to arrays or hashes/,
    'encoder for "application/json" throws an exception for bad data',
  );
};

subtest 'text/*' => sub {
  is_equal(
    decode_media_type('text/plain', \"\xe0\xb2\xa0\x5f\xe0\xb2\xa0")->$*,
    "\xe0\xb2\xa0\x5f\xe0\xb2\xa0",
    'text/* decoder without charset',
  );

  is_equal(
    decode_media_type('text/plain; charset=UTF-8', \"\xe0\xb2\xa0\x5f\xe0\xb2\xa0")->$*,
    'ಠ_ಠ',
    'text/* decoder with UTF-8 charset',
  );

  is_equal(
    encode_media_type('text/plain; charset=UTF-8', \'ಠ_ಠ')->$*,
    "\xe0\xb2\xa0\x5f\xe0\xb2\xa0",
    'text/* encoder with UTF-8 charset',
  );

  is_equal(
    decode_media_type('text/plain; charset=latin1', \"\xe9clair")->$*,
    'éclair',
    'text/* decoder with latin1 charset',
  );

  is_equal(
    encode_media_type('text/plain; charset=latin1', \'éclair')->$*,
    "\xe9clair",
    'text/* encoder with latin1 charset',
  );
};

subtest 'application/x-www-form-urlencoded'=> sub {
  is_equal(
    decode_media_type('application/x-www-form-urlencoded', \'foo=%E0%B2%A0_%E0%B2%A0')->$*,
    { foo => 'ಠ_ಠ' },
    'application/x-www-form-urlencoded decoder',
  );

  is_equal(
    encode_media_type('application/x-www-form-urlencoded', \{ foo => 'ಠ_ಠ' })->$*,
    'foo=%E0%B2%A0_%E0%B2%A0',
    'application/x-www-form-urlencoded encoder',
  );

  is_equal(
    decode_media_type('application/x-www-form-urlencoded', \'a=x&a=y&b=1&a=z&b=2')->$*,
    { a => [qw(x y z)], b => [qw(1 2)] },
    'application/x-www-form-urlencoded decoder with array values',
  );
  is_equal(
    encode_media_type('application/x-www-form-urlencoded', \{ a => [qw(x y z)], b => [qw(1 2)] })->$*,
    'a=x&a=y&a=z&b=1&b=2',
    'application/x-www-form-urlencoded encoder with array values, normalized',
  );

  is_equal(
    decode_media_type('application/x-www-form-urlencoded; type=array', \'a=x&a=y&b=1&a=z&b=2')->$*,
    [ { a => 'x' }, { a => 'y' }, { b => '1' }, { a => 'z' }, { b => '2' } ],
    'application/x-www-form-urlencoded decoder preserves order, when decoded to an array of tuples',
  );

  is_equal(
    encode_media_type('application/x-www-form-urlencoded',
      \[ { a => 'x' }, { a => 'y' }, { b => '1' }, { a => 'z' }, { b => '2' } ])->$*,
    'a=x&a=y&b=1&a=z&b=2',
    'application/x-www-form-urlencoded encoder, from an array of tuples',
  );
};

subtest 'application/x-ndjson' => sub {
  is_equal(
    decode_media_type('application/x-ndjson', \qq!{"a":1,"b":2}\n[0,1,2,3,4]!)->$*,
    [ { a => 1, b => 2 }, [ 0, 1, 2, 3, 4 ] ],
    'application/x-ndjson decoder',
  );

  is_equal(
    encode_media_type('application/x-ndjson', \[ { a => 1 }, [ 0, 1, 2, 3, 4 ] ])->$*,
    qq!{"a":1}\n[0,1,2,3,4]!,
    'application/x-ndjson encoder',
  );
};

done_testing;
