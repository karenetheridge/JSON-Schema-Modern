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

use Safe::Isa;
use Feature::Compat::Try;
use Path::Tiny;

use if $ENV{AUTHOR_TESTING}, 'Test::Warnings' => ':fail_on_warning'; # hooks into done_testing unless overridden
use Test::JSON::Schema::Acceptance 1.029;
use Test::Memory::Cycle;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::Schema::Modern;

# supports options:
# - acceptance: options passed to Test::JSON::Schema::Acceptance constructor
# - evaluator: options passed to JSON::Schema::Modern constructor
# - tests: options passed to Test::JSON::Schema::Acceptance::acceptance method
# - output_file: filename to print results to (default: none)
sub acceptance_tests (%options) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $note = $ENV{AUTHOR_TESTING} || $ENV{AUTOMATED_TESTING} ? \&diag : \&note;
  $note->('');
  foreach my $env (qw(AUTHOR_TESTING AUTOMATED_TESTING EXTENDED_TESTING NO_TODO TEST_DIR NO_SHORT_CIRCUIT)) {
    $note->($env.': '.($ENV{$env} // '<undef>'));
  }
  $note->('');

  my $accepter = Test::JSON::Schema::Acceptance->new(
    include_optional => 1,
    verbose => $ENV{AUTOMATED_TESTING},
    test_schemas => $ENV{AUTHOR_TESTING},
    $options{acceptance}->%*,
    $ENV{TEST_DIR} ? (test_dir => $ENV{TEST_DIR})
      : $ENV{TEST_PREFIXDIR} ? (test_dir => path($ENV{TEST_PREFIXDIR}, 'tests', $options{acceptance}{specification})) : (),
    supported_specifications => [ qw(draft4 draft6 draft7 draft2019-09 draft2020-12) ],
  );
  $accepter = $accepter->new(%$accepter,
      test_dir => $accepter->test_dir->child($options{acceptance}{test_subdir}))
    if not $ENV{TEST_DIR} and $options{acceptance}{test_subdir};
  $accepter->json_decoder->allow_bignum if Test::JSON::Schema::Acceptance->VERSION < '1.022';

  my $js = JSON::Schema::Modern->new($options{evaluator}->%*);
  my $js_short_circuit = $ENV{NO_SHORT_CIRCUIT} || JSON::Schema::Modern->new($options{evaluator}->%*, short_circuit => 1);

  my $add_resource = sub ($uri, $schema, %resource_options) {
    return if $uri =~ m{/draft-next/};
    try {
      # suppress warnings from parsing remotes/* intended for draft <= 7 with 'definitions'
      local $SIG{__WARN__} = sub {
        warn @_ if $_[0] !~ /^no-longer-supported "definitions" keyword present/;
      } if $options{acceptance}{specification} !~ /^draft[467]$/
          and Test::JSON::Schema::Acceptance->VERSION < '1.028';

      my $doc = my $document = JSON::Schema::Modern::Document->new(
        schema => $schema,
        evaluator => $js,
        %resource_options,
      );

      $js->add_document($uri => $doc);
      $js_short_circuit->add_document($uri => $doc) if not $ENV{NO_SHORT_CIRCUIT};
    }
    catch ($e) {
      die $e->$_isa('JSON::Schema::Modern::Result') ? $e->dump : $e;
    }
  };

  $accepter->acceptance(
    validate_data => sub ($schema, $instance_data) {
      my $result = $js->evaluate($instance_data, $schema);
      my $result_short = $ENV{NO_SHORT_CIRCUIT} || $js_short_circuit->evaluate($instance_data, $schema);
      die 'result is not a JSON::Schema::Modern::Result object'
        if not $result->isa('JSON::Schema::Modern::Result');

      note 'result: ', $result->dump;

      if (not $ENV{NO_SHORT_CIRCUIT}) {
        die 'short-circuited result is not a JSON::Schema::Modern::Result object'
          if not $result_short->isa('JSON::Schema::Modern::Result');
        note 'short-circuited result: ', $result_short->dump;
        die 'results inconsistent between short_circuit = false and true'
          if ($result->valid xor $result_short->valid);
      }

      my $in_todo;

      # if any errors contain an exception, generate a warning so we can be sure
      # to count that as a failure (an exception would be caught and perhaps TODO'd).
      # (This might change if tests are added that are expected to produce exceptions.)
      foreach my $r ($result, ($ENV{NO_SHORT_CIRCUIT} ? () : $result_short)) {
        diag 'evaluation generated an exception: '.$_->dump
          foreach
            grep +($_->{error} =~ /^EXCEPTION/
                && $_->{error} !~ /(max|min)imum value is not a number$/)   # optional/bignum.json
                && !($in_todo //= grep $_->{todo}, Test2::API::test2_stack->top->{_pre_filters}->@*),
              $r->errors;
      }

      ($result->valid, $result->TO_JSON);
    },
    add_resource => $add_resource,
    @ARGV ? (tests => { file => \@ARGV }) : (),
    ($options{test} // {})->%*,
  );

  memory_cycle_ok($js, 'no leaks in the main evaluator object');
  memory_cycle_ok($js_short_circuit, 'no leaks in the short-circuiting evaluator object')
    if not $ENV{NO_SHORT_CIRCUIT};

  path('t/results/'.$options{output_file})->spew_utf8($accepter->results_text)
    if $ENV{AUTHOR_TESTING};
}

1;
