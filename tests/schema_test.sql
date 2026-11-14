-- Senaryo testi (yerel Postgres). Hata olursa ON_ERROR_STOP ile durur.
\set ON_ERROR_STOP 1
create or replace function pg_temp.assert(c boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(c,false) then raise exception 'TEST BAŞARISIZ: %', msg; end if; end $$;

-- İki alan: Vitrin (platform) ve Pilot (demo, aylık 500 kota)
insert into public.workspaces (id, slug, name, is_demo, lead_quota)
values ('99999999-0000-0000-0000-000000000001', 'pilot', 'Pilot', true, 500);
select pg_temp.assert((select count(*) from public.workspaces where is_platform) = 1, 'tek platform alanı');

-- Kullanıcılar: 1111 yönetici, 2222 satış, 3333 operasyon (designer), 4444 rolsüz — Vitrin'de
--               5555 pilot yöneticisi, 6666 pilot satış
insert into auth.users (id, email, created_at) values
  ('11111111-1111-1111-1111-111111111111','a@vitrin.test', now() - interval '6 days'),
  ('22222222-2222-2222-2222-222222222222','b@vitrin.test', now() - interval '5 days'),
  ('33333333-3333-3333-3333-333333333333','c@vitrin.test', now() - interval '4 days'),
  ('44444444-4444-4444-4444-444444444444','d@vitrin.test', now() - interval '3 days'),
  ('55555555-5555-5555-5555-555555555555','e@pilot.test',  now() - interval '2 days'),
  ('66666666-6666-6666-6666-666666666666','f@pilot.test',  now() - interval '1 days');
insert into public.user_roles (user_id, role, workspace_id) values
  ('11111111-1111-1111-1111-111111111111','admin',   public.platform_ws()),
  ('22222222-2222-2222-2222-222222222222','sales',   public.platform_ws()),
  ('33333333-3333-3333-3333-333333333333','designer',public.platform_ws()),
  ('55555555-5555-5555-5555-555555555555','admin',   '99999999-0000-0000-0000-000000000001'),
  ('66666666-6666-6666-6666-666666666666','sales',   '99999999-0000-0000-0000-000000000001');

select set_config('t.plat', public.platform_ws()::text, false);
set role service_role;
select pg_temp.assert(public.ingest_businesses(public.platform_ws(), '[
 {"place_id":"p1","name":"Cep Kuaför","city":"Ankara","district":"Çankaya","sector":"kuaför","phone_raw":"0532 111 22 33","phone_normalized":"+905321112233","rating":4.8,"review_count":50,"website_status":"none","lead_score":90},
 {"place_id":"p2","name":"Sabit Kuaför","city":"Ankara","district":"Çankaya","sector":"kuaför","phone_raw":"0312 111 22 33","phone_normalized":"+903121112233","rating":4.5,"review_count":20,"website_status":"has_site","lead_score":70},
 {"place_id":"p1","name":"Aynı place","city":"Ankara","sector":"kuaför","phone_normalized":"+905550000000"},
 {"place_id":"p3","name":"Aynı telefon","city":"Ankara","sector":"kuaför","phone_normalized":"+905321112233"},
 {"place_id":"p4","name":"Üçüncü","city":"İzmir","district":"Bornova","sector":"diş","phone_normalized":"+905329998877","rating":4.4,"review_count":12,"website_status":"none","lead_score":60}
]'::jsonb) = 3, 'tekrarlar (place_id/telefon) atlanmalı, 3 kayıt kalmalı');
select pg_temp.assert(public.ingest_businesses(public.platform_ws(), '[{"place_id":"p1","name":"x","city":"a","sector":"b"}]') = 0, 'tekrar ingest 0 eklemeli');
-- Aynı işletme başka alanda serbestçe eklenebilir (alanlar birbirini etkilemez)
select pg_temp.assert(public.ingest_businesses('99999999-0000-0000-0000-000000000001', '[
 {"place_id":"p1","name":"Cep Kuaför (pilot)","city":"Ankara","district":"Çankaya","sector":"diş kliniği","phone_raw":"0532 111 22 33","phone_normalized":"+905321112233","lead_score":50},
 {"place_id":"q2","name":"Pilot Klinik","city":"Ankara","district":"Çankaya","sector":"diş kliniği","phone_raw":"0533 444 55 66","phone_normalized":"+905334445566","lead_score":40}
]'::jsonb) = 2, 'aynı place_id/telefon başka alanda eklenebilmeli');
select pg_temp.assert((select count(*) from public.closed_regions where city='Bursa' and workspace_id = public.platform_ws())=1, 'Bursa Vitrin için kapalı bölge');
select pg_temp.assert((select count(*) from public.closed_regions where workspace_id = '99999999-0000-0000-0000-000000000001')=0, 'pilotta kapalı bölge yok');
select pg_temp.assert((public.scan_context('55555555-5555-5555-5555-555555555555')->>'workspace_id') = '99999999-0000-0000-0000-000000000001'
  and (public.scan_context('55555555-5555-5555-5555-555555555555')->>'can_scan')::boolean
  and (public.scan_context('55555555-5555-5555-5555-555555555555')->>'lead_quota')::int = 500, 'tarama bağlamı: alan, izin, kota');
select pg_temp.assert(not (public.scan_context('33333333-3333-3333-3333-333333333333')->>'can_scan')::boolean, 'operasyon rolü tarayamaz');
select pg_temp.assert(public.scan_context('44444444-4444-4444-4444-444444444444') is null, 'rolsüz kullanıcının bağlamı yok');

reset role;
set role anon;
do $$ begin
  begin perform * from public.businesses; raise exception 'anon okuyabildi'; exception when insufficient_privilege then null; end;
  begin perform public.log_call(gen_random_uuid(),'wa_sent'); raise exception 'anon log_call'; exception when insufficient_privilege then null; end;
  begin perform * from public.workspaces; raise exception 'anon alanları okudu'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- Giriş yapmış kullanıcılar
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';  -- Vitrin yöneticisi
do $$ begin
  begin insert into public.businesses(name, workspace_id) values ('x', public.my_ws()); raise exception 'doğrudan insert açık'; exception when insufficient_privilege then null; end;
  begin update public.businesses set status='won'; raise exception 'doğrudan update açık'; exception when insufficient_privilege then null; end;
  begin perform public.ingest_businesses(public.my_ws(), '[]'); raise exception 'ingest açık'; exception when insufficient_privilege then null; end;
  begin perform public.scan_context(auth.uid()); raise exception 'scan_context açık'; exception when insufficient_privilege then null; end;
end $$;

select pg_temp.assert((select count(*) from public.businesses) = 3, 'Vitrin yalnızca kendi 3 kaydını görür');
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

-- ===================== Alan ayrımı =====================
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';   -- pilot satış
select pg_temp.assert((select count(*) from public.businesses) = 2, 'pilot yalnızca kendi 2 kaydını görür');
select pg_temp.assert((select name from public.next_business('whatsapp')) = 'Cep Kuaför (pilot)', 'pilot kendi kartını alır (Vitrin aynı işletmeyi kilitlemiş olsa da)');
select pg_temp.assert((select count(*) from public.scan_history) = 0 and (select count(*) from public.closed_regions) = 0, 'pilot Vitrin tarama geçmişini/kapalı bölgesini görmez');
select pg_temp.assert((select count(*) from public.workspaces) = 1 and (select name from public.workspaces) = 'Pilot', 'pilot yalnızca kendi alanını görür');
do $$ declare vid uuid; begin
  reset role; select id into vid from public.businesses where name = 'Sabit Kuaför'; set role authenticated;
  perform set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
  begin perform public.log_call(vid, 'wa_sent'); raise exception 'başka alanın kaydı işlendi';
  exception when raise_exception then if sqlerrm like 'başka alan%' then raise; end if; end;
  begin perform public.move_to_call_list(vid); exception when others then null; end;
  reset role;
  if (select call_list from public.businesses where id = vid) then raise exception 'TEST BAŞARISIZ: başka alanın kaydı arama listesine alındı'; end if;
  set role authenticated;
end $$;
set role authenticated;
select pg_temp.assert((select role from public.my_access()) = 'sales' and (select workspace_name from public.my_access()) = 'Pilot'
  and (select is_demo from public.my_access()) and (select lead_quota from public.my_access()) = 500
  and not (select is_platform_admin from public.my_access()), 'pilot erişim bilgisi: alan adı, demo, kota');

-- A: WhatsApp gönderdi -> 3 gün sonra takip
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.log_call((select id from public.businesses where name='Cep Kuaför'),'wa_sent','merhaba');
select pg_temp.assert((select status from public.businesses where name='Cep Kuaför')='wa_sent','durum wa_sent');
select pg_temp.assert((select next_action_at from public.businesses where name='Cep Kuaför') > now()+interval '2 days 23 hours','3 gün sonra');
select pg_temp.assert((select claimed_by from public.businesses where name='Cep Kuaför') is null,'kilit açıldı');
select pg_temp.assert((select count(*) from public.next_business('followup'))=0,'vadesi gelmeyen takipte çıkmaz');
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

-- Dur dedi (ret sebebiyle): kalıcı kapanır, tekrar işlenemez
select public.log_call((select id from public.businesses where name='Üçüncü'),'do_not_contact','dur dedi', null, 'no_need');
select pg_temp.assert((select reason from public.calls where outcome='do_not_contact') = 'no_need', 'ret sebebi kaydedildi');
do $$ begin
  begin perform public.log_call((select id from public.businesses where name='Üçüncü'),'wa_sent'); raise exception 'kapalı kayıt tekrar işlendi';
  exception when raise_exception then if sqlerrm like 'kapalı%' then raise; end if; end;
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'wa_sent', null, null, 'price'); raise exception 'ret dışı sonuçta sebep kabul';
  exception when raise_exception then if sqlerrm like 'ret dışı%' then raise; end if; end;
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'rejected', null, null, 'uydurma'); raise exception 'geçersiz sebep kabul';
  exception when raise_exception then if sqlerrm like 'geçersiz sebep%' then raise; end if; end;
end $$;
select pg_temp.assert((select count(*) from public.v_queue where name='Üçüncü' and lst is not null)=0,'dur diyen listede görünmez');
do $$ begin
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'callback'); raise exception 'tarihsiz callback kabul';
  exception when raise_exception then if sqlerrm like 'tarihsiz%' then raise; end if; end;
  begin perform public.log_call((select id from public.businesses where name='Cep Kuaför'),'foo'); raise exception 'geçersiz kabul';
  exception when raise_exception then if sqlerrm like 'geçersiz kabul' then raise; end if; end;
