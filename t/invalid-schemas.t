# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use lib 't/lib';
use Acceptance;

acceptance_tests(
  acceptance => {
    specification => 'draft2019-09',
    test_dir => 't/invalid-schemas',
    include_optional => 0,
    test_schemas => 0,
  },
  evaluator => {
    validate_formats => 1,
  },
  output_file => 'invalid-schemas.txt',
);

done_testing;
__END__
see t/results/invalid-schemas.txt for test results
