use strict;
use warnings;
package JSON::Schema::Draft201909::Vocabulary::Format;
# vim: set ts=8 sts=2 sw=2 tw=100 et :
# ABSTRACT: Implementation of the JSON Schema Draft 2019-09 Format vocabulary

our $VERSION = '0.021';

use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
use JSON::Schema::Draft201909::Utilities qw(is_type E A assert_keyword_type);
use Moo;
use strictures 2;
use MooX::TypeTiny 0.002002;
use MooX::HandlesVia;
use Types::Standard 1.010002 qw(HashRef Dict Enum CodeRef);
use Syntax::Keyword::Try 0.11;
use namespace::clean;

with 'JSON::Schema::Draft201909::Vocabulary';

sub vocabulary { 'https://json-schema.org/draft/2019-09/vocab/format' }

sub keywords {
  qw(format);
}

has _format_validations => (
  is => 'bare',
  isa => HashRef[Dict[
      type => Enum[qw(null object array boolean string number integer)],
      sub => CodeRef,
    ]],
  init_arg => undef,
  handles_via => 'Hash',
  handles => {
    _get_format_validation => 'get',
  },
  lazy => 1,
  default => sub {
    my $self = shift;

    my $is_datetime = sub {
      eval { require Time::Moment; 1 } or return 1;
      eval { Time::Moment->from_string($_[0]) } ? 1 : 0,
    };
    my $is_email = sub {
      eval { require Email::Address::XS; Email::Address::XS->VERSION(1.01); 1 } or return 1;
      Email::Address::XS->parse($_[0])->is_valid;
    };
    my $is_hostname = sub {
      eval { require Data::Validate::Domain; 1 } or return 1;
      Data::Validate::Domain::is_domain($_[0]);
    };
    my $idn_decode = sub {
      eval { require Net::IDN::Encode; 1 } or return $_[0];
      try { return Net::IDN::Encode::domain_to_ascii($_[0]) } catch { return $_[0]; }
    };
    my $is_ipv4 = sub {
      my @o = split(/\./, $_[0], 5);
      @o == 4 && (grep /^[0-9]{1,3}$/, @o) == 4 && (grep $_ < 256, @o) == 4;
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

    # all built-in formats are constrained to the 'string' type
    my $formats = +{
      'date-time' => $is_datetime,
      date => sub { $is_datetime->($_[0].'T00:00:00Z') },
      time => sub { $is_datetime->('2000-01-01T'.$_[0]) },
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
      regex => sub { eval { qr/$_[0]/; 1 ? 1 : 0 } },

      # TODO: if the metaschema's $vocabulary entry is true, then we must die on
      # encountering these unimplemented formats.
      'iri-reference' => sub { 1 },
      'uri-template' => sub { 1 },
    };

    # the subrefs from JSON::Schema::Draft201909->new(format_evaluations => { ... })
    my $args = +{ $self->evaluator->_format_validations };

    return +{
      map +(
        $_ => exists $formats->{$_}
          ? +{ type => 'string', sub => $args->{$_} // $formats->{$_} }
          : $args->{$_}
      ), keys %$formats, keys %$args
    };
  },
);

sub _traverse_keyword_format {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  # TODO: if the metaschema's $vocabulary entry is true, then we must die on
  # encountering unimplemented formats specified by the vocabulary (iri-reference, uri-template).
}

sub _eval_keyword_format {
  my ($self, $data, $schema, $state) = @_;

  if ($state->{validate_formats}
      and my $spec = $self->_get_format_validation($schema->{format})) {
    return E($state, 'not a%s %s', $schema->{format} =~ /^[aeio]/ ? 'n' : '', $schema->{format})
      if is_type($spec->{type}, $data) and not $spec->{sub}->($data);
  }

  return A($state, $schema->{format});
}

1;
__END__

=pod

=for Pod::Coverage vocabulary keywords evaluator

=head1 DESCRIPTION

=for stopwords metaschema

Implementation of the JSON Schema Draft 2019-09 "Format" vocabulary, indicated in metaschemas
with the URI C<https://json-schema.org/draft/2019-09/vocab/format> and formally specified in
L<https://json-schema.org/draft/2019-09/json-schema-validation.html#rfc.section.7>.

Overrides to particular format implementations, or additions of new ones, can be done through
L<JSON::Schema::Draft201909/format_validations>.

=head1 SEE ALSO

=for :list
* L<JSON::Schema::Draft201909/Format Validation>

=cut