end $$;

-- Sayaçlar (yalnızca kendi alanı)
select pg_temp.assert((select week_total from public.stats())=5,'hafta toplamı (5 kayıt) = '||(select week_total from public.stats()));
select pg_temp.assert((select today_wa from public.stats())=1,'bugün wa=1');
select pg_temp.assert((select count(*) from public.filter_options())>=1,'filtre seçenekleri');
select pg_temp.assert((select count(*) from public.search_history('kuaför'))>=1,'geçmiş arama');
select pg_temp.assert((select count(*) from public.search_history('%'))=0,'% joker olarak çalışmamalı');
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select pg_temp.assert((select week_total from public.stats())=0 and (select count(*) from public.search_history(''))=0, 'pilot Vitrin işlemlerini saymaz/görmez');

-- ===================== 30 gün kuralı =====================
reset role;
update public.businesses set created_at = now() - interval '31 days' where name in ('Pilot Klinik', 'Sabit Kuaför');
select pg_temp.assert((select lst from public.v_queue where name='Pilot Klinik') is null, '30 günü geçen işlenmemiş kayıt listede görünmez');
select pg_temp.assert(public.purge_stale_leads() = 1, 'yalnızca işlenmemiş eski kayıt silinir');
select pg_temp.assert(not exists (select 1 from public.businesses where name='Pilot Klinik'), 'Pilot Klinik silindi');
select pg_temp.assert(exists (select 1 from public.businesses where name='Sabit Kuaför'), 'işlenmiş eski kayıt (açmadı) kalır');

