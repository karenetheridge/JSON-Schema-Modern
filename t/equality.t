use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use utf8;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.88;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

foreach my $test (
  [ undef, undef, true ],
  [ undef, 1, false ],
  [ [qw(a b c)], [qw(a b c)], true ],
  [ [qw(a b c)], [qw(a b)], false ],
  [ [qw(a b)], [qw(b a)], false, '/0' ],
  [ 1, 1, true ],
  [ 1, 1.0, true ],
  [ [1,2], [2,1], false, '/0' ],
  [ { a => 1, b => 2 }, { b => 2, a => 1 }, true ],
  [ { a => 1 }, { a => 1.0 }, true ],
  [ [qw(école ಠ_ಠ)], ["\x{e9}cole", "\x{0ca0}_\x{0ca0}"], true ],
  [ { a => 1, b => 2 }, { a => 1, b => 3 }, false, '/b' ],
) {
  my ($x, $y, $expected, $diff_path) = @$test;
  my @types = map $js->_get_type($_), $x, $y;
  my $result = $js->_is_equal($x, $y, my $state = {});

  ok(!($result xor $expected), json_sprintf('%s == %s is %s', $x, $y, $expected));
  is($state->{path}, $diff_path // '', 'two instances differ at the expected place') if not $expected;

  ok($js->_is_type($types[0], $x), 'type of arg 0 was not mutated while making equality check');
  ok($js->_is_type($types[1], $y), 'type of arg 1 was not mutated while making equality check');

  note '';
}

done_testing;
