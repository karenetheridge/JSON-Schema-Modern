use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Scalar::Util qw(isdual dualvar);
use JSON::Schema::Modern::Utilities qw(is_type get_type);
use lib 't/lib';
use Helper;

my %inflated_data = (
  null => [ undef ],
  boolean => [ false, true ],
  object => [ {}, { a => 1 } ],
  array => [ [], [ 1 ] ],
  number => [ 0, -1, 2, 2.0, 3.1 ],
  string => [ '', '0', '-1', '2', '2.0', '3.1', 'école', 'ಠ_ಠ' ],
);

my %json_data = (
  null => [ 'null'],
  boolean => [ 'false', 'true' ],
  object => [ '{}', '{"a":1}' ],
  array => [ '[]', '[1]' ],
  number => [ '0', '-1', '2.0', '3.1' ],
  string => [ '""', '"0"', '"-1"', '"2.0"', '"3.1"',
    qq{"\x{c3}\x{a9}cole"}, qq{"\x{e0}\x{b2}\x{a0}_\x{e0}\x{b2}\x{a0}"} ],
);

foreach my $type (sort keys %inflated_data) {
  subtest 'inflated data, type: '.$type => sub {
    foreach my $value (@{ $inflated_data{$type} }) {
      my $value_copy = $value;
      ok(is_type($type, $value), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      is(get_type($value), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %inflated_data) {
        next if $other_type eq $type;

        ok(!is_type($other_type, $value),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

my $decoder = JSON::MaybeXS->new(allow_nonref => 1, canonical => 1, utf8 => 1);

foreach my $type (sort keys %json_data) {
  subtest 'JSON-encoded data, type: '.$type => sub {
    foreach my $value (@{ $json_data{$type} }) {
      $value = $decoder->decode($value);
      my $value_copy = $value;
      ok(is_type($type, $value), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      is(get_type($value), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %json_data) {
        next if $other_type eq $type;

        ok(!is_type($other_type, $value),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

subtest 'type: integer' => sub {
  ok(is_type('integer', $_), json_sprintf('%s is an integer', $_))
    foreach (1, 2.0);

  ok(!is_type('integer', $_), json_sprintf('%s is not an integer', $_))
    foreach ('1', '2.0', 3.1, '4.2');
};

ok(!is_type('foo', 'wharbarbl'), 'non-existent type does not result in exception');

my $file = __FILE__;
my $line;
like(
  exception { $line = __LINE__; get_type(dualvar(5, "five")) },
  qr/^ambiguous type for "five" at $file line $line/,
  'ambiguous type results in exception',
);

subtest 'is_type and get_type for references' => sub {
  foreach my $test (
    [ \1, 'reference to SCALAR' ],
    [ \\2, 'reference to REF' ],
    [ sub { 1 }, 'reference to CODE' ],
    [ \*stdout, 'reference to GLOB' ],
    [ \substr('a', '1'), 'reference to LVALUE' ],
    [ \v1.2.3, 'reference to VSTRING' ],
    [ qr/foo/, 'Regexp' ],
    [ *STDIN{IO}, 'IO::File' ],
    [ bless({}, 'Foo'), 'Foo' ],
  ) {
    is(get_type($test->[0]), $test->[1], $test->[1].' type is reported without exception');
    ok(is_type($test->[1], $test->[0]), 'value is a '.$test->[1]);
    foreach my $type (qw(null object array boolean string number integer)) {
      ok(!is_type($type, $test->[0]), 'value is not a '.$type);
    }
  }
};

done_testing;