-- ===================== Roller, ekip ve alanlar =====================
set role anon;
do $$ begin
  begin perform public.my_access(); raise exception 'anon my_access'; exception when insufficient_privilege then null; end;
  begin perform public.team_list(); raise exception 'anon team_list'; exception when insufficient_privilege then null; end;
  begin perform public.has_perm('leads'); raise exception 'anon has_perm'; exception when insufficient_privilege then null; end;
end $$;
reset role;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.assert((select role from public.my_access()) = 'admin' and (select is_platform_admin from public.my_access()), 'Vitrin yöneticisi platform yöneticisidir');
select pg_temp.assert((select count(*) from public.team_list()) = 6, 'platform yöneticisi herkesi görür (6)');
select pg_temp.assert((select count(*) from public.list_workspaces()) = 2, 'platform yöneticisi iki alanı görür');
select pg_temp.assert((select count(*) from public.workspaces) = 2, 'platform yöneticisi alan tablosunu görür');

set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';   -- pilot yöneticisi
select pg_temp.assert(not (select is_platform_admin from public.my_access()), 'pilot yöneticisi platform yöneticisi değil');
select pg_temp.assert((select count(*) from public.team_list()) = 2, 'pilot yöneticisi yalnızca kendi ekibini görür');
do $$ begin
  begin perform public.list_workspaces(); raise exception 'pilot alanları listeledi'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.create_workspace('Kaçak'); raise exception 'pilot alan açtı'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.set_user_role('22222222-2222-2222-2222-222222222222','sales'); raise exception 'pilot Vitrin kullanıcısını değiştirdi'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.set_user_role('44444444-4444-4444-4444-444444444444','sales'); raise exception 'pilot rolsüz kullanıcıyı aldı'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.set_user_role('66666666-6666-6666-6666-666666666666','sales', null, current_setting('t.plat')::uuid); raise exception 'pilot kullanıcıyı başka alana taşıdı'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.set_user_role('55555555-5555-5555-5555-555555555555','sales'); raise exception 'pilotun son yöneticisi düşürüldü'; exception when raise_exception then if sqlerrm like 'pilotun%' then raise; end if; end;
  begin perform public.update_workspace(current_setting('t.plat')::uuid, '{"name":"x"}'); raise exception 'pilot Vitrin ayarını değiştirdi'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.update_workspace(public.my_ws(), '{"lead_quota":99999}'); raise exception 'pilot kotasını artırdı'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
  begin perform public.update_workspace(public.my_ws(), '{"message_template":"Merhaba"}'); raise exception 'iptal cümlesiz şablon'; exception when raise_exception then if sqlerrm like 'iptal cümlesiz%' then raise; end if; end;
