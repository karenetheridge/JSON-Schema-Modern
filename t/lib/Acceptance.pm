# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use if "$]" >= 5.022, 'experimental', 're_strict';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Safe::Isa;
use Feature::Compat::Try;
use Path::Tiny;

use if $ENV{AUTHOR_TESTING}, 'Test::Warnings' => ':fail_on_warning'; # hooks into done_testing unless overridden
use Test::JSON::Schema::Acceptance 1.013;
use Test::Memory::Cycle;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::Schema::Modern;

BEGIN {
  foreach my $env (qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING NO_TODO TEST_DIR NO_SHORT_CIRCUIT)) {
    note $env.': '.($ENV{$env} // '');
  }
  note '';
}

sub acceptance_tests {
  my (%options) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $accepter = Test::JSON::Schema::Acceptance->new(
    include_optional => 1,
    verbose => 1,
    test_schemas => -d '.git' || $ENV{AUTHOR_TESTING},
    %{$options{acceptance}},
    $ENV{TEST_DIR} ? (test_dir => $ENV{TEST_DIR})
      : $ENV{TEST_PREFIXDIR} ? (test_dir => path($ENV{TEST_PREFIXDIR}, 'tests', $options{acceptance}{specification})) : (),
  );
  $accepter = $accepter->new(%$accepter,
      test_dir => $accepter->test_dir->child($options{acceptance}{test_subdir}))
    if not $ENV{TEST_DIR} and $options{acceptance}{test_subdir};

  my $js = JSON::Schema::Modern->new(%{$options{evaluator}});
  my $js_short_circuit = $ENV{NO_SHORT_CIRCUIT} || JSON::Schema::Modern->new(%{$options{evaluator}}, short_circuit => 1);

  my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, convert_blessed => 1, canonical => 1, pretty => 1);
  $encoder->indent_length(2) if $encoder->can('indent_length');

  my $add_resource = sub {
    my ($uri, $schema) = @_;
    try {
      # suppress warnings from parsing remotes/* intended for draft <= 7 with 'definitions'
      local $SIG{__WARN__} = sub {
        warn @_ if $_[0] !~ /^no-longer-supported "definitions" keyword present/;
      } if $options{acceptance}{specification} ne 'draft7';
      $js->add_schema($uri => $schema);
      $js_short_circuit->add_schema($uri => $schema) if not $ENV{NO_SHORT_CIRCUIT};
    }
    catch ($e) {
      die $e->$_isa('JSON::Schema::Modern::Result') ? $encoder->encode($e->TO_JSON) : $e;
    }
  };

  $accepter->acceptance(
    validate_data => sub {
      my ($schema, $instance_data) = @_;
      my $result = $js->evaluate($instance_data, $schema);
      my $result_short = $ENV{NO_SHORT_CIRCUIT} || $js_short_circuit->evaluate($instance_data, $schema);

      note 'result: ', $encoder->encode($result);
      note 'short-circuited result: ', $encoder->encode($result_short)
        if not $ENV{NO_SHORT_CIRCUIT} and ($result xor $result_short);

      die 'results inconsistent between short_circuit = false and true'
        if not $ENV{NO_SHORT_CIRCUIT}
          and ($result xor $result_short)
          and not grep $_->error =~ /but short_circuit is enabled/, $result_short->errors;

      # if any errors contain an exception, generate a warning so we can be sure
      # to count that as a failure (an exception would be caught and perhaps TODO'd).
      # (This might change if tests are added that are expected to produce exceptions.)
      foreach my $r ($result, ($ENV{NO_SHORT_CIRCUIT} ? () : $result_short)) {
        warn('evaluation generated an exception: '.$encoder->encode($_))
          foreach
            grep +($_->{error} =~ /^EXCEPTION/
                && $_->{error} !~ /but short_circuit is enabled/            # unevaluated*
                && $_->{error} !~ /(max|min)imum value is not a number$/),  # optional/bignum.json
              @{$r->TO_JSON->{errors}};
      }

      $result;
    },
    add_resource => $add_resource,
    @ARGV ? (tests => { file => \@ARGV }) : (),
    %{$options{test} // {}},
  );

  memory_cycle_ok($js, 'no leaks in the main evaluator object');
  memory_cycle_ok($js_short_circuit, 'no leaks in the short-circuiting evaluator object')
    if not $ENV{NO_SHORT_CIRCUIT};

  path('t/results/'.$options{output_file})->spew_utf8($accepter->results_text)
    if -d '.git' or $ENV{AUTHOR_TESTING} or $ENV{RELEASE_TESTING};
}

1;
