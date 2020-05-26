use strict;
use warnings;
no if "$]" >= 5.031009, feature => 'indirect';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test::More;
use Test::Fatal;
use Test::Deep;
use JSON::Schema::Draft201909;

my $js = JSON::Schema::Draft201909->new;

foreach my $keyword (qw($id $anchor $recursiveRef $recursiveAnchor $vocabulary)) {
  subtest 'keyword: '.$keyword => sub {
    is(
      exception {
        my $result = $js->evaluate('hello', { $keyword => 'something' });
        cmp_deeply(
          $result->TO_JSON,
          {
            valid => bool(0),
            errors => [
              {
                instanceLocation => '',
                keywordLocation => '',
                error => 'EXCEPTION: unsupported keyword "'.$keyword.'"',
              },
            ],
          },
          'got error',
        );
      },
      undef,
      'did not get no exception',
    );
  };
}

done_testing;
