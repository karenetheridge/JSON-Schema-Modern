package MyVocabulary::BadVocabularySub2;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://some/uri#/invalid/uri' => 'draft2020-12',
}

sub keywords {}

1;
