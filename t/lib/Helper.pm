# no package, so things defined here appear in the namespace of the parent.
use strictures 2;
use 5.020;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::PP ();
use constant { true => JSON::PP::true, false => JSON::PP::false };

my $encoder = JSON::Schema::Modern::_JSON_BACKEND()->new
  ->allow_nonref(1)
  ->utf8(0)
  ->allow_bignum(1)
  ->convert_blessed(1);

# like sprintf, but all list items are JSON-encoded. assumes placeholders are %s!
sub json_sprintf {
  sprintf(shift, map +(ref($_) =~ /^Math::Big(Int|Float)$/ ? ref($_).'->new(\''.$_.'\')' : $encoder->encode($_)), @_);
}

1;
