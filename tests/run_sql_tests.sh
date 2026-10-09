#!/usr/bin/env bash
# Yerel Postgres'e karşı şema + senaryo testi. Kullanım: PGHOST=... PGPORT=... PGUSER=postgres tests/run_sql_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB="t_$(date +%s%N)"
psql -q -v ON_ERROR_STOP=1 -d postgres -c "create database $DB"
P="psql -q -v ON_ERROR_STOP=1 -d $DB"
$P -f tests/supabase_stub.sql
$P -f supabase/schema.sql 2>&1 | grep -v NOTICE || true
$P -f supabase/schema.sql >/dev/null 2>&1          # ikinci çalıştırma de hatasız olmalı
$P -f tests/schema_test.sql 2>&1 | grep -E "ERROR|BAŞARISIZ|GEÇTİ" && true
