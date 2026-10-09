-- Senaryo testi (yerel Postgres). Hata olursa ON_ERROR_STOP ile durur.
\set ON_ERROR_STOP 1
create or replace function pg_temp.assert(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c,false) then raise exception 'TEST BAŞARISIZ: %', msg; end if; end $$;

-- Kullanıcılar: 1111 yönetici, 2222 satış, 3333 tasarımcı, 4444 rolsüz
insert into auth.users (id, email, created_at) values
  ('11111111-1111-1111-1111-111111111111','a@vitrin.test', now() - interval '4 days'),
  ('22222222-2222-2222-2222-222222222222','b@vitrin.test', now() - interval '3 days'),
  ('33333333-3333-3333-3333-333333333333','c@vitrin.test', now() - interval '2 days'),
  ('44444444-4444-4444-4444-444444444444','d@vitrin.test', now() - interval '1 day');
insert into public.user_roles (user_id, role) values
  ('11111111-1111-1111-1111-111111111111','admin'),('22222222-2222-2222-2222-222222222222','sales'),('33333333-3333-3333-3333-333333333333','designer');

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


-- ===================== Roller ve izinler =====================
reset role;
-- anon rol/müşteri fonksiyonlarını çağıramaz
set role anon;
do $$ begin
  begin perform public.my_access(); raise exception 'anon my_access'; exception when insufficient_privilege then null; end;
  begin perform public.team_list(); raise exception 'anon team_list'; exception when insufficient_privilege then null; end;
  begin perform public.has_perm('leads'); raise exception 'anon has_perm'; exception when insufficient_privilege then null; end;
end $$;
reset role;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.assert((select role from public.my_access()) = 'admin', 'yönetici rolü');
select pg_temp.assert((select 'team' = any (perms) and 'subscriptions' = any (perms) from public.my_access()), 'yönetici ekip+abonelik iznine sahip');
select pg_temp.assert((select count(*) from public.team_list()) = 4, 'ekip listesi 4 kullanıcı');

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.assert((select role = 'sales' and not ('team' = any (perms)) from public.my_access()), 'satış: ekip izni yok');
do $$ begin
  begin perform public.team_list(); raise exception 'satış team_list görebildi'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
  begin perform public.set_user_role('44444444-4444-4444-4444-444444444444','admin'); raise exception 'satış rol verebildi'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
end $$;

set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.assert((select role from public.my_access()) = 'designer', 'tasarımcı rolü');
select pg_temp.assert((select count(*) from public.businesses) = 0 and (select count(*) from public.calls) = 0 and (select count(*) from public.scan_history) = 0, 'tasarımcı satış verisini göremez');
select pg_temp.assert((select count(*) from public.list_counts()) = 0 and (select count(*) from public.v_queue) = 0, 'tasarımcıda liste boş');
do $$ begin
  begin perform * from public.next_business('whatsapp'); raise exception 'tasarımcı next_business çağırdı'; exception when raise_exception then if sqlerrm like 'tasarımcı%' then raise; end if; end;
  begin perform public.log_call(gen_random_uuid(), 'wa_sent'); raise exception 'tasarımcı log_call çağırdı'; exception when raise_exception then if sqlerrm like 'tasarımcı%' then raise; end if; end;
  begin perform public.move_to_call_list(gen_random_uuid()); raise exception 'tasarımcı move_to_call_list'; exception when raise_exception then if sqlerrm like 'tasarımcı%' then raise; end if; end;
end $$;

set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.assert((select role from public.my_access()) = 'none' and cardinality((select perms from public.my_access())) = 0, 'rolsüz kullanıcı: izin yok');
select pg_temp.assert((select count(*) from public.businesses) = 0 and (select count(*) from public.customers) = 0, 'rolsüz kullanıcı hiçbir şey göremez');
do $$ begin
  begin perform public.create_customer('Deneme'); raise exception 'rolsüz müşteri ekledi'; exception when raise_exception then if sqlerrm like 'rolsüz%' then raise; end if; end;
end $$;