end $$;
select public.set_user_role('66666666-6666-6666-6666-666666666666', 'designer', 'Fatma');
select pg_temp.assert((select role from public.team_list() where user_id = '66666666-6666-6666-6666-666666666666') = 'designer', 'pilot yöneticisi kendi ekibine rol verir');
select public.set_user_role('66666666-6666-6666-6666-666666666666', 'sales');
select public.update_workspace(public.my_ws(), '{"message_template":"Merhaba {isim}, istemezseniz iptal yazın.","sector_suggestions":["Diş Kliniği"," avukat ","x"],"weekly_goal":50}');
select pg_temp.assert((select message_template from public.my_access()) like 'Merhaba {isim}%' and (select weekly_goal from public.my_access()) = 50
  and (select sector_suggestions from public.my_access()) = array['avukat','diş kliniği'], 'alan ayarları güncellendi (sektörler temizlendi)');

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.assert((select role = 'sales' and not ('team' = any (perms)) from public.my_access()), 'satış: ekip izni yok');
do $$ begin
  begin perform public.team_list(); raise exception 'satış team_list görebildi'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
  begin perform public.set_user_role('44444444-4444-4444-4444-444444444444','admin'); raise exception 'satış rol verebildi'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
  begin perform public.update_workspace(public.my_ws(), '{"weekly_goal":5}'); raise exception 'satış ayar değiştirdi'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
  begin perform public.monthly_report(); exception when others then raise exception 'satış raporu göremedi: %', sqlerrm; end;
