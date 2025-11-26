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
use Test2::Warnings 'warnings', ':no_end_test';

my $version = 'draft2020-12';

my @warnings = warnings {
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
            # these all depend on optional prereqs
            !eval { require Time::Moment; 1 } ? map "format-$_.json", qw(date-time date time) : (),
            !eval { require DateTime::Format::RFC3339; 1 } ? 'format-date-time.json' : (),
          ] },
        # various edge cases that are difficult to accomodate
        JSON::Schema::Modern::_JSON_BACKEND eq 'JSON::PP' ? { file => 'integers.json', group_description => 'int64 range checks', test_description => 'beyond lower boundary' } : (),
      ]),
    },
  );
};

my $test_sub = $ENV{AUTHOR_TESTING} ? sub { bag(@_) } : sub { superbagof(@_) };

cmp_result(
  \@warnings,
  $test_sub->(
    # these are all in unknownKeyword.json
    map +(
      (re(qr/^no-longer-supported "\Q$_\E" keyword present/)) x (4 * ($ENV{NO_SHORT_CIRCUIT} ? 1 : 2)),
    ), qw(dependencies id additionalItems $recursiveAnchor $recursiveRef),
  ),
  'got unsupported keyword warnings'.($ENV{AUTHOR_TESTING} ? '; no unexpected warnings' : ''),
);

done_testing;
__END__
see t/results/draft2020-12-additional-tests.txt for test results
