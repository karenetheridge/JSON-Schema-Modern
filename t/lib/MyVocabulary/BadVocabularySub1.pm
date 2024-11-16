# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
package MyVocabulary::BadVocabularySub1;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

sub vocabulary { 'https://wrong_data' }
sub keywords {}

1;
