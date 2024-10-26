use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::Fatal;
use Scalar::Util qw(isdual dualvar);
use JSON::Schema::Modern::Utilities qw(is_type get_type);
use Math::BigInt;
use Math::BigFloat;
use lib 't/lib';
use Helper;

my %inflated_data = (
  null => [ undef ],
  boolean => [ false, true ],
  object => [ {}, { a => 1 } ],
  array => [ [], [ 1 ] ],
  number => [ 3.1, 1.23456789012e10, Math::BigFloat->new('0.123') ],
  integer => [ 0, -1, 2, 2.0, 2**31-1, 2**31, 2**63-1, 2**63, 2**64, 2**65, 1000000000000000,
    Math::BigInt->new('1e20'), Math::BigInt->new('1'), Math::BigInt->new('1.0'),
    Math::BigFloat->new('2e1'), Math::BigFloat->new('1'), Math::BigFloat->new('1.0') ],
  string => [ '', '0', '-1', '2', '2.0', '3.1', 'école', 'ಠ_ಠ' ],
);

my %json_data = (
  null => [ 'null' ],
  boolean => [ 'false', 'true' ],
  object => [ '{}', '{"a":1}' ],
  array => [ '[]', '[1]' ],
  number => [ '3.1', '1.23456789012e10' ],
  integer => [ '0', '-1', '2.0', (map $_.'', 2**31-1, 2**31, 2**63-1, 2**63, 2**64, 2**65), '1000000000000000', '2e1' ],
  string => [ '""', '"0"', '"-1"', '"2.0"', '"3.1"',
    qq{"\x{c3}\x{a9}cole"}, qq{"\x{e0}\x{b2}\x{a0}_\x{e0}\x{b2}\x{a0}"} ],
);

