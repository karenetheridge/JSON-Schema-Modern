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

use Test2::Warnings qw(warnings :no_end_test had_no_warnings);
use lib 't/lib';
use Helper;

my %strings = (
  id => qr/^no-longer-supported "id" keyword present \(at location ""\): this should be rewritten as "\$id" at /,
  definitions => qr/^no-longer-supported "definitions" keyword present \(at location ""\): this should be rewritten as "\$defs" at /,
  dependencies => qr/^no-longer-supported "dependencies" keyword present \(at location ""\): this should be rewritten as "dependentSchemas" or "dependentRequired" at /,
);

my %schemas = (
  id => 'https://localhost:1234',
  definitions => {},
  dependencies => {},
);

my @warnings = (
  [ draft6 => [ qw(id) ] ],
  [ draft7 => [ qw(id) ] ],
  [ 'draft2019-09' => [ qw(id definitions dependencies) ] ],
);

foreach my $index (0 .. $#warnings) {
  my ($spec_version, $removed_keywords) = $warnings[$index]->@*;

  note "\n", $spec_version;
  my $js = JSON::Schema::Modern->new(specification_version => $spec_version);
  foreach my $keyword (@$removed_keywords) {
    cmp_result(
      [ warnings {
          cmp_result(
            $js->evaluate(true, { $keyword => $schemas{$keyword} })->TO_JSON,
            { valid => true },
            'schema with "'.$keyword.'" still validates in '.$spec_version,
          )
        } ],
      superbagof(re($strings{$keyword})),
      'warned for "'.$keyword.'" in '.$spec_version,
    );
  }

  next if $index == $#warnings;
  my ($next_spec_version, $removed_next_keywords) = $warnings[$index+1]->@*;
  foreach my $keyword (@$removed_next_keywords) {
    next if grep $keyword eq $_, @$removed_keywords;
    local $SIG{__WARN__} = sub {
      warn @_ if $_[0] =~ /^no-longer-supported "$keyword" keyword present/;
    };
    cmp_result(
      [ warnings {
          cmp_result(
            $js->evaluate(true, { $keyword => $schemas{$keyword} })->TO_JSON,
            { valid => true },
            'schema with "'.$keyword.'" validates in '.$spec_version,
          )
        } ],
      [],
      'did not warn for "'.$keyword.'" in '.$spec_version,
    );
  }
}

had_no_warnings if $ENV{AUTHOR_TESTING};
done_testing;