end $$;

set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.assert((select role from public.my_access()) = 'designer', 'operasyon rolü');
select pg_temp.assert((select count(*) from public.businesses) = 0 and (select count(*) from public.calls) = 0 and (select count(*) from public.scan_history) = 0, 'operasyon satış verisini göremez');
select pg_temp.assert((select count(*) from public.list_counts()) = 0 and (select count(*) from public.v_queue) = 0, 'operasyonda liste boş');
do $$ begin
  begin perform * from public.next_business('whatsapp'); raise exception 'operasyon next_business çağırdı'; exception when raise_exception then if sqlerrm like 'operasyon%' then raise; end if; end;
  begin perform public.log_call(gen_random_uuid(), 'wa_sent'); raise exception 'operasyon log_call çağırdı'; exception when raise_exception then if sqlerrm like 'operasyon%' then raise; end if; end;
  begin perform public.monthly_report(); raise exception 'operasyon raporu gördü'; exception when raise_exception then if sqlerrm like 'operasyon%' then raise; end if; end;
end $$;

set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.assert((select role from public.my_access()) = 'none' and cardinality((select perms from public.my_access())) = 0, 'rolsüz kullanıcı: izin yok');
select pg_temp.assert((select count(*) from public.businesses) = 0 and (select count(*) from public.customers) = 0 and (select count(*) from public.workspaces) = 0, 'rolsüz kullanıcı hiçbir şey göremez');
do $$ begin
  begin perform public.create_customer('Deneme'); raise exception 'rolsüz müşteri ekledi'; exception when raise_exception then if sqlerrm like 'rolsüz%' then raise; end if; end;
end $$;

-- Platform yöneticisi: alan açar, kullanıcıyı alana atar, kotayı değiştirir
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.create_workspace('Örnek Şirket A.Ş.', true, 250);
do $$ begin
  begin perform public.set_user_role('44444444-4444-4444-4444-444444444444', 'sales'); raise exception 'alansız kişi platforma atandı';
  exception when raise_exception then if sqlerrm like 'alansız%' then raise; end if; end;
