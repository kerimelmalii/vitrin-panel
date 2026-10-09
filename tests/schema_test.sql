-- Senaryo testi (yerel Postgres). Hata olursa ON_ERROR_STOP ile durur.
\set ON_ERROR_STOP 1
create or replace function pg_temp.assert(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c,false) then raise exception 'TEST BAŞARISIZ: %', msg; end if; end $$;

set role service_role;
select pg_temp.assert(public.ingest_businesses('[
 {"place_id":"p1","name":"Cep Kuaför","city":"Ankara","district":"Çankaya","sector":"kuaför","phone_raw":"0532 111 22 33","phone_normalized":"+905321112233","rating":4.8,"review_count":50,"website_status":"none","lead_score":90},
 {"place_id":"p2","name":"Sabit Kuaför","city":"Ankara","district":"Çankaya","sector":"kuaför","phone_raw":"0312 111 22 33","phone_normalized":"+903121112233","rating":4.5,"review_count":20,"website_status":"social_only","lead_score":70},
 {"place_id":"p1","name":"Aynı place","city":"Ankara","sector":"kuaför","phone_normalized":"+905550000000"},
 {"place_id":"p3","name":"Aynı telefon","city":"Ankara","sector":"kuaför","phone_normalized":"+905321112233"},
 {"place_id":"p4","name":"Üçüncü","city":"İzmir","district":"Bornova","sector":"diş","phone_normalized":"+905329998877","rating":4.4,"review_count":12,"website_status":"none","lead_score":60}
]'::jsonb) = 3, 'tekrarlar (place_id/telefon) atlanmalı, 3 kayıt kalmalı');
select pg_temp.assert(public.ingest_businesses('[{"place_id":"p1","name":"x","city":"a","sector":"b"}]') = 0, 'tekrar ingest 0 eklemeli');
select pg_temp.assert((select count(*) from public.closed_regions where city='Bursa')=1, 'Bursa kapalı bölge');

reset role;
set role anon;
do $$ begin
  begin perform * from public.businesses; raise exception 'anon okuyabildi'; exception when insufficient_privilege then null; end;
  begin perform public.log_call(gen_random_uuid(),'wa_sent'); raise exception 'anon log_call'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- Giriş yapmış kullanıcılar
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';  -- kullanıcı A
do $$ begin
  begin insert into public.businesses(name) values ('x'); raise exception 'doğrudan insert açık'; exception when insufficient_privilege then null; end;
  begin update public.businesses set status='won'; raise exception 'doğrudan update açık'; exception when insufficient_privilege then null; end;
  begin perform public.ingest_businesses('[]'); raise exception 'ingest açık'; exception when insufficient_privilege then null; end;
end $$;

select pg_temp.assert((select n from public.list_counts() where lst='whatsapp')=2, 'whatsapp listesi 2 (cep numaraları)');
select pg_temp.assert((select n from public.list_counts() where lst='call')=1, 'arama listesi 1 (sabit hat)');
select pg_temp.assert((select n from public.list_counts('İzmir') where lst='whatsapp')=1, 'şehir filtresi');

-- A sıradakini alır: skor yüksek olan
select pg_temp.assert((select name from public.next_business('whatsapp')) = 'Cep Kuaför', 'A en yüksek skoru almalı');
select pg_temp.assert((select name from public.next_business('whatsapp')) = 'Cep Kuaför', 'A yenileyince aynı kartı geri almalı');

-- B kullanıcısı aynı kartı görmemeli
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.assert((select name from public.next_business('whatsapp')) = 'Üçüncü', 'B, A nın açtığı kartı atlamalı');
select pg_temp.assert((select count(*) from public.next_business('whatsapp', null, null, array[(select id from public.businesses where name='Üçüncü')]))=0, 'skip listesi çalışmalı');

-- B "arama listesine al" yapar
select public.move_to_call_list((select id from public.businesses where name='Üçüncü'));
select pg_temp.assert((select n from public.list_counts() where lst='call')=2, 'arama listesine alınan kayıt call listesinde');
select pg_temp.assert((select n from public.list_counts() where lst='whatsapp')=1, 'whatsapp listesi azalmalı');

-- A: WhatsApp gönderdi -> 3 gün sonra takip
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.log_call((select id from public.businesses where name='Cep Kuaför'),'wa_sent','merhaba');
select pg_temp.assert((select status from public.businesses where name='Cep Kuaför')='wa_sent','durum wa_sent');
select pg_temp.assert((select next_action_at from public.businesses where name='Cep Kuaför') > now()+interval '2 days 23 hours','3 gün sonra');
select pg_temp.assert((select claimed_by from public.businesses where name='Cep Kuaför') is null,'kilit açıldı');
select pg_temp.assert((select count(*) from public.next_business('followup'))=0,'vadesi gelmeyen takipte çıkmaz');
-- geri alınmış gibi vadeyi geçmişe çek (test için sahip rolüyle)
reset role; update public.businesses set next_action_at = now()-interval '1 minute' where name='Cep Kuaför'; set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.assert((select name from public.next_business('followup'))='Cep Kuaför','vadesi gelince takipte çıkar');

-- Açmadı x3 -> unreachable ve listeden çıkar
select public.log_call((select id from public.businesses where name='Sabit Kuaför'),'no_answer');
select pg_temp.assert((select status from public.businesses where name='Sabit Kuaför')='no_answer','1. açmadı');
reset role; update public.businesses set next_action_at=now()-interval '1 minute' where name='Sabit Kuaför'; set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.log_call((select id from public.businesses where name='Sabit Kuaför'),'no_answer');
reset role; update public.businesses set next_action_at=now()-interval '1 minute' where name='Sabit Kuaför'; set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.log_call((select id from public.businesses where name='Sabit Kuaför'),'no_answer');
select pg_temp.assert((select status from public.businesses where name='Sabit Kuaför')='unreachable','3. açmadı => ulaşılamaz');

-- Dur dedi: kalıcı kapanır, tekrar işlenemez, tekrar taramada geri gelmez
select public.log_call((select id from public.businesses where name='Üçüncü'),'do_not_contact','dur dedi');
do $$ begin
  begin perform public.log_call((select id from public.businesses where name='Üçüncü'),'wa_sent'); raise exception 'kapalı kayıt tekrar işlendi';
  exception when raise_exception then if sqlerrm like 'kapalı%' then raise; end if; end;
end $$;
select pg_temp.assert((select count(*) from public.v_queue where name='Üçüncü' and lst is not null)=0,'dur diyen listede görünmez');
-- geri arama tarihi zorunlu, geçersiz sonuç reddedilir
do $$ begin
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'callback'); raise exception 'tarihsiz callback kabul';
  exception when raise_exception then if sqlerrm like 'tarihsiz%' then raise; end if; end;
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'foo'); raise exception 'geçersiz kabul';
  exception when raise_exception then if sqlerrm like 'geçersiz kabul' then raise; end if; end;
end $$;

-- Sayaçlar
select pg_temp.assert((select week_total from public.stats())=5,'hafta toplamı (5 kayıt) = '||(select week_total from public.stats()));
select pg_temp.assert((select today_wa from public.stats())=1,'bugün wa=1');
select pg_temp.assert((select count(*) from public.filter_options())>=1,'filtre seçenekleri');
select pg_temp.assert((select count(*) from public.search_history('kuaför'))>=1,'geçmiş arama');
select pg_temp.assert((select count(*) from public.search_history('%'))=0,'% joker olarak çalışmamalı');

reset role;
reset role;
\echo TÜM TESTLER GEÇTİ
