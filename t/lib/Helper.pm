use strictures 2;
# no package, so things defined here appear in the namespace of the parent.

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Deep;
use JSON::Schema::Modern;
use Test::File::ShareDir -share => { -dist => { 'JSON-Schema-Modern' => 'share' } };
use JSON::PP ();
use constant { true => JSON::PP::true, false => JSON::PP::false };

use JSON::MaybeXS;
my $encoder = JSON::MaybeXS->new(allow_nonref => 1, utf8 => 0, allow_bignum => 1, convert_blessed => 1);

# like sprintf, but all list items are JSON-encoded. assumes placeholders are %s!
sub json_sprintf {
  sprintf(shift, map +(ref($_) =~ /^Math::Big(Int|Float)$/ ? ref($_).'->new(\''.$_.'\')' : $encoder->encode($_)), @_);
}

1;
