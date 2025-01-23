# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
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

use Config;
use lib 't/lib';
use Helper;

my @tests = (
  # data (dividend), schema value (divisor), expected result
  [ 4, 2, true ],
  [ 4, 1, true ],
  [ 4, 3, false ],
  [ 4.5, 1.5, true ],
  [ 4.5, 1, false ],
  [ 4.5, 3, false ],
  [ 4, 2, true ],
  [ 4, 2.5, false ],
  [ 5, 2.5, true ],
  [ 4.5, 2.25, true ],
  [ 4.5, 2.5, false ],
  [ 4.5, 2, false ],
  [ -(~0 >> 1) -1, 0.5, true ], # min signed int
  [ ~0 >> 1, 0.5, true ],       # max signed int
  [ ~0, 0.5, true ],            # max unsigned int
);


my $js = JSON::Schema::Modern->new;
my $note = $ENV{AUTHOR_TESTING} || $ENV{AUTOMATED_TESTING} ? \&diag : \&note;

sub run_test ($data, $schema_value, $expected) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $result = $js->evaluate($data, { multipleOf => $schema_value });
  my $pass = ok(!($result->valid xor $expected), "$data is ".($expected ? '' : 'not ')."a multiple of $schema_value");
  $note->('got result: '.$result->dump) if not $pass;
}

subtest 'multipleOf, native types' => sub {
  foreach my $test (@tests) {
    my ($data, $schema_value, $expected) = @$test;
    run_test($data, $schema_value, $expected);
  };
};

subtest 'multipleOf, data is a bignum' => sub {
  foreach my $test (@tests) {
    my ($data, $schema_value, $expected) = @$test;
    run_test(Math::BigFloat->new($data), $schema_value, $expected);
  };
};

subtest 'multipleOf, multipleOf is a bignum' => sub {
  foreach my $test (@tests) {
    my ($data, $schema_value, $expected) = @$test;
    run_test($data, Math::BigFloat->new($schema_value), $expected);
  };
};

subtest 'multipleOf, data and multipleOf are bignums' => sub {
  foreach my $test (@tests) {
    my ($data, $schema_value, $expected) = @$test;
    run_test(Math::BigFloat->new($data), Math::BigFloat->new($schema_value), $expected);
  };
};

done_testing;
