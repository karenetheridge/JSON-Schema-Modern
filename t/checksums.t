# vim: set ft=perl ts=8 sts=2 sw=2 tw=100 et :
use strictures 2;
use stable 0.031 'postderef';
use experimental 'signatures';
no autovivification warn => qw(fetch store exists delete);
use if "$]" >= 5.022, experimental => 're_strict';
no if "$]" >= 5.031009, feature => 'indirect';
no if "$]" >= 5.033001, feature => 'multidimensional';
no if "$]" >= 5.033006, feature => 'bareword_filehandles';
no if "$]" >= 5.041009, feature => 'smartmatch';
no feature 'switch';
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8

use Test2::V0;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';
use Digest::MD5 'md5_hex';
use Path::Tiny;

foreach my $line (<DATA>) {
  chomp $line;
  my ($filename, $checksum) = split / /, $line, 2;

  is(md5_hex(path($filename)->slurp_raw), $checksum, 'checksum for '.$filename.' is correct')
    or diag $filename.' is not what was shipped in the distribution!';
}

done_testing;

__DATA__
share/LICENSE 82b044426b4e3998d7eb085d98a5f916
share/draft2019-09/meta/applicator.json fd08fc5b4c3bd23ae19c919c62b86551
share/draft2019-09/meta/content.json 50fe3f49e909fb38f2bf35022139d174
share/draft2019-09/meta/core.json b4c0e7eac5bd74641d464ebb6377e8cf
share/draft2019-09/meta/format.json 067f8aa16b1e4b8f6b3c352e42ce7a04
share/draft2019-09/meta/meta-data.json f1d30b664cc43acf7d14cce61629cec8
share/draft2019-09/meta/validation.json 9d955e385dbc9cd1d2cb609725c22836
share/draft2019-09/output/schema.json bf63c8c7e3b4aa8786c6f7c27c28121f
share/draft2019-09/schema.json 235e1fd47201b751194d9e8e90969ce4
share/draft2020-12/meta/applicator.json 835180064e52815df939c2118814d80d
share/draft2020-12/meta/content.json 43fd532b134825d343a9be5aa5610234
share/draft2020-12/meta/core.json 8e6829848b79f6d6952e888b4291a639
share/draft2020-12/meta/format-annotation.json 12e1bd6b2af5bdd67240bcb5efc473ae
share/draft2020-12/meta/format-assertion.json c78476a32441e52b48f13027a37fcfa6
share/draft2020-12/meta/meta-data.json c416e310b2648f291e51992b7dc012ab
share/draft2020-12/meta/unevaluated.json 9e4dddcbb0581b939b686048713a1b8e
share/draft2020-12/meta/validation.json a5a6bc93fa352985fc455e6325237f9c
share/draft2020-12/output/schema.json 6efc8e121569c98060dc754e88c52113
share/draft2020-12/schema.json e32920982620b2b43803dc82d4640b50
share/draft4/schema.json c6be0c4792c7455a526f0e0cc9eb7d25
share/draft6/schema.json 0376a64fd48e524336d37410c50f7b74
share/draft7/schema.json d6f6ffd262250e16b20f687b94a08bdc
