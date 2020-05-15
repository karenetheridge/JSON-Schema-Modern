use strict;
use warnings;

use Test::More;
use Test::Fatal;
use JSON::Schema::Draft201909;
use lib 't/lib';
use Helper;

my $js = JSON::Schema::Draft201909->new;

subtest 'local JSON pointer' => sub {
  ok($js->evaluate(true, { '$defs' => { true => true }, '$ref' => '#/$defs/true' }),
    'can follow local $ref to a true schema');

  ok(!$js->evaluate(true, { '$defs' => { false => false }, '$ref' => '#/$defs/false' }),
    'can follow local $ref to a false schema');

  is(
    exception {
      my $result = $js->evaluate(true, { '$ref' => '#/$defs/nowhere' });
      like(
        (($result->errors)[0])->error,
        qr{unable to resolve ref "\#/\$defs/nowhere"},
        'got error for unresolvable ref',
      );
    },
    undef,
    'no exception',
  );
};

local $TODO = 'FIXME! I dont think I like making these errors instead of exceptions';

like(
  exception { $js->evaluate(true, { '$ref' => '#foo' }) },
  qr/only same-document JSON pointers are supported in \$ref/,
  'threw exception on $ref to plain-name fragment',
);

like(
  exception { $js->evaluate(true, { '$ref' => 'http://foo/bar#/$defs/x' }) },
  qr/only same-document JSON pointers are supported in \$ref/,
  'threw exception on $ref to absolute URI',
);

done_testing;
