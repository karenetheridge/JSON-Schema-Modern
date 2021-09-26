package MyVocabulary::BadVocabularySub1;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary { 'https://wrong_data' }
sub keywords {}

1;
