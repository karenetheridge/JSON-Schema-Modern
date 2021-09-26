package MyVocabulary::BadVocabularySub3;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://some/uri' => 'wrongdraft',
}

sub keywords {}

1;
