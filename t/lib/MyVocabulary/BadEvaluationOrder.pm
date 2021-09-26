package MyVocabulary::BadEvaluationOrder;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://vocabulary/with/bad/evaluation/order' => 'draft2020-12',
}

sub keywords {}

sub evaluation_order { 2 }  # conflicts with Validation vocabulary

1;
