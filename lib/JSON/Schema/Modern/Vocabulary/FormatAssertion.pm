use strict;
use warnings;
package JSON::Schema::Modern::Vocabulary::FormatAssertion;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Format-Assertion vocabulary

our $VERSION = '0.587';

use 5.020;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use JSON::Schema::Modern::Utilities qw(get_type E A assert_keyword_type abort);
use Feature::Compat::Try;
use List::Util 'any';
use Ref::Util 0.100 'is_plain_arrayref';
use Scalar::Util 'looks_like_number';
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
  # https://datatracker.ietf.org/doc/html/rfc3339#appendix-A with some additions for the 2000 version
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
      # https://www.rfc-editor.org/rfc/rfc3339.html#section-5.6
      $_[0] =~ m/^\d{4}-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:Z|[+-](\d\d):(\d\d))$/ia
        && $1 >= 1 && $1 <= 12        # date-month
        && $2 >= 1 && $2 <= 31        # date-mday
        && $3 <= 23                   # time-hour
        && $4 <= 59                   # time-minute
        && $5 <= 60                   # time-second
        && (!defined $6 || $6 <= 23)  # time-hour in time-numoffset
        && (!defined $7 || $7 <= 59)  # time-minute in time-numoffset

        # Time::Moment does month+day sanity check (with leap years), but not leap seconds
        && ($5 <= 59 && eval { Time::Moment->from_string(uc($_[0])) }
          || do {
            require DateTime::Format::RFC3339;
            eval { DateTime::Format::RFC3339->parse_datetime($_[0]) };
        });
    },
    date => sub {
      # https://www.rfc-editor.org/rfc/rfc3339.html#section-5.6 full-date
      $_[0] =~ m/^(\d{4})-(\d\d)-(\d\d)$/a
        && $2 >= 1 && $2 <= 12        # date-month
        && $3 >= 1 && $3 <= 31        # date-mday
        && eval { Time::Moment->new(year => $1, month => $2, day => $3) };
    },
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
      ($_[0] =~ /^(?:[[:xdigit:]]{0,4}:){0,8}[[:xdigit:]]{0,4}$/
        || $_[0] =~ /^(?:[[:xdigit:]]{0,4}:){1,6}((?:[0-9]{1,3}\.){3}[0-9]{1,3})$/
            && $is_ipv4->($1))
        && $_[0] !~ /:::/
        && $_[0] !~ /^:[^:]/
        && $_[0] !~ /[^:]:$/
        && do {
          my $double_colons = ()= ($_[0] =~ /::/g);
          my $colon_components = grep length, split(/:+/, $_[0], -1);
          ($double_colons == 1
            && ((!defined $1 && $colon_components < 8) || (defined $1 && $colon_components < 7)))
            ||
          ($double_colons == 0
            && ((!defined $1 && $colon_components == 8) || (defined $1 && $colon_components == 7)));
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
      eval { qr/$_[0]/; 1 };
    },

    'iri-reference' => sub { 1 },
    'uri-template' => sub { 1 },
  };

  my %formats_by_spec_version = (
    draft7 => [qw(
      date-time
      date
      time
      email
      idn-email
      hostname
      idn-hostname
      ipv4
      ipv6
      uri
      uri-reference
      iri
      json-pointer
      relative-json-pointer
      regex
      iri-reference
      uri-template
    )],
  );
  $formats_by_spec_version{'draft2019-09'} =
  $formats_by_spec_version{'draft2020-12'} = [$formats_by_spec_version{draft7}->@*, qw(duration uuid)];

  sub _get_default_format_validation ($class, $state, $format) {
    # all core formats are of type string (so far)
    return { type => 'string', sub => $formats->{$format} }
      if grep $format eq $_, $formats_by_spec_version{$state->{spec_version}}->@*;
  }
}

# common code between FormatAnnotation+validate_formats and FormatAssertion paths
sub _get_format_definition ($class, $schema, $state) {
  try {
    if ($schema->{format} eq 'date-time' or $schema->{format} eq 'date') {
      require Time::Moment;
    }
    elsif ($schema->{format} eq 'email' or $schema->{format} eq 'idn-email') {
      require Email::Address::XS; Email::Address::XS->VERSION(1.04);
    }
    # FIXME:
    # draft7 hostname uses RFC1034
    # draft2019-09+ hostname uses RFC1123
    elsif ($schema->{format} eq 'hostname' or $schema->{format} eq 'idn-hostname') {
      require Data::Validate::Domain;
    }

    if ($schema->{format} eq 'idn-hostname') {
      require Net::IDN::Encode;
    }
  }
  catch ($e) {
    abort($state, 'EXCEPTION: cannot validate with format "%s": %s', $schema->{format}, $e);
  }

  return $state->{evaluator}->_get_format_validation($schema->{format})
    // $class->_get_default_format_validation($state, $schema->{format});
}

sub _traverse_keyword_format ($class, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return E($state, 'unimplemented format "%s"', $schema->{format})
    if $schema->{format} eq 'uri-template';

  return E($state, 'unimplemented custom format "%s"', $schema->{format})
    if not grep $state->{spec_version} eq $_, qw(draft7 draft2019-09)
      and not $class->_get_default_format_validation($state, $schema->{format})
      and not $state->{evaluator}->_get_format_validation($schema->{format});

  return 1;
}

# Note that this method is only callable in draft2020-12 and later, because this vocabulary does not
# exist in previous versions
sub _eval_keyword_format ($class, $data, $schema, $state) {
  A($state, $schema->{format});

  # §7.2.2 (draft2020-12) "When the Format-Assertion vocabulary is declared with a value of true,
  # implementations MUST provide full validation support for all of the formats defined by this
  # specification. Implementations that cannot provide full validation support MUST refuse to
  # process the schema."
  abort($state, 'unimplemented format "%s"', $schema->{format})
    if $schema->{format} eq 'uri-template';

  my $spec = $class->_get_format_definition($schema, $state);

  # §7.2.3 (draft2020-12) "When the Format-Assertion vocabulary is specified, implementations MUST
  # fail upon encountering unknown formats."
  abort($state, 'unimplemented custom format "%s"', $schema->{format}) if not $spec;

  my $type = get_type($data);
  $type = 'number' if $type eq 'integer';

  return 1 if
    not is_plain_arrayref($spec->{type}) ? any { $type eq $_ } $spec->{type}->@* : $type eq $spec->{type}
    and not ($state->{stringy_numbers} and $type eq 'string'
      and is_plain_arrayref($spec->{type}) ? any { $_ eq 'number' } $spec->{type}->@* : $spec->{type} eq 'number'
      and looks_like_number($data));

  return E($state, 'not a valid %s', $schema->{format}) if not $spec->{sub}->($data);
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

=cut
