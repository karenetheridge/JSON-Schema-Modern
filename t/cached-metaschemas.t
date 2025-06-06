# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use List::Util 'unpairs';

use constant METASCHEMA => 'https://json-schema.org/draft/2019-09/schema';

use lib 't/lib';
use Helper;

# spec version -> vocab classes
my %vocabularies = unpairs(JSON::Schema::Modern->new->__all_metaschema_vocabulary_classes);

subtest 'load cached metaschema' => sub {
  my $js = JSON::Schema::Modern->new;

  cmp_result(
    $js->_get_resource(METASCHEMA),
    undef,
    'this resource is not yet known',
  );

  cmp_result(
    $js->_get_or_load_resource(METASCHEMA),
    my $resource = +{
      canonical_uri => str(METASCHEMA),
      path => '',
      specification_version => 'draft2019-09',
      vocabularies => $vocabularies{'draft2019-09'},
      document => all(
        isa('JSON::Schema::Modern::Document'),
        methods(
          schema => superhashof({
            '$schema' => str(METASCHEMA),
            '$id' => METASCHEMA,
          }),
          canonical_uri => str(METASCHEMA),
          resource_index => ignore,
        ),
      ),
      configs => {},
    },
    'loaded metaschema from sharedir cache',
  );

  cmp_result(
    $js->_get_resource(METASCHEMA),
    $resource,
    'this resource is now in the resource index',
  );
};

subtest 'resource collision with cached metaschema' => sub {
  my $js = JSON::Schema::Modern->new;
  cmp_result(
    $js->evaluate(1, { '$id' => METASCHEMA })->TO_JSON,
    {
      valid => false,
      errors => [
        {
          instanceLocation => '',
          keywordLocation => '',
          error => re(qr{^EXCEPTION: \Quri "https://json-schema.org/draft/2019-09/schema" conflicts with an existing meta-schema resource\E}),
        },
      ],
    },
    'cannot introduce another schema whose id collides with a cached schema, even if it isn\'t loaded yet',
  );
};

done_testing;