-- Rol yönetimi
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.set_user_role('44444444-4444-4444-4444-444444444444', 'designer', 'Ayşe');
select pg_temp.assert((select role from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'designer'
  and (select display_name from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'Ayşe', 'rol atandı');
select public.set_user_role('44444444-4444-4444-4444-444444444444', 'none');
select pg_temp.assert((select role from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'none', 'rol kaldırıldı');
do $$ begin
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','sales'); raise exception 'son yönetici düşürüldü'; exception when raise_exception then if sqlerrm like 'son yönetici düşürüldü' then raise; end if; end;
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','none'); raise exception 'son yönetici silindi'; exception when raise_exception then if sqlerrm like 'son yönetici silindi' then raise; end if; end;
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','patron'); raise exception 'geçersiz rol'; exception when raise_exception then if sqlerrm like 'geçersiz rol' then raise; end if; end;
  begin perform public.set_user_role(gen_random_uuid(),'sales'); raise exception 'olmayan kullanıcı'; exception when raise_exception then if sqlerrm like 'olmayan kullanıcı' then raise; end if; end;
end $$;
-- ikinci yönetici varsa ilki düşürülebilir
select public.set_user_role('22222222-2222-2222-2222-222222222222', 'admin');
select public.set_user_role('11111111-1111-1111-1111-111111111111', 'sales');
select pg_temp.assert((select role from public.my_access()) = 'sales', 'yönetici ikinci yönetici varken düşürülebildi');
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.set_user_role('11111111-1111-1111-1111-111111111111', 'admin');   -- geri ver (sonraki testler için)

-- ===================== Müşteri akışı =====================
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
-- "Satış oldu" -> müşteri kendiliğinden oluşur
select public.log_call((select id from public.businesses where name='Cep Kuaför'), 'won', 'Paket: kurumsal');
select pg_temp.assert((select count(*) from public.customers) = 1, 'satış müşteri oluşturdu');
select pg_temp.assert((select stage from public.customers limit 1) = 'sale_done', 'başlangıç aşaması');
select pg_temp.assert((select body from public.customer_notes where kind = 'created' limit 1) like 'Satış kaydedildi%Paket: kurumsal', 'oluşturma notu');
select pg_temp.assert((select business_id from public.customers limit 1) = (select id from public.businesses where name='Cep Kuaför'), 'işletmeye bağlı');
select pg_temp.assert((select status from public.businesses where name='Cep Kuaför') = 'won', 'işletme kapandı');

-- tasarımcı aşamayı ve notu yönetir
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.assert((select count(*) from public.v_customers) = 1, 'tasarımcı müşteriyi görür');
select public.set_customer_stage((select id from public.customers limit 1), 'designing', 'Logo bekleniyor');
select pg_temp.assert((select stage from public.customers limit 1) = 'designing', 'aşama değişti');
select pg_temp.assert((select body from public.customer_notes where kind = 'stage' limit 1) = E'Satış gerçekleşti → Site tasarlanıyor\nLogo bekleniyor', 'aşama notu');
select public.set_customer_stage((select id from public.customers limit 1), 'designing');          -- aynı aşama: sessiz
select pg_temp.assert((select count(*) from public.customer_notes where kind = 'stage') = 1, 'aynı aşamaya geçiş not üretmez');
select public.update_customer((select id from public.customers limit 1), '{"amount":"7500","domain":"mavikuafor.com","next_step":"Logo iste","next_step_at":"2026-10-20T10:00:00+03:00"}'::jsonb);
select pg_temp.assert((select amount from public.customers limit 1) = 7500 and (select domain from public.customers limit 1) = 'mavikuafor.com'
  and (select next_step from public.customers limit 1) = 'Logo iste' and (select next_step_at from public.customers limit 1) is not null, 'alanlar güncellendi');
select pg_temp.assert((select body from public.customer_notes where kind = 'edit' limit 1) = 'Güncellendi: tutar, alan adı, sıradaki adım, adım tarihi', 'düzenleme notu: ' || (select body from public.customer_notes where kind = 'edit' limit 1));
select public.update_customer((select id from public.customers limit 1), '{"domain":"","amount":null}'::jsonb);   -- temizleme
select pg_temp.assert((select domain from public.customers limit 1) is null and (select amount from public.customers limit 1) is null, 'boş değer alanı temizler');
select public.add_customer_note((select id from public.customers limit 1), '  Müşteri logoyu gönderdi  ');
select pg_temp.assert((select last_note from public.v_customers limit 1) = 'Müşteri logoyu gönderdi', 'son not görünümde (kırpılmış)');
do $$ declare cid uuid := (select id from public.customers limit 1); begin
  begin perform public.set_customer_stage(cid, 'bitti'); raise exception 'geçersiz aşama'; exception when raise_exception then if sqlerrm like 'geçersiz aşama' then raise; end if; end;
  begin perform public.update_customer(cid, '{"stage":"live"}'::jsonb); raise exception 'aşama patch ile değişti'; exception when raise_exception then if sqlerrm like 'aşama patch%' then raise; end if; end;
  begin perform public.update_customer(cid, '{"amount":"-5"}'::jsonb); raise exception 'negatif tutar'; exception when check_violation then null; end;
  begin perform public.update_customer(cid, '{"name":" "}'::jsonb); raise exception 'boş ad'; exception when raise_exception then if sqlerrm like 'boş ad' then raise; end if; end;
  begin perform public.add_customer_note(cid, '   '); raise exception 'boş not'; exception when raise_exception then if sqlerrm like 'boş not' then raise; end if; end;
  begin perform public.add_customer_note(gen_random_uuid(), 'x'); raise exception 'olmayan müşteri'; exception when raise_exception then if sqlerrm like 'olmayan müşteri' then raise; end if; end;
  begin insert into public.customers (name) values ('doğrudan'); raise exception 'doğrudan insert'; exception when insufficient_privilege then null; end;
  begin update public.customers set stage = 'live'; raise exception 'doğrudan update'; exception when insufficient_privilege then null; end;
  begin delete from public.customer_notes; raise exception 'doğrudan delete'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.assert((select count(*) from public.customer_timeline((select id from public.customers where name = 'Cep Kuaför' limit 1))) = 5, 'zaman çizelgesi: oluşturma+aşama+düzenleme+temizleme+not = ' || (select count(*) from public.customer_timeline((select id from public.customers where name = 'Cep Kuaför' limit 1))));
select pg_temp.assert((select body from public.customer_timeline((select id from public.customers where name = 'Cep Kuaför' limit 1)) limit 1) = 'Müşteri logoyu gönderdi', 'zaman çizelgesi en yeni not önde');
select pg_temp.assert((select author from public.customer_timeline((select id from public.customers where name = 'Cep Kuaför' limit 1)) limit 1) = 'c', 'yazan kişi (ad yoksa e-posta başı)');
-- elle müşteri ekleme
select public.create_customer('Elle Eklenen Kafe', '0532 000 11 22', 'Ankara', 'kafe', 12000, 'Tanıdık yoluyla geldi');
select pg_temp.assert((select count(*) from public.customers) = 2 and (select stage from public.customers where name = 'Elle Eklenen Kafe') = 'sale_done', 'elle müşteri eklendi');
do $$ begin
  begin perform public.create_customer('x'); raise exception 'kısa ad'; exception when raise_exception then if sqlerrm like 'kısa ad' then raise; end if; end;
end $$;

-- rolsüz kullanıcı zaman çizelgesini göremez
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
do $$ begin
  begin perform public.customer_timeline(gen_random_uuid()); raise exception 'rolsüz zaman çizelgesi'; exception when raise_exception then if sqlerrm like 'rolsüz%' then raise; end if; end;
end $$;

-- Eski veri: durumu 'won' olup müşterisi olmayan işletme şema yeniden çalışınca müşteri olur
reset role;
update public.businesses set status = 'won' where name = 'Üçüncü';

reset role;
reset role;
\echo TÜM TESTLER GEÇTİ
