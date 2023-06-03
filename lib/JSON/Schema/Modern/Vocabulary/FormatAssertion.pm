use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::FormatAssertion;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Format-Assertion vocabulary

our $VERSION = '0.568';

use 5.020;
use Moo;
use strictures 2;
use experimental qw(signatures postderef);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::Schema::Modern::Utilities qw(is_type E A assert_keyword_type abort);
use Feature::Compat::Try;
use namespace::clean;

with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://json-schema.org/draft/2020-12/vocab/format-assertion' => 'draft2020-12';
}

sub evaluation_order { 2 }

sub keywords {
  qw(format);
}

{
  # for now, all built-in formats are constrained to the 'string' type

  my $is_datetime = sub {
    eval { Time::Moment->from_string(uc($_[0])) } ? 1 : 0,
  };
  my $is_email = sub {
    Email::Address::XS->parse($_[0])->is_valid;
  };
  my $is_hostname = sub {
    Data::Validate::Domain::is_domain($_[0]);
  };
  my $idn_decode = sub {
    try { return Net::IDN::Encode::domain_to_ascii($_[0]) } catch ($e) { return $_[0]; }
  };
  my $is_ipv4 = sub {
    my @o = split(/\./, $_[0], 5);
    @o == 4 && (grep /^(?:0|[1-9][0-9]{0,2})$/, @o) == 4 && (grep $_ < 256, @o) == 4;
  };
  # https://tools.ietf.org/html/rfc3339#appendix-A with some additions for the 2000 version
  # as defined in https://en.wikipedia.org/wiki/ISO_8601#Durations
  my $duration_re = do {
    my $num = qr{[0-9]+(?:[.,][0-9]+)?};
    my $second = qr{${num}S};
    my $minute = qr{${num}M};
    my $hour = qr{${num}H};
    my $time = qr{T(?=[0-9])(?:$hour)?(?:$minute)?(?:$second)?};
    my $day = qr{${num}D};
    my $month = qr{${num}M};
    my $year = qr{${num}Y};
    my $week = qr{${num}W};
    my $date = qr{(?=[0-9])(?:$year)?(?:$month)?(?:$day)?};
    qr{^P(?:(?=.)(?:$date)?(?:$time)?|$week)$};
  };

  my $formats = +{
    'date-time' => sub {
      $is_datetime->($_[0]) || (
        $_[0] =~ m/^(?:\d{4}-\d\d-\d\dT\d\d:\d\d):(\d\d)(?:\.\d+)?(?:[Zz]|[+-]\d\d:\d\d)$/a
          && $1 eq '60'
          && do {
            require DateTime::Format::RFC3339;
            eval { DateTime::Format::RFC3339->parse_datetime($_[0]) };
          });
    },
    date => sub { $_[0] =~ /^\d{4}-(?:\d\d)-(?:\d\d)$/a && $is_datetime->($_[0].'T00:00:00Z') },
    time => sub {
      return if $_[0] !~ /^(\d\d):(\d\d):(\d\d)(?:\.\d+)?([Zz]|([+-])(\d\d):(\d\d))$/a
        or $1 > 23
        or $2 > 59
        or $3 > 60
        or (defined($6) and $6 > 23)
        or (defined($7) and $7 > 59);

      return 1 if $3 <= 59;
      return $1 == 23 && $2 == 59 if uc($4) eq 'Z';

      my $sign = $5 eq '+' ? 1 : -1;
      my $hour_zulu = $1 - $6*$sign;
      my $min_zulu = $2 - $7*$sign;
      $hour_zulu -= 1 if $min_zulu < 0;

      return $hour_zulu%24 == 23 && $min_zulu%60 == 59;
    },
    duration => sub { $_[0] =~ $duration_re && $_[0] !~ m{[.,][0-9]+[A-Z].} },
    email => sub { $is_email->($_[0]) && $_[0] !~ /[^[:ascii:]]/ },
    'idn-email' => $is_email,
    hostname => $is_hostname,
    'idn-hostname' => sub { $is_hostname->($idn_decode->($_[0])) },
    ipv4 => $is_ipv4,
    ipv6 => sub {
      ($_[0] =~ /^(?:[[:xdigit:]]{0,4}:){0,7}[[:xdigit:]]{0,4}$/
        || $_[0] =~ /^(?:[[:xdigit:]]{0,4}:){1,6}((?:[0-9]{1,3}\.){3}[0-9]{1,3})$/
            && $is_ipv4->($1))
        && $_[0] !~ /:::/
        && $_[0] !~ /^:[^:]/
        && $_[0] !~ /[^:]:$/
        && do {
          my $double_colons = ()= ($_[0] =~ /::/g);
          my $colon_components = grep length, split(/:+/, $_[0], -1);
          $double_colons < 2 && ($double_colons > 0
            || ($colon_components == 8 && !defined $1)
            || ($colon_components == 7 && defined $1))
        };
    },
    uri => sub {
      my $uri = Mojo::URL->new($_[0]);
      fc($uri->to_unsafe_string) eq fc($_[0]) && $uri->is_abs && $_[0] !~ /[^[:ascii:]]/;
    },
    'uri-reference' => sub {
      fc(Mojo::URL->new($_[0])->to_unsafe_string) eq fc($_[0]) && $_[0] !~ /[^[:ascii:]]/;
    },
    iri => sub { Mojo::URL->new($_[0])->is_abs },
    uuid => sub { $_[0] =~ /^[[:xdigit:]]{8}-(?:[[:xdigit:]]{4}-){3}[[:xdigit:]]{12}$/ },
    'json-pointer' => sub { (!length($_[0]) || $_[0] =~ m{^/}) && $_[0] !~ m{~(?![01])} },
    'relative-json-pointer' => sub { $_[0] =~ m{^(?:0|[1-9][0-9]*)(?:#$|$|/)} && $_[0] !~ m{~(?![01])} },
    regex => sub {
      local $SIG{__WARN__} = sub { die @_ };
      eval { qr/$_[0]/; 1 ? 1 : 0 };
    },

    'iri-reference' => sub { 1 },
    'uri-template' => sub { 1 },
  };

  sub _get_default_format_validation ($self, $format) {
    return $formats->{$format};
  }
}

sub _traverse_keyword_format ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_format ($self, $data, $schema, $state) {
  abort($state, 'unimplemented format "%s"', $schema->{format})
    if $schema->{format} eq 'uri-template';

  try {
    if ($schema->{format} eq 'date-time' or $schema->{format} eq 'date') {
      require Time::Moment;
    }
    elsif ($schema->{format} eq 'email' or $schema->{format} eq 'idn-email') {
      require Email::Address::XS; Email::Address::XS->VERSION(1.04);
    }
    elsif ($schema->{format} eq 'hostname' or $schema->{format} eq 'idn-hostname') {
      require Data::Validate::Domain;
    }
    elsif ($schema->{format} eq 'idn-hostname') {
      require Net::IDN::Encode;
    }
  }
  catch ($e) {
    abort($state, 'EXCEPTION: cannot validate format "%s": %s', $schema->{format}, $e);
  }

  # first check the subrefs from JSON::Schema::Modern->new(format_evaluations => { ... })
  # and add in the type if needed
  my $evaluator_spec = $state->{evaluator}->_get_format_validation($schema->{format});
  my $default_spec = $self->_get_default_format_validation($schema->{format});

  my $spec =
    $evaluator_spec ? ($default_spec ? +{ type => 'string', sub => $evaluator_spec } : $evaluator_spec)
      : $default_spec ? +{ type => 'string', sub => $default_spec }
      : undef;

  A($state, $schema->{format});
  return E($state, 'not a%s %s', $schema->{format} =~ /^[aeio]/ ? 'n' : '', $schema->{format})
    if $spec and is_type($spec->{type}, $data) and not $spec->{sub}->($data);

  return 1;
}

1;
__END__

=pod

=for Pod::Coverage vocabulary evaluation_order keywords

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2020-12 "Format-Assertion" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2020-12/vocab/format-assertion> and formally specified in
L<https://json-schema.org/draft/2020-12/json-schema-validation.html#section-7>.

Support is also provided for

=for :list
* the equivalent Draft 2019-09 keyword, indicated in metaschemas
  with the URI C<https://json-schema.org/draft/2019-09/vocab/format> and formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-02#section-7>.
* the equivalent Draft 7 keyword, as formally specified in
  L<https://datatracker.ietf.org/doc/html/draft-handrews-json-schema-validation-01#section-7>.

Assertion behaviour can be enabled by
L<https://json-schema.org/draft/2020-12/json-schema-core.html#rfc.section.8.1.2/referencing this vocabulary explicitly>
in a metaschema's C<$vocabulary> keyword, or by toggling the
L<JSON::Schema::Modern/validate_formats> option.

Overrides to particular format implementations, or additions of new ones, can be done through
L<JSON::Schema::Modern/format_validations>.

Format C<uri-template> is not yet implemented.
Use of this format will always result in an error.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Modern/Format Validation>

=head1 SUPPORT

You can also find me on the L<JSON Schema Slack server|https://json-schema.slack.com> and L<OpenAPI Slack
server|https://open-api.slack.com>, which are also great resources for finding help.

=for stopwords OpenAPI

=cut
