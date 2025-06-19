# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
package MyVocabulary::ConflictingKeyword;
use Moo;
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://vocabulary/conflicting/keyword' => 'draft2020-12',
}

sub keywords { 'minLength' }

sub _traverse_keyword_minLength ($self, $schema, $state) { 1 }

sub _eval_keyword_minLength ($self, $data, $schema, $state) { 1 }

1;
