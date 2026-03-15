# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use 5.020;
package inc::TestWithoutOptionalModules;

use Moose;
with 'Dist::Zilla::Role::TestRunner';
use Config;

# cribbed from Dist::Zilla::Plugin::MakeMaker::Runner
sub test {
  my ($self, $target, $arg) = @_;

  # assumes 'make' has already been run
  my $make = $Config{make} || 'make';

  my $job_count = $arg && exists $arg->{jobs}
                ? $arg->{jobs}
                : $self->default_jobs;

  my $jobs = "j$job_count";
  my $ho = "HARNESS_OPTIONS";
  local $ENV{$ho} = $ENV{$ho} ? "$ENV{$ho}:$jobs" : $jobs;

  local $ENV{NO_OPTIONAL_MODULES} = 1;
  local $ENV{DEVEL_HIDE_VERBOSE} = 0;

  $self->log(join(' ', "running $make test", ( $self->zilla->logger->get_debug ? 'TEST_VERBOSE=1' : () ), 'with NO_OPTIONAL_MODULES=1'));
  system($make, 'test',
    ( $self->zilla->logger->get_debug || $arg->{test_verbose} ? 'TEST_VERBOSE=1' : () ),
  ) and die "error running $make test\n";

  return;
}

1;
