package MyVocabulary::StringComparison;
use Moo;
with 'JSON::Schema::Modern::Vocabulary';

use JSON::Schema::Modern::Utilities qw(assert_keyword_type is_type E);

sub vocabulary {
  'https://vocabulary/string/comparison' => 'draft2020-12',
}

sub keywords { 'stringLessThan' }

sub _traverse_keyword_stringLessThan {
  my ($self, $schema, $state) = @_;
  return if not assert_keyword_type($state, $schema, 'string');
  return 1;
}

sub _eval_keyword_stringLessThan {
  my ($self, $data, $schema, $state) = @_;

  return 1 if not is_type('string', $data);
  return 1 if ($data cmp $schema->{stringLessThan}) == -1;
  return E($state, 'value is not stringwise less than %s', $schema->{stringLessThan});
}

1;
