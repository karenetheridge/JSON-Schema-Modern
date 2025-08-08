---
name: Bug report
about: File a bug report
title: ''
labels: ''
assignees: ''

---
When filing a bug, please be sure to include the installed version of this
distribution, the Perl version, and your operating system/architecture.

If the bug is due to failing unit tests, such as from installation, please
include the output of **all** tests. If you use `cpanm` you can get this from
your local `build.log`.

If the distribution is already installed, it is still helpful to re-install it
(e.g. via `cpanm --reinstall JSON::Schema::Modern`) in order to generate
useful diagnostic data, such as the installed versions of all dependencies.
This may also give you enough information to diagnose the problem yourself --
pay close attention to the output from `t/zzz-check-breaks.t`.

Also, include any other information needed to reproduce your issue.
