#!/usr/bin/env bash
# Yerel/CI Postgres'e karşı şema + senaryo + yükseltme testleri.
# Kullanım: PGHOST=... PGPORT=... PGUSER=postgres [PGPASSWORD=...] tests/run_sql_tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."
STAMP="$(date +%s%N)"
q() { psql -q -v ON_ERROR_STOP=1 "$@"; }
newdb() { q -d postgres -c "create database $1" || exit 1; q -d "$1" -f tests/supabase_stub.sql || { echo "stub yüklenemedi"; exit 1; }; }

# 1) Temiz kurulum + iş kuralları
DB="t_$STAMP"; newdb "$DB"
q -d "$DB" -f supabase/schema.sql >/dev/null 2>&1 || { echo "schema.sql ilk çalıştırmada hata verdi"; exit 1; }
q -d "$DB" -f supabase/schema.sql >/dev/null 2>&1 || { echo "schema.sql ikinci çalıştırmada hata verdi (tekrar çalıştırılabilir olmalı)"; exit 1; }
out=$(q -d "$DB" -f tests/schema_test.sql 2>&1); code=$?
echo "$out" | grep -E "ERROR|BAŞARISIZ|GEÇTİ"
[ $code -eq 0 ] && echo "$out" | grep -q "TÜM TESTLER GEÇTİ" || exit 1
# Satışı kayıtlı ama müşterisi olmayan eski kayıt, şema yeniden çalışınca müşteri olur
q -d "$DB" -f supabase/schema.sql >/dev/null 2>&1 || exit 1
n=$(q -d "$DB" -tA -c "select count(*) from public.customers where name = 'Üçüncü' and stage = 'won'")
[ "$n" = "1" ] || { echo "geri doldurma çalışmadı (n=$n)"; exit 1; }
echo "ok: temiz kurulum, iş kuralları, geri doldurma"
# Sıfırlama betiği: işletmelerden doğan müşteriler gider, elle eklenenler, roller ve alanlar kalır
q -d "$DB" -f supabase/reset_test_data.sql >/dev/null 2>&1 || { echo "reset_test_data.sql hata verdi"; exit 1; }
r=$(q -d "$DB" -tA -c "select (select count(*) from public.businesses) || ',' || (select count(*) from public.customers where business_id is not null) || ',' || (select count(*) from public.customers where name = 'Elle Eklenen Kafe') || ',' || (select count(*) from public.user_roles) || ',' || (select count(*) from public.closed_regions)")
[ "$r" = "0,0,1,5,1" ] || { echo "sıfırlama beklenmeyen sonuç verdi (işletme,bağlı müşteri,elle müşteri,rol,kapalı bölge = $r)"; exit 1; }
echo "ok: sıfırlama betiği (bağlı müşteriler silindi; elle müşteri, roller, kapalı bölge korundu)"

# 2) Çok eski şemadan yükseltme: veri korunur, kullanıcılar rolsüz kalmaz (en eski = yönetici)
DB2="u_$STAMP"; newdb "$DB2"
q -d "$DB2" <<'SQL' || { echo "eski şema hazırlanamadı"; exit 1; }
insert into auth.users (id, email, created_at) values
  ('aaaaaaaa-0000-0000-0000-000000000002','ikinci@vitrin.test', now() - interval '1 day'),
  ('aaaaaaaa-0000-0000-0000-000000000001','ilk@vitrin.test',    now() - interval '9 days');
create table public.businesses (id uuid primary key default gen_random_uuid(), name text not null, address text, city text, district text, sector text,
  phone_raw text, phone_normalized text unique, rating numeric, review_count int, website_status text, maps_url text, lead_score int default 0,
  status text default 'new', no_answer_count int default 0, attempt_count int default 0, next_action_at timestamptz, created_at timestamptz default now(), place_id text unique);
create table public.calls (id uuid primary key default gen_random_uuid(), business_id uuid references public.businesses(id), outcome text, note text, callback_at timestamptz, called_at timestamptz default now());
insert into public.businesses (name, city, sector, phone_normalized, rating, review_count, website_status, status)
  values ('Eski', 'Ankara', 'kuaför', '+905001112233', 4.8, 30, 'legacy_value', 'weird_status'),
         ('Eski Satış', 'Ankara', 'kuaför', '+905001112244', 4.8, 30, 'none', 'won');