end $$;
select pg_temp.assert((select slug from public.workspaces where name = 'Örnek Şirket A.Ş.') = 'ornek-sirket-a-s', 'alan kısa adı üretildi');
select public.set_user_role('44444444-4444-4444-4444-444444444444', 'sales', 'Ayşe', (select id from public.workspaces where slug = 'ornek-sirket-a-s'));
select pg_temp.assert((select workspace_name from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'Örnek Şirket A.Ş.', 'kullanıcı yeni alana atandı');
select public.update_workspace((select id from public.workspaces where slug = 'ornek-sirket-a-s'), '{"lead_quota":1000,"is_demo":false}');
select pg_temp.assert((select lead_quota from public.workspaces where slug = 'ornek-sirket-a-s') = 1000, 'platform kotayı değiştirdi');
select public.set_user_role('44444444-4444-4444-4444-444444444444', 'none');
select pg_temp.assert((select role from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'none', 'rol kaldırıldı');
do $$ begin
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','sales'); raise exception 'son yönetici düşürüldü'; exception when raise_exception then if sqlerrm like 'son yönetici düşürüldü' then raise; end if; end;
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','none'); raise exception 'son yönetici silindi'; exception when raise_exception then if sqlerrm like 'son yönetici silindi' then raise; end if; end;
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','admin', null, '99999999-0000-0000-0000-000000000001'); raise exception 'son yönetici taşındı'; exception when raise_exception then if sqlerrm like 'son yönetici taşındı' then raise; end if; end;
  begin perform public.set_user_role('11111111-1111-1111-1111-111111111111','patron'); raise exception 'geçersiz rol'; exception when raise_exception then if sqlerrm like 'geçersiz rol' then raise; end if; end;
  begin perform public.set_user_role(gen_random_uuid(),'sales'); raise exception 'olmayan kullanıcı'; exception when raise_exception then if sqlerrm like 'olmayan kullanıcı' then raise; end if; end;
end $$;
select public.set_user_role('22222222-2222-2222-2222-222222222222', 'admin');
select public.set_user_role('11111111-1111-1111-1111-111111111111', 'sales');
select pg_temp.assert((select role from public.my_access()) = 'sales', 'yönetici ikinci yönetici varken düşürülebildi');
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select public.set_user_role('11111111-1111-1111-1111-111111111111', 'admin');
select public.set_user_role('22222222-2222-2222-2222-222222222222', 'sales');

-- ===================== Müşteri akışı =====================
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
-- "İlgilendi" -> müşteri "İletişimde" aşamasıyla oluşur; "Satış oldu" -> "Satış tamamlandı"ya geçer
reset role; update public.businesses set status = 'new', next_action_at = null where name = 'Cep Kuaför'; set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.log_call((select id from public.businesses where name='Cep Kuaför'), 'interested', 'Fiyat istedi');
select pg_temp.assert((select count(*) from public.customers) = 1 and (select stage from public.customers limit 1) = 'contacted', 'ilgilenen İletişimde aşamasıyla eklendi');
select public.log_call((select id from public.businesses where name='Cep Kuaför'), 'won', 'Paket: kurumsal');
select pg_temp.assert((select count(*) from public.customers) = 1 and (select stage from public.customers limit 1) = 'won', 'satış aynı müşteriyi Satış tamamlandı yapar');
select pg_temp.assert((select body from public.customer_notes where kind = 'stage' limit 1) = E'İletişimde → Satış tamamlandı\nPaket: kurumsal', 'aşama notu');
select pg_temp.assert((select status from public.businesses where name='Cep Kuaför') = 'won', 'işletme kapandı');

-- Satış kalemleri
select public.set_customer_stage((select id from public.customers limit 1), 'negotiating', 'Teklif gönderildi');
select pg_temp.assert((select stage from public.customers limit 1) = 'negotiating', 'aşama değişti');
select public.add_sale((select id from public.customers limit 1), 'Danışmanlık paketi', 2, 3000);
select public.add_sale((select id from public.customers limit 1), ' Eğitim ', 1, 1500.5);
select pg_temp.assert((select stage from public.customers limit 1) = 'won', 'satış eklenince Satış tamamlandı');
select pg_temp.assert((select sales_total from public.v_customers limit 1) = 4500.50 and (select sales_count from public.v_customers limit 1) = 2, 'müşteri toplamı satışlardan');
select pg_temp.assert((select product from public.customer_sales order by created_at desc, product limit 1) in ('Eğitim','Danışmanlık paketi'), 'ürün adı kırpıldı');
select pg_temp.assert((select last_note from public.v_customers limit 1) like 'Satış: %', 'son not satış');
do $$ declare cid uuid := (select id from public.customers limit 1); begin
  begin perform public.add_sale(cid, 'x', 0, 10); raise exception 'sıfır adet'; exception when raise_exception then if sqlerrm like 'sıfır adet' then raise; end if; end;
  begin perform public.add_sale(cid, 'x', 1, -1); raise exception 'negatif tutar'; exception when raise_exception then if sqlerrm like 'negatif tutar' then raise; end if; end;
  begin perform public.add_sale(cid, '  ', 1, 1); raise exception 'boş ürün'; exception when raise_exception then if sqlerrm like 'boş ürün' then raise; end if; end;
  begin perform public.set_customer_stage(cid, 'designing'); raise exception 'eski aşama'; exception when raise_exception then if sqlerrm like 'eski aşama' then raise; end if; end;
  begin perform public.update_customer(cid, '{"amount":"5"}'::jsonb); raise exception 'tutar patch'; exception when raise_exception then if sqlerrm like 'tutar patch' then raise; end if; end;
  begin insert into public.customer_sales (workspace_id, customer_id, product, quantity, amount) values (public.my_ws(), cid, 'x', 1, 1); raise exception 'doğrudan satış'; exception when insufficient_privilege then null; end;
end $$;
select public.delete_sale((select id from public.customer_sales where product = 'Eğitim'));
select pg_temp.assert((select sales_total from public.v_customers limit 1) = 3000, 'satış silindi');

-- Pilot, Vitrin müşterisini göremez ve değiştiremez
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select pg_temp.assert((select count(*) from public.v_customers) = 0 and (select count(*) from public.customer_sales) = 0, 'pilot Vitrin müşterilerini görmez');
do $$ declare cid uuid; begin
  reset role; select id into cid from public.customers limit 1; set role authenticated;
  perform set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
  begin perform public.add_sale(cid, 'x', 1, 1); raise exception 'başka alan satış'; exception when raise_exception then if sqlerrm like 'başka alan%' then raise; end if; end;
  begin perform public.add_customer_note(cid, 'x'); raise exception 'başka alan not'; exception when raise_exception then if sqlerrm like 'başka alan%' then raise; end if; end;
  begin perform public.set_customer_stage(cid, 'contacted'); raise exception 'başka alan aşama'; exception when raise_exception then if sqlerrm like 'başka alan%' then raise; end if; end;
  if (select count(*) from public.customer_timeline(cid)) <> 0 then raise exception 'TEST BAŞARISIZ: başka alanın zaman çizelgesi göründü'; end if;
end $$;

-- operasyon rolü aşama, not ve satış yönetir
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.assert((select count(*) from public.v_customers) = 1, 'operasyon müşteriyi görür');
select public.update_customer((select id from public.customers limit 1), '{"next_step":"Sözleşme gönder","next_step_at":"2026-10-20T10:00:00+03:00"}'::jsonb);
select pg_temp.assert((select next_step from public.customers limit 1) = 'Sözleşme gönder', 'sıradaki adım güncellendi');
select public.add_customer_note((select id from public.customers limit 1), '  Müşteri sözleşmeyi imzaladı  ');
select pg_temp.assert((select last_note from public.v_customers limit 1) = 'Müşteri sözleşmeyi imzaladı', 'son not görünümde (kırpılmış)');
select pg_temp.assert((select author from public.customer_timeline((select id from public.customers limit 1)) limit 1) = 'c', 'yazan kişi (ad yoksa e-posta başı)');
do $$ begin
  begin insert into public.customers (name, workspace_id) values ('doğrudan', public.my_ws()); raise exception 'doğrudan insert'; exception when insufficient_privilege then null; end;
  begin update public.customers set stage = 'won'; raise exception 'doğrudan update'; exception when insufficient_privilege then null; end;
  begin delete from public.customer_notes; raise exception 'doğrudan delete'; exception when insufficient_privilege then null; end;
end $$;
-- elle müşteri ekleme
select public.create_customer('Elle Eklenen Kafe', '0532 000 11 22', 'Ankara', 'kafe', 'Tanıdık yoluyla geldi');
select pg_temp.assert((select count(*) from public.customers) = 2 and (select stage from public.customers where name = 'Elle Eklenen Kafe') = 'contacted', 'elle müşteri eklendi');
do $$ begin
  begin perform public.create_customer('x'); raise exception 'kısa ad'; exception when raise_exception then if sqlerrm like 'kısa ad' then raise; end if; end;
end $$;

-- ===================== Aylık rapor =====================
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
reset role;
insert into public.scan_history (workspace_id, city, district, sector, saved, places_found, api_calls) values (current_setting('t.plat')::uuid, 'Ankara', 'Çankaya', 'kuaför', 3, 40, 2);
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.assert((public.monthly_report()->>'contacted')::int = 3, 'rapor: aranan işletme 3 = ' || (public.monthly_report()->>'contacted'));
select pg_temp.assert((public.monthly_report()->>'positive')::int = 1 and (public.monthly_report()->>'won')::int = 1, 'rapor: olumlu ve satış');
select pg_temp.assert((public.monthly_report()->>'rejected')::int = 1 and (public.monthly_report()->>'unreachable')::int = 1, 'rapor: red ve ulaşılamayan');
select pg_temp.assert((public.monthly_report()->'reasons'->0->>'label') = 'İhtiyacı yok', 'rapor: ret sebebi etiketi');
select pg_temp.assert((public.monthly_report()->>'sales_total')::numeric = 3000 and (public.monthly_report()->>'sales_qty')::int = 2, 'rapor: satış toplamı ve adet');
select pg_temp.assert((public.monthly_report()->>'leads_found')::int = 3, 'rapor: bu ay bulunan işletme');
select pg_temp.assert((public.monthly_report()->'products'->0->>'product') = 'Danışmanlık paketi', 'rapor: ürün dağılımı');
select pg_temp.assert(jsonb_array_length(public.monthly_report()->'people') >= 1, 'rapor: kişi dağılımı');
select pg_temp.assert((public.monthly_report((now() - interval '2 months')::date)->>'actions')::int = 0, 'rapor: geçmiş ay boş');
select pg_temp.assert((select leads_this_month from public.my_access()) = 3, 'kota sayacı tarama geçmişinden');
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select pg_temp.assert((public.monthly_report()->>'actions')::int = 0 and (public.monthly_report()->>'sales_total')::numeric = 0, 'pilot raporu yalnızca kendi verisi');

-- ===================== Kayıt bilgileri ve yönetim paneli =====================
reset role;
update auth.users set raw_user_meta_data = '{"full_name":"Deniz Kaya","company":"Kaya Hukuk","phone":"0532 000 00 00"}' where id = '44444444-4444-4444-4444-444444444444';
update public.scan_history set user_id = '11111111-1111-1111-1111-111111111111' where workspace_id = public.platform_ws();
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.assert((select full_name || '|' || company || '|' || phone from public.team_list() where user_id = '44444444-4444-4444-4444-444444444444') = 'Deniz Kaya|Kaya Hukuk|0532 000 00 00', 'kayıt bilgileri platform yöneticisine görünür');
select pg_temp.assert((public.admin_usage()->'totals'->>'api_calls')::int = 2 and (public.admin_usage()->'totals'->>'leads')::int = 3, 'yönetim: Google çağrısı ve bulunan işletme');
select pg_temp.assert((public.admin_usage()->'totals'->>'pending')::int = 1, 'yönetim: onay bekleyen 1 kişi');
select pg_temp.assert((public.admin_usage()->'totals'->>'users')::int = 6, 'yönetim: toplam kullanıcı');
select pg_temp.assert((select (x->>'api_calls')::int from jsonb_array_elements(public.admin_usage()->'users') x where x->>'email' = 'a@vitrin.test') = 2, 'yönetim: kişi bazında Google çağrısı');
select pg_temp.assert((select x->>'name' from jsonb_array_elements(public.admin_usage()->'users') x where x->>'email' = 'd@vitrin.test') = 'Deniz Kaya'
  and (select x->>'company' from jsonb_array_elements(public.admin_usage()->'users') x where x->>'email' = 'd@vitrin.test') = 'Kaya Hukuk', 'yönetim: onay bekleyenin adı ve şirketi');
select pg_temp.assert(jsonb_array_length(public.admin_usage()->'workspaces') = 3, 'yönetim: her alan listelenir');
select pg_temp.assert((select (x->>'actions')::int from jsonb_array_elements(public.admin_usage()->'workspaces') x where x->>'name' = 'Vitrin') >= 5, 'yönetim: alan bazında işlem');
select pg_temp.assert((public.admin_usage((now() - interval '2 months')::date)->'totals'->>'api_calls')::int = 0, 'yönetim: geçmiş ay boş');
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';   -- pilot yöneticisi
select pg_temp.assert((select company from public.team_list() limit 1) is null, 'şirket/telefon bilgisi alan yöneticisine gösterilmez');
do $$ begin
  begin perform public.admin_usage(); raise exception 'pilot yönetim panelini gördü'; exception when raise_exception then if sqlerrm like 'pilot%' then raise; end if; end;
end $$;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$ begin
  begin perform public.admin_usage(); raise exception 'satış yönetim panelini gördü'; exception when raise_exception then if sqlerrm like 'satış%' then raise; end if; end;
end $$;

-- Eski veri: durumu 'won' olup müşterisi olmayan işletme şema yeniden çalışınca müşteri olur
reset role;
update public.businesses set status = 'won' where name = 'Üçüncü';

reset role;
\echo TÜM TESTLER GEÇTİ
