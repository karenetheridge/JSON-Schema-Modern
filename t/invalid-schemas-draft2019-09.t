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
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;
use Acceptance;

my $version = 'draft2019-09';

acceptance_tests(
  acceptance => {
    specification => $version,
    test_dir => 't/invalid-schemas-'.$version,
    include_optional => 0,
    test_schemas => 0,
  },
  evaluator => {
    specification_version => $version,
    validate_formats => 1,
    collect_annotations => 0,
  },
  output_file => $version.'-invalid-schemas.txt',
);

done_testing;
__END__
see t/results/draft2019-09-invalid-schemas.txt for test results
