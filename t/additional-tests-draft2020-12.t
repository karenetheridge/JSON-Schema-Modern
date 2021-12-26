# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.020;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Test::Warnings 'warnings', ':no_end_test';
use Test::Deep;
use Config;
use lib 't/lib';
use Acceptance;

my $version = 'draft2020-12';

my @warnings = warnings {
  acceptance_tests(
    acceptance => {
      specification => $version,
      include_optional => 0,
      test_dir => 't/additional-tests-'.$version,
    },
    evaluator => {
      specification_version => $version,
      validate_formats => 1,
    },
    output_file => $version.'-additional-tests.txt',
    test => {
      $ENV{NO_TODO} ? () : ( todo_tests => [
        { file => [
            # these all depend on optional prereqs
            !eval { require Time::Moment; 1 } ? qw(format-date-time.json format-date.json format-time.json) : (),
            !eval { require DateTime::Format::RFC3339; 1 } ? 'format-date-time.json' : (),
          ] },
        # TODO: requires bigint support
        { file => 'integers.json', group_description => 'type checks', test_description => [
            'beyond int64 lower boundary',
            $Config{ivsize} < 8
              ? ('int64 lower boundary', 'beyond int32 lower boundary',
                'beyond int32 upper boundary', 'upper int64 boundary') : (),
            'beyond int64 upper boundary',
          ] },
        $Config{ivsize} < 8 ? { file => 'integers.json', group_description => 'int32 range checks',
          test_description => [ 'beyond lower boundary', 'beyond upper boundary' ] } : (),
        { file => 'integers.json', group_description => 'int64 range checks', test_description => [
            'beyond lower boundary',
            $Config{ivsize} < 8
              ? ('lower boundary', 'beyond lower boundary', 'beyond upper boundary', 'upper boundary') : (),
            'beyond upper boundary',
          ] },
      ] ),
    },
  );
};

my $test_sub = $ENV{AUTHOR_TESTING} ? sub { bag(@_) } : sub { superbagof(@_) };

cmp_deeply(
  \@warnings,
  $test_sub->(
    # these are all in unknownKeyword.json
    map +(
      ( re(qr/^no-longer-supported "\Q$_\E" keyword present/) ) x (4 * ($ENV{NO_SHORT_CIRCUIT} ? 1 : 2)),
    ), qw(dependencies id additionalItems $recursiveAnchor $recursiveRef),
  ),
  'got unsupported keyword warnings'.($ENV{AUTHOR_TESTING} ? '; no unexpected warnings' : ''),
);

done_testing;
__END__
see t/results/draft2020-12-additional-tests.txt for test results
