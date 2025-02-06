# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strict;
use warnings;
package inc::CheckConflicts;

use Moose;
with 'Dist::Zilla::Role::InstallTool';

sub setup_installer {
  my $self = shift;

  my @mfpl = grep +($_->name eq 'Makefile.PL' or $_->name eq 'Build.PL'), $self->zilla->files->@*;
  $self->log_fatal('No Makefile.PL or Build.PL was found.') if not @mfpl;

  foreach my $file (@mfpl) {
    $self->log_debug([ 'munging %s in setup_installer phase', $file->name ]);

    my $orig_content = $file->content;
    $self->log_fatal('could not find position in ' . $file->name . ' to modify!')
      if not $orig_content =~ m/use strict;\nuse warnings;\n\n/g;

    my $pos = pos($orig_content);

    my $content = <<'CONTENT';
if ("$]" < 5.038) {
  die "This distribution will not install where builtin::Backport exists.\n"
    if eval { +require builtin::Backport; 1 };
}
CONTENT

    $file->content(substr($orig_content, 0, $pos) . $content . substr($orig_content, $pos));
  }

  return;
}

1;
