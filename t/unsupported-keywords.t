use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use Test::Warnings qw(warnings :no_end_test had_no_warnings);
use Test::Deep;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

my %warnings = (
  definitions => qr/^no-longer-supported "definitions" keyword present \(at location ""\): this should be rewritten as "\$defs" at /,
  dependencies => qr/^no-longer-supported "dependencies" keyword present \(at location ""\): this should be rewritten as "dependentSchemas" or "dependentRequired" at /,
);

my $js = JSON::Schema::Modern->new;

foreach my $keyword (keys %warnings) {
  cmp_deeply(
    [ warnings { ok($js->evaluate(true, { $keyword => 1 }), 'schema with '.$keyword.' still validates') } ],
    [ re($warnings{$keyword}), ],
    'warned for '.$keyword,
  );
}

had_no_warnings if $ENV{AUTHOR_TESTING};
done_testing;
