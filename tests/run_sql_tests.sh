#!/usr/bin/env bash
# Yerel/CI Postgres'e karşı şema + senaryo testi.
# Kullanım: PGHOST=... PGPORT=... PGUSER=postgres [PGPASSWORD=...] tests/run_sql_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DB="t_$(date +%s%N)"
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
psql -q -v ON_ERROR_STOP=1 -d postgres -c "create database $DB" || exit 1
$P -f tests/supabase_stub.sql                               || { echo "stub yüklenemedi"; exit 1; }
$P -f supabase/schema.sql >/dev/null 2>&1                   || { echo "schema.sql ilk çalıştırmada hata verdi"; exit 1; }
$P -f supabase/schema.sql >/dev/null 2>&1                   || { echo "schema.sql ikinci çalıştırmada hata verdi (tekrar çalıştırılabilir olmalı)"; exit 1; }
out=$($P -f tests/schema_test.sql 2>&1); code=$?
echo "$out" | grep -E "ERROR|BAŞARISIZ|GEÇTİ"
[ $code -eq 0 ] && echo "$out" | grep -q "TÜM TESTLER GEÇTİ"
