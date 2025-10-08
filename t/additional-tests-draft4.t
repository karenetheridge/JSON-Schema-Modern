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
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use lib 't/lib';
use Helper;
use Acceptance;

my $version = 'draft4';

acceptance_tests(
  acceptance => {
    specification => $version,
    test_dir => 't/additional-tests-'.$version,
  },
  evaluator => {
    specification_version => $version,
    validate_formats => 1,
    collect_annotations => 0,
  },
  output_file => $version.'-additional-tests.txt',
  test => {
    $ENV{NO_TODO} ? () : (todo_tests => [
      { file => [
          # these depend on optional prereqs
          !eval { require Time::Moment; require DateTime::Format::RFC3339; 1 } ? 'format-date-time.json' : (),
        ] },
    ]),
  },
);

done_testing;
__END__
see t/results/draft4-additional-tests.txt for test results