create function public.log_call(p_business_id uuid, p_outcome text, p_note text, p_callback_at timestamptz) returns boolean language sql as 'select true';
SQL
q -d "$DB2" -f supabase/schema.sql >/dev/null 2>&1 || { echo "eski şemanın üstüne yükleme hata verdi"; exit 1; }
q -d "$DB2" -f supabase/schema.sql >/dev/null 2>&1 || { echo "yükseltme sonrası ikinci çalıştırma hata verdi"; exit 1; }
chk=$(q -d "$DB2" -tA <<'SQL'
select (select count(*) from public.businesses where workspace_id = public.platform_ws()) = 2
   and (select role from public.user_roles where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'admin'
   and (select role from public.user_roles where user_id = 'aaaaaaaa-0000-0000-0000-000000000002') = 'sales'
   and (select count(*) from public.user_roles where workspace_id = public.platform_ws()) = 2
   and (select prorettype::regtype::text from pg_proc where proname = 'log_call') = 'void'
   and (select count(*) from public.customers where name = 'Eski Satış' and stage = 'won') = 1;
SQL
)
[ "$chk" = "t" ] || { echo "yükseltme doğrulaması başarısız (sonuç=$chk)"; exit 1; }
echo "ok: çok eski şemadan yükseltme (veri korundu, roller atandı, müşteriler geri dolduruldu)"

# 3) Canlıdaki önceki sürümden (tests/fixtures/schema_v1.sql) yükseltme: veri platform alanına taşınır,
#    aşamalar ve tutarlar yeni modele çevrilir, eski panel fonksiyonları yerini yenisine bırakır
DB3="v_$STAMP"; newdb "$DB3"
q -d "$DB3" -f tests/fixtures/schema_v1.sql >/dev/null 2>&1 || { echo "v1 şeması kurulamadı"; exit 1; }
q -d "$DB3" <<'SQL' >/dev/null || { echo "v1 verisi hazırlanamadı"; exit 1; }
insert into auth.users (id, email) values ('bbbbbbbb-0000-0000-0000-000000000001','sahip@vitrin.test'), ('bbbbbbbb-0000-0000-0000-000000000002','ekip@vitrin.test');
insert into public.user_roles (user_id, role) values ('bbbbbbbb-0000-0000-0000-000000000001','admin'), ('bbbbbbbb-0000-0000-0000-000000000002','designer');
insert into public.businesses (place_id, name, city, sector, phone_normalized, status) values ('v1','V1 Kuaför','Ankara','kuaför','+905001110001','wa_sent');
insert into public.calls (business_id, outcome) select id, 'wa_sent' from public.businesses;
insert into public.customers (name, stage, amount) values ('Tasarımdaki', 'designing', 7500), ('İptal Olan', 'cancelled', null), ('Bekleyen', 'paused', null);
insert into public.customer_notes (customer_id, kind, body) select id, 'note', 'eski not' from public.customers;
insert into public.scan_history (city, sector, saved) values ('Ankara', 'kuaför', 1);
SQL
q -d "$DB3" -f supabase/schema.sql >/dev/null 2>&1 || { echo "v1 üstüne yeni şema hata verdi"; exit 1; }
q -d "$DB3" -f supabase/schema.sql >/dev/null 2>&1 || { echo "v1 yükseltmesinden sonra ikinci çalıştırma hata verdi"; exit 1; }
chk=$(q -d "$DB3" -tA <<'SQL'
select (select count(*) from public.businesses where workspace_id = public.platform_ws()) = 1
   and (select count(*) from public.calls where workspace_id = public.platform_ws()) = 1
   and (select count(*) from public.customer_notes where workspace_id = public.platform_ws()) = 3
   and (select count(*) from public.scan_history where workspace_id = public.platform_ws()) = 1
   and (select count(*) from public.user_roles where workspace_id = public.platform_ws()) = 2
   and (select stage from public.customers where name = 'Tasarımdaki') = 'won'
   and (select stage from public.customers where name = 'İptal Olan') = 'contacted'
   and (select stage from public.customers where name = 'Bekleyen') = 'negotiating'
   and (select sum(amount) from public.customer_sales) = 7500
   and (select count(*) from public.customers where amount is not null) = 0
   and (select count(*) from public.closed_regions where workspace_id = public.platform_ws() and city = 'Bursa') = 1
   and not exists (select 1 from pg_proc where proname = 'user_can');
SQL
)
[ "$chk" = "t" ] || { echo "v1 yükseltme doğrulaması başarısız (sonuç=$chk)"; exit 1; }
echo "ok: önceki sürümden yükseltme (veri Vitrin alanına taşındı, aşamalar ve tutarlar çevrildi)"
