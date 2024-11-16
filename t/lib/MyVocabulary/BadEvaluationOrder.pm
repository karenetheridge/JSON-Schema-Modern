# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
package MyVocabulary::BadEvaluationOrder;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary {
  'https://vocabulary/with/bad/evaluation/order' => 'draft2020-12',
}

sub keywords {}

sub evaluation_order { 1 }  # conflicts with Validation vocabulary

1;
