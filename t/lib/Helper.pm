# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
# no package, so things defined here appear in the namespace of the parent.
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

use Test2::V0 qw(!bag !bool !warnings), -no_pragmas => 1;  # prefer Test::Deep's versions of these exports
use if $ENV{AUTHOR_TESTING}, 'Test2::Warnings';
use if $ENV{AUTHOR_TESTING} && (caller(2))[1] !~ /acceptance/, 'Test2::Plugin::BailOnFail';
use Test::Deep qw(!array !hash !blessed); # import symbols: ignore, re etc
use Test2::API 'context_do';
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::Schema::Modern;
use JSON::Schema::Modern::Utilities qw(jsonp true false);

my $encoder = JSON::Schema::Modern::_JSON_BACKEND()->new
  ->allow_nonref(1)
  ->utf8(0)
  ->allow_bignum(1)
  ->allow_blessed(1)
  ->convert_blessed(1)
  ->canonical(1)
  ->pretty(1)
  ->indent_length(2);

# like sprintf, but all list items are JSON-encoded. assumes placeholders are %s!
sub json_sprintf {
  sprintf(shift, map +(ref($_) =~ /^Math::Big(?:Int|Float)$/ ? ref($_).'->new(\''.$_.'\')' : $encoder->indent(0)->encode($_)), @_);
}

# deep comparison, with Test::Deep syntax sugar
sub cmp_result ($got, $expected, $test_name) {
  context_do {
    my $ctx = shift;
    my ($got, $expected, $test_name) = @_;
    my ($equal, $stack) = Test::Deep::cmp_details($got, $expected);
    if ($equal) {
      $ctx->pass($test_name);
    }
    else {
      $ctx->fail($test_name);
      my $method =
        # be less noisy for expected failures
        (grep $_->{todo}, Test2::API::test2_stack->top->{_pre_filters}->@*) ? 'note'
          : $ENV{AUTHOR_TESTING} || $ENV{AUTOMATED_TESTING} ? 'diag' : 'note';
      $ctx->$method(Test::Deep::deep_diag($stack));
      $ctx->$method("got result:\n".$encoder->encode($got));
    }
    return $equal;
  } $got, $expected, $test_name;
}

sub is_passing () {
  context_do { shift->hub->is_passing };
}

1;
