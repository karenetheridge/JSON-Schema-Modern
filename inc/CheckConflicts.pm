# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
package inc::CheckConflicts;

use Moose;
extends 'Dist::Zilla::Plugin::Conflicts';

# like [Conflicts], except:
# - we die instead of warn in Makefile.PL and Build.PL when conflicts are detected
# - the Conflicts check only runs for perls < 5.38 (which is when builtin::Backport is active)
# - the Conflicts module is defined inline, and contains no -also clause
# - we manually populate metadata with x_breaks

sub gather_files {}

sub metadata {} # we add to x_breaks in dist.ini

around _check_conflicts_sub => sub {
  my $orig = shift;
  my $self = shift;

  my $content = $self->$orig(@_);

  $content =~ s/sub check_conflicts \{\K/\n    return if "\$\]" >= 5.038;\n/;
  $content =~ s/\bwarn /die /;

  $content =~ s/eval \{\K require [^}]+ \}/
package JSON::Schema::Modern::Conflicts;
require Dist::CheckConflicts;
Dist::CheckConflicts->import(
  -dist => 'JSON::Schema::Modern',
  -conflicts => { 'builtin::Backport' => '0.02' }
); 1;
}
/;

  return $content;
};

1;
