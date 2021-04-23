# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings' => ':fail_on_warning';
use Test::JSON::Schema::Acceptance 1.008;
use Test::Memory::Cycle;
use Path::Tiny;
use JSON::Schema::Draft201909;

my $accepter = Test::JSON::Schema::Acceptance->new(
  specification => 'draft2019-09',
  test_dir => 't/additional-tests',
  verbose => 1,
  test_schemas => -d '.git' || $ENV{AUTHOR_TESTING},
);

plan skip_all => 'no tests in this directory to test' if not @{$accepter->_test_data};

my %options = (validate_formats => 1);
my $js = JSON::Schema::Draft201909->new(%options);
my $js_short_circuit = JSON::Schema::Draft201909->new(%options, short_circuit => 1);
my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, convert_blessed => 1, canonical => 1, pretty => 1);
$encoder->indent_length(2) if $encoder->can('indent_length');

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
      map warn('evaluation generated an exception: '.$encoder->encode($_)),
        grep $_->{error} =~ /^EXCEPTION/
            && $_->{error} !~ /but short_circuit is enabled/,         # unevaluated*
          @{$r->TO_JSON->{errors}};
    }

    $result;
  },
  @ARGV ? (tests => { file => \@ARGV }) : (),
);

memory_cycle_ok($js, 'no leaks in the main evaluator object');
memory_cycle_ok($js_short_circuit, 'no leaks in the short-circuiting evaluator object');

path('t/results/additional-tests.txt')->spew_utf8($accepter->results_text)
  if -d '.git' or $ENV{AUTHOR_TESTING} or $ENV{RELEASE_TESTING};

done_testing;
__END__
see t/results/additional-tests.txt for test results
