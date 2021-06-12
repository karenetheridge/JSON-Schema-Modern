use strict;
use warnings;
use 5.016;
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More 0.96;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Modern;
use lib 't/lib';
use Helper;

{
  like(
    exception { ()= JSON::Schema::Modern->new(specification_version => 'ohhai')->evaluate(true, true) },
    qr/^Value "ohhai" did not pass type constraint/,
    'unrecognized $SPECIFICATION_VERSION',
  );
}

subtest '$schema' => sub {
  cmp_deeply(
    JSON::Schema::Modern->new->evaluate(
      true,
      { '$schema' => 'http://wrong/url' },
    )->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '/$schema',
          error => re(qr/^custom \$schema URIs are not yet supported \(must be one of: /),
        },
      ],
    },
    '$schema, when set, must contain a recognizable URI',
  );
};

done_testing;
