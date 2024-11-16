# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
package MyVocabulary::StringComparison;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
with 'JSON::Schema::Modern::Vocabulary';

use JSON::Schema::Modern::Utilities qw(assert_keyword_type is_type E);

sub vocabulary {
  'https://vocabulary/string/comparison' => 'draft2020-12',
}

sub keywords { 'stringLessThan' }

sub _traverse_keyword_stringLessThan ($self, $schema, $state) {
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_stringLessThan ($self, $data, $schema, $state) {
  return 1 if not is_type('string', $data);
  return 1 if ($data cmp $schema->{stringLessThan}) == -1;
  return E($state, 'value is not stringwise less than %s', $schema->{stringLessThan});
}

1;