foreach my $type (sort keys %inflated_data) {
  subtest 'inflated data, type: '.$type => sub {
    foreach my $value ($inflated_data{$type}->@*) {
      my $value_copy = $value;
      ok(is_type($type, $value), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      ok(is_type('number', $value), json_sprintf(('is_type("number", %s) is true'), $value_copy ))
        if $type eq 'integer';
      is(get_type($value), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %inflated_data) {
        next if $other_type eq $type;
        next if $type eq 'integer' and $other_type eq 'number';

        ok(!is_type($other_type, $value),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

my $decoder = JSON::Schema::Modern::_JSON_BACKEND()->new
  ->allow_nonref(1)
  ->canonical(1)
  ->utf8(1)
  ->allow_bignum(1);

foreach my $type (sort keys %json_data) {
  subtest 'JSON-encoded data, type: '.$type => sub {
    foreach my $value ($json_data{$type}->@*) {
      $value = $decoder->decode($value);
      my $value_copy = $value;
      ok(is_type($type, $value), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      ok(is_type('number', $value), json_sprintf(('is_type("number", %s) is true'), $value_copy ))
        if $type eq 'integer';
      is(get_type($value), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (sort keys %json_data) {
        next if $other_type eq $type;
        next if $type eq 'integer' and $other_type eq 'number';

        ok(!is_type($other_type, $value),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  };
}

my %draft4_inflated_data = (
  number => [ 3.1, 1.23456789012e10, Math::BigFloat->new('0.123'), 2.0 ],
  integer => [ 0, -1, 2, Math::BigInt->new('2'), Math::BigInt->new('1.0') ],
);

my %draft4_json_data = (
  number => [ '3.1', '1.23456789012e10' ],
  integer => [ '0', '-1', '3' ],
);

subtest 'integers and numbers in draft4' => sub {
  foreach my $type (sort keys %draft4_inflated_data) {
    foreach my $value ($draft4_inflated_data{$type}->@*) {
      my $value_copy = $value;
      ok(is_type($type, $value, { legacy_ints => 1 }), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      ok(is_type('number', $value, { legacy_ints => 1 }), json_sprintf(('is_type("number", %s) is true'), $value_copy ))
        if $type eq 'integer';
      is(get_type($value, { legacy_ints => 1 }), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (qw(null boolean object array string), sort keys %draft4_inflated_data) {
        next if $other_type eq $type;
        next if $type eq 'integer' and $other_type eq 'number';

        ok(!is_type($other_type, $value, { legacy_ints => 1 }),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }

    foreach my $value ($draft4_json_data{$type}->@*) {
      $value = $decoder->decode($value);
      my $value_copy = $value;
      ok(is_type($type, $value, { legacy_ints => 1 }), json_sprintf(('is_type("'.$type.'", %s) is true'), $value_copy ));
      ok(is_type('number', $value, { legacy_ints => 1 }), json_sprintf(('is_type("number", %s) is true'), $value_copy ))
        if $type eq 'integer';
      is(get_type($value, { legacy_ints => 1 }), $type, json_sprintf(('get_type(%s) = '.$type), $value_copy));

      foreach my $other_type (qw(null boolean object array string), sort keys %draft4_json_data) {
        next if $other_type eq $type;
        next if $type eq 'integer' and $other_type eq 'number';

        ok(!is_type($other_type, $value, { legacy_ints => 1 }),
          json_sprintf('is_type("'.$other_type.'", %s) is false', $value));
      }

      ok(!isdual($value), 'data is not tampered with while it is tested (not dualvar)');
    }
  }
};

ok(!is_type('foo', 'wharbarbl'), 'non-existent type does not result in exception');

subtest 'ambiguous types' => sub {
  subtest 'integers' => sub {
    my $integer = dualvar(5, 'five');
    is(get_type($integer), 'ambiguous type', 'dualvar integers with different values are ambiguous');
    ok(!is_type($_, $integer), "dualvar integers with different values are not ${_}s") foreach qw(integer number string);

    $integer = 5;
    ()= sprintf('%s', $integer);

    # legacy behaviour (this only happens for IVs, not NVs)
    SKIP: {
      skip 'on perls < 5.35.9, reading the string form of an integer value sets the flag SVf_POK', 1
        if "$]" >= 5.035009;

      is(get_type($integer), 'string', 'older perls only: integer that is later used as a string is now identified as a string');
      ok(is_type('integer', $integer), 'integer that is later used as a string is still an integer');
      ok(is_type('number', $integer), 'integer that is later used as a string is still a number');
      ok(is_type('string', $integer), 'older perls only: integer that is later used as a string is now a string');
    }

    # modern behaviour
    SKIP: {
      skip 'on perls < 5.35.9, reading the string form of an integer value sets the flag SVf_POK', 1
        if "$]" < 5.035009;

      is(get_type($integer), 'integer', 'integer that is later used as a string is still identified as a integer');
      ok(is_type('integer', $integer), 'integer that is later used as a string is still an integer');
      ok(is_type('number', $integer), 'integer that is later used as a string is still a number');
      ok(!is_type('string', $integer), 'integer that is later used as a string is not a string');
    }
  };

  subtest 'numbers' => sub {
    my $number = dualvar(5.1, 'five');
    is(get_type($number), 'ambiguous type', 'dualvar numbers are ambiguous in get_type');
    ok(!is_type($_, $number), "dualvar numbers are not ${_}s") foreach qw(integer number string);

    $number = 5.1;
    ()= sprintf('%s', $number);

    is(get_type($number), 'number', 'number that is later used as a string is still identified as a number');
    ok(!is_type('integer', $number), 'number that is later used as a string is not an integer');
    ok(is_type('number', $number), 'number that is later used as a string is still a number');
    ok(!is_type('string', $number), 'number that is later used as a string is not a string');
  };

  subtest 'strings' => sub {
    my $string = dualvar(5.1, 'five');
    is(get_type($string), 'ambiguous type', 'dualvar strings are ambiguous in get_type');
    ok(!is_type($_, $string), "dualvar strings are not ${_}s") foreach qw(integer number string);

    $string = '5';
    ()= 0+$string;

    is(get_type($string), 'string', 'string that is later used as an integer is still identified as a string');

    # legacy behaviour
    SKIP: {
      skip 'on perls < 5.35.9, reading the string form of an integer value sets the flag SVf_POK', 1
        if "$]" >= 5.035009;
      ok(is_type('integer', $string), 'older perls only: string that is later used as an integer becomes an integer');
      ok(is_type('number', $string), 'older perls only: string that is later used as an integer becomes a number');
    }

    # modern behaviour
    SKIP: {
      skip 'on perls < 5.35.9, reading the integer form of a string value sets the flag SVf_IOK', 1
        if "$]" < 5.035009;
      ok(!is_type('integer', $string), 'string that is later used as an integer is not an integer');
      ok(!is_type('number', $string), 'string that is later used as an integer is not a number');
    }

    ok(is_type('string', $string), 'string that is later used as an integer is still a string');

    $string = '5.1';
    ()= 0+$string;

    is(get_type($string), 'string', 'string that is later used as a number is still identified as a string');
    ok(!is_type('integer', $string), 'string that is later used as a number is not an integer');

    # legacy behaviour
    SKIP: {
      skip 'on perls < 5.35.9, reading the string form of an integer value sets the flag SVf_POK', 1
        if "$]" >= 5.035009;
      ok(is_type('number', $string), 'older perls only: string that is later used as a number becomes a number');
    }

    # modern behaviour
    SKIP: {
      skip 'on perls < 5.35.9, reading the numeric form of a string value sets the flag SVf_NOK', 1
        if "$]" < 5.035009;
      ok(!is_type('number', $string), 'string that is later used as a number is not a number');
    }

    ok(is_type('string', $string), 'string that is later used as a number is still a string');
  };
};

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
    [ bless({}, '0'), '0' ],
  ) {
    is(get_type($test->[0]), $test->[1], $test->[1].' type is reported without exception');
    ok(is_type($test->[1], $test->[0]), 'value is a '.$test->[1]);
    foreach my $type (qw(null object array boolean string number integer)) {
      ok(!is_type($type, $test->[0]), 'value is not a '.$type);
    }
  }
};

done_testing;
