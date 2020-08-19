use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Scalar::Util qw(isdual dualvar);
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

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
      ok($js->_is_type($type, $value), json_sprintf(('_is_type("'.$type.'", %s) is true'), $value_copy ));
      is($js->_get_type($value), $type, json_sprintf(('_get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %inflated_data) {
        next if $other_type eq $type;

        ok(!$js->_is_type($other_type, $value),
          json_sprintf('_is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

foreach my $type (sort keys %json_data) {
  subtest 'JSON-encoded data, type: '.$type => sub {
    foreach my $value (@{ $json_data{$type} }) {
      $value = $js->_json_decoder->decode($value);
      my $value_copy = $value;
      ok($js->_is_type($type, $value), json_sprintf(('_is_type("'.$type.'", %s) is true'), $value_copy ));
      is($js->_get_type($value), $type, json_sprintf(('_get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %json_data) {
        next if $other_type eq $type;

        ok(!$js->_is_type($other_type, $value),
          json_sprintf('_is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

subtest 'type: integer' => sub {
  ok($js->_is_type('integer', $_), json_sprintf('%s is an integer', $_))
    foreach (1, 2.0);

  ok(!$js->_is_type('integer', $_), json_sprintf('%s is not an integer', $_))
    foreach ('1', '2.0', 3.1, '4.2');
};

subtest 'type: everything else' => sub {
  foreach my $type (qw(null object array boolean string number integer)) {
    ok(!$js->_is_type($type, $_), 'value is a '.(ref).', not a '.$type)
      foreach (
        \1,
        \\2,
        sub { 1 },
        \*stdout,
        \substr('a', '1'),
        \v1.2.3,
        qr/foo/,
        *STDIN{IO},
        bless({}, 'Foo'),
      );
  }
};

my $file = __FILE__;
my $line;
like(
  exception { $line = __LINE__; $js->_is_type('foo', 'wharbarbl') },
  qr/unknown type "foo" at $file line $line/,
  'non-existent type results in exception',
);

like(
  exception { $line = __LINE__; $js->_get_type(dualvar(5, "five")) },
  qr/ambiguous type for "five"/,
  'ambiguous type results in exception',
);

subtest '_get_type for references' => sub {
  like(
    exception { $line = __LINE__; $js->_get_type($_->[0]) },
    qr/unsupported reference type $_->[1]/,
    $_->[1].' reference type results in exception',
  ) foreach (
    [ \1, 'SCALAR' ],
    [ \\2, 'REF' ],
    [ sub { 1 }, 'CODE' ],
    [ \*stdout, 'GLOB' ],
    [ \substr('a', '1'), 'LVALUE' ],
    [ \v1.2.3, 'VSTRING' ],
    [ qr/foo/, 'Regexp' ],
    [ *STDIN{IO}, 'IO::File' ],
    [ bless({}, 'Foo'), 'Foo' ],
  );
};

done_testing;
