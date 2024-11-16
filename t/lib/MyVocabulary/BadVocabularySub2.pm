# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
package MyVocabulary::BadVocabularySub2;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://some/uri#/invalid/uri' => 'draft2020-12',
}

sub keywords {}

1;
