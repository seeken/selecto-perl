#!/usr/bin/env bash
set -euo pipefail
backend=$1
apt-get update -qq
apt-get install -y --no-install-recommends build-essential ca-certificates curl libssl-dev pkg-config unzip
case "$backend" in
 duckdb)
  arch=$(uname -m); [[ $arch = x86_64 ]] && arch=amd64; [[ $arch = aarch64 ]] && arch=arm64
  curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v1.5.5/libduckdb-linux-$arch.zip" -o /tmp/duckdb.zip
  mkdir /tmp/duckdb-sdk; unzip -q /tmp/duckdb.zip -d /tmp/duckdb-sdk
  cp /tmp/duckdb-sdk/libduckdb.so /usr/local/lib/
  ldconfig
  sha256sum /tmp/duckdb.zip /usr/local/lib/libduckdb.so > /evidence/duckdb-sdk-sha256.txt
 ;;
 postgresql) apt-get install -y --no-install-recommends libpq-dev;;
 mysql|mariadb) apt-get install -y --no-install-recommends libmariadb-dev;;
esac
curl -fsSL https://cpanmin.us -o /tmp/cpanm
cp -a /source /tmp/producer; cd /tmp/producer
# Recommendations are deliberately excluded; they describe development choices.
perl /tmp/cpanm --mirror https://cpan.metacpan.org --notest --local-lib-contained /tmp/consumer --installdeps .
perl /tmp/cpanm --mirror https://cpan.metacpan.org --notest --local-lib-contained /tmp/consumer .
case "$backend" in
 postgresql) driver='DBD::Pg~>=3.21.2';;
 mysql|mariadb) driver='DBD::MariaDB@1.24';;
 sqlite) driver='DBD::SQLite@1.76';;
 duckdb) driver='DBD::DuckDB@0.16';;
 core) driver=;;
esac
if [[ -n $driver ]]; then perl /tmp/cpanm --mirror https://cpan.metacpan.org --notest --local-lib-contained /tmp/consumer "$driver"; fi
export PERL5LIB=/tmp/consumer/lib/perl5
perl -MDBI -e 'print "$_\n" for DBI->available_drivers' > /evidence/installed-drivers.txt
while read -r driver; do
 case "$backend:$driver" in postgresql:Pg|mysql:MariaDB|mariadb:MariaDB|sqlite:SQLite|duckdb:DuckDB|*:DBM|*:ExampleP|*:File|*:Gofer|*:Mem|*:NullP|*:Proxy|*:Sponge) ;; *) echo "foreign driver $driver"; exit 1;; esac
done < /evidence/installed-drivers.txt
bash /source/ci/single-backend/system-inventory "$backend"
cd /tmp
perl /source/ci/single-backend/query.pl "$backend" | tee /evidence/query.txt
find /tmp/consumer -name '*.packlist' -print > /evidence/installed-packlists.txt
find /tmp/consumer -name '*.so' -exec ldd {} \; > /evidence/native-linkage.txt
du -sb /tmp/consumer > /evidence/install-prefix-bytes.txt
