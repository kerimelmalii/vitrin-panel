-- =====================================================================
-- Vitrin – müşteri bulma paneli şeması (tek dosya, tekrar çalıştırılabilir)
-- Supabase > SQL Editor'e yapıştırıp Run. Mevcut veriyi silmez;
-- eksik tablo/sütun/fonksiyonları ekler, fonksiyonları günceller.
--
-- Çalışma alanları: her şirket (Vitrin, pilot şirket…) ayrı bir alandır. Kullanıcı yalnızca
-- kendi alanının verisini görür; bu kural veritabanında (satır düzeyinde güvenlik) zorunludur.
-- Platform alanının (Vitrin) yöneticileri yeni alan açar ve kullanıcıları alanlara atar.
-- =====================================================================

-- ---------- Çalışma alanları ----------
create table if not exists public.workspaces (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique,
  name               text not null,
  is_platform        boolean not null default false,   -- Vitrin: diğer alanları yönetir
  is_demo            boolean not null default false,   -- panelde "Demo sürüm" şeridi
  lead_quota         int,                              -- aylık en çok kaydedilecek işletme (null = sınırsız)
  weekly_goal        int not null default 100,
  wa_daily_limit     int not null default 20,
  message_template   text not null default '',         -- boşsa WhatsApp boş mesajla açılır
  sector_suggestions text[] not null default '{}',
  created_at         timestamptz not null default now()
);
alter table public.workspaces drop constraint if exists workspaces_quota_chk;
alter table public.workspaces add constraint workspaces_quota_chk check (lead_quota is null or lead_quota >= 0);
alter table public.workspaces drop constraint if exists workspaces_goal_chk;
alter table public.workspaces add constraint workspaces_goal_chk check (weekly_goal between 1 and 10000 and wa_daily_limit between 1 and 1000);

insert into public.workspaces (slug, name, is_platform, sector_suggestions)
select 'vitrin', 'Vitrin', true,
       array['diş kliniği','poliklinik','fizik tedavi merkezi','psikolog','diyetisyen','veteriner kliniği',
             'avukat','mali müşavir','danışmanlık firması','emlak ofisi','güzellik salonu','spor salonu']
where not exists (select 1 from public.workspaces where is_platform);

-- Mevcut kayıtların ait olduğu alan: platform alanı (Vitrin)
create or replace function public.platform_ws() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.workspaces where is_platform order by created_at limit 1
$$;

-- ---------- Tablolar ----------
create table if not exists public.businesses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

alter table public.businesses
  add column if not exists place_id        text,
  add column if not exists address         text,
  add column if not exists city            text not null default '',
  add column if not exists district        text,
  add column if not exists sector          text not null default '',
  add column if not exists phone_raw       text,
  add column if not exists phone_normalized text,
  add column if not exists rating          numeric(2,1),
  add column if not exists review_count    int,
  add column if not exists website_status  text not null default 'none',
  add column if not exists maps_url        text,
  add column if not exists lead_score      int  not null default 0,
  add column if not exists status          text not null default 'new',
  add column if not exists call_list       boolean not null default false,
  add column if not exists no_answer_count int  not null default 0,
  add column if not exists attempt_count   int  not null default 0,
  add column if not exists next_action_at  timestamptz,
  add column if not exists claimed_by      uuid,
  add column if not exists claimed_at      timestamptz,
  add column if not exists updated_at      timestamptz not null default now(),
  add column if not exists source          text not null default 'google',
  add column if not exists category        text,                -- Google kategorisi (örn. "Özel hastane", "Diş hekimi")
  add column if not exists category_type   text,                -- Google tür kodu (örn. hospital, dentist)
  add column if not exists workspace_id    uuid references public.workspaces(id) on delete cascade;

-- Cep numarası mı? (+905XXXXXXXXX) – WhatsApp listesi bununla ayrılır
do $$ begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='businesses' and column_name='is_mobile') then
    alter table public.businesses add column is_mobile boolean
      generated always as (coalesce(phone_normalized ~ '^\+905[0-9]{9}$', false)) stored;
  end if;
end $$;

create table if not exists public.calls (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  outcome     text not null,
  note        text,
  callback_at timestamptz,
  called_at   timestamptz not null default now()
);
alter table public.calls add column if not exists user_id uuid;
alter table public.calls add column if not exists reason text;
alter table public.calls add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;
create index if not exists calls_called_at_idx on public.calls (called_at desc);
create index if not exists calls_business_idx  on public.calls (business_id);

-- Taranmayacak bölgeler (district boşsa şehrin tamamı kapalı), alan başına
create table if not exists public.closed_regions (
  id         uuid primary key default gen_random_uuid(),
  city       text not null,
  district   text,
  reason     text,
  created_at timestamptz not null default now()
);
alter table public.closed_regions add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;

-- Tarama geçmişi (aynı bölge+sektör 90 gün tekrar taranmaz; aylık kota buradan sayılır)
create table if not exists public.scan_history (
  id           uuid primary key default gen_random_uuid(),
  city         text not null,
  district     text not null default '',
  sector       text not null,
  scanned_at   timestamptz not null default now(),
  places_found int not null default 0,
  saved        int not null default 0,
  api_calls    int not null default 0
);
alter table public.scan_history add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;
alter table public.scan_history add column if not exists user_id uuid;   -- taramayı kim yaptı (yönetim paneli)

-- ---------- Roller ----------
-- Kullanıcıyı Supabase > Authentication > Users'tan siz eklersiniz; alanını ve rolünü panelde "Ekip" sekmesinden verirsiniz.
-- Rolü olmayan kullanıcı hiçbir veriyi göremez. Bir kullanıcı tek bir alana aittir.
create table if not exists public.user_roles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  role         text not null check (role in ('admin','sales','designer')),
  display_name text,
  created_at   timestamptz not null default now()
);
alter table public.user_roles add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;

-- ---------- Müşteriler (iletişime geçilen → anlaşma → satış) ----------
create table if not exists public.customers (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid unique references public.businesses(id) on delete set null,
  name             text not null,
  phone            text,
  city             text,
  sector           text,
  stage            text not null default 'contacted',
  amount           numeric(12,2),
  domain           text,
  next_step        text,
  next_step_at     timestamptz,
  stage_changed_at timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.customers add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;

create table if not exists public.customer_notes (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  user_id     uuid,
  kind        text not null default 'note',
  body        text not null,
  created_at  timestamptz not null default now()
);
alter table public.customer_notes add column if not exists workspace_id uuid references public.workspaces(id) on delete cascade;
alter table public.customer_notes drop constraint if exists customer_notes_kind_check;
alter table public.customer_notes drop constraint if exists customer_notes_kind_chk;
alter table public.customer_notes add constraint customer_notes_kind_chk check (kind in ('note','stage','created','edit','sale'));
create index if not exists customer_notes_idx on public.customer_notes (customer_id, created_at desc);

-- Satış kalemleri: hangi üründen kaç adet, toplam kaça
create table if not exists public.customer_sales (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  customer_id  uuid not null references public.customers(id) on delete cascade,
  product      text not null check (length(btrim(product)) between 1 and 120),
  quantity     int  not null check (quantity between 1 and 1000000),
  amount       numeric(12,2) not null check (amount >= 0),
  user_id      uuid,
  sold_at      timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index if not exists customer_sales_idx on public.customer_sales (customer_id, sold_at desc);
create index if not exists customer_sales_ws_idx on public.customer_sales (workspace_id, sold_at desc);

-- ---------- Mevcut veriyi platform alanına bağla (tek seferlik, tekrar çalışınca bir şey yapmaz) ----------
update public.businesses     set workspace_id = public.platform_ws() where workspace_id is null;
update public.calls c        set workspace_id = coalesce((select b.workspace_id from public.businesses b where b.id = c.business_id), public.platform_ws()) where workspace_id is null;
update public.closed_regions set workspace_id = public.platform_ws() where workspace_id is null;
update public.scan_history   set workspace_id = public.platform_ws() where workspace_id is null;
update public.user_roles     set workspace_id = public.platform_ws() where workspace_id is null;
update public.customers      set workspace_id = public.platform_ws() where workspace_id is null;
update public.customer_notes n set workspace_id = coalesce((select c.workspace_id from public.customers c where c.id = n.customer_id), public.platform_ws()) where workspace_id is null;
alter table public.businesses     alter column workspace_id set not null;
alter table public.calls          alter column workspace_id set not null;
alter table public.closed_regions alter column workspace_id set not null;
alter table public.scan_history   alter column workspace_id set not null;
alter table public.user_roles     alter column workspace_id set not null;
alter table public.customers      alter column workspace_id set not null;
alter table public.customer_notes alter column workspace_id set not null;

-- Kısıtlamalar veri doldurulduktan sonra eklenir (NOT VALID: eski tuhaf değerler kalabilir, yeni yazılanlar denetlenir)
-- Eski migration'dan kalan otomatik adlı kısıtlamalar yenileriyle çakışmasın
alter table public.businesses drop constraint if exists businesses_status_check;
alter table public.businesses drop constraint if exists businesses_status_chk;
alter table public.businesses add constraint businesses_status_chk check (status in
  ('new','wa_sent','no_answer','callback','interested','won','rejected','do_not_contact',
   'wrong_number','closed_business','unreachable')) not valid;
-- Web sitesi hizmeti kaldırıldı: site durumu artık filtre değil, yalnızca bilgi
alter table public.businesses drop constraint if exists businesses_website_chk;
alter table public.businesses add constraint businesses_website_chk
  check (website_status in ('none','social_only','has_site')) not valid;
alter table public.businesses drop constraint if exists businesses_source_chk;
alter table public.businesses add constraint businesses_source_chk check (source in ('google','manual','open_data')) not valid;

alter table public.calls drop constraint if exists calls_outcome_check;
alter table public.calls drop constraint if exists calls_outcome_chk;
alter table public.calls add constraint calls_outcome_chk check (outcome in
  ('wa_sent','no_answer','callback','interested','won','rejected','do_not_contact',
   'wrong_number','closed_business')) not valid;
-- Ret sebepleri (aylık raporda dağılımı görünür)
alter table public.calls drop constraint if exists calls_reason_chk;
alter table public.calls add constraint calls_reason_chk check (reason is null or reason in
  ('no_need','price','has_provider','timing','not_authorized','other'));

-- Aynı işletme / aynı telefon bir alanda iki kez eklenemez (farklı alanlar birbirini etkilemez)
drop index if exists public.businesses_place_id_uniq;
drop index if exists public.businesses_phone_uniq;
alter table public.businesses drop constraint if exists businesses_place_id_key;
alter table public.businesses drop constraint if exists businesses_phone_normalized_key;
create unique index if not exists businesses_ws_place_uniq on public.businesses (workspace_id, place_id) where place_id is not null;
create unique index if not exists businesses_ws_phone_uniq on public.businesses (workspace_id, phone_normalized) where phone_normalized is not null;
drop index if exists public.businesses_queue_idx;
drop index if exists public.businesses_filter_idx;
create index if not exists businesses_ws_queue_idx  on public.businesses (workspace_id, status, next_action_at);
create index if not exists businesses_ws_filter_idx on public.businesses (workspace_id, city, sector);
create index if not exists calls_ws_idx on public.calls (workspace_id, called_at desc);
create index if not exists scan_history_ws_idx on public.scan_history (workspace_id, scanned_at desc);
drop index if exists public.scan_history_lookup;
drop index if exists public.closed_regions_uniq;
create unique index if not exists closed_regions_ws_uniq
  on public.closed_regions (workspace_id, lower(city), lower(coalesce(district, '')));
create index if not exists customers_ws_idx on public.customers (workspace_id, stage, stage_changed_at desc);
drop index if exists public.customers_stage_idx;

insert into public.closed_regions (workspace_id, city, reason)
select public.platform_ws(), 'Bursa', 'Kapalı bölge'
where not exists (select 1 from public.closed_regions where workspace_id = public.platform_ws() and lower(city) = 'bursa' and district is null);

-- Müşteri aşamaları sadeleşti: İletişimde → Anlaşma aşamasında → Satış tamamlandı
alter table public.customers drop constraint if exists customers_stage_chk;
update public.customers set stage = case
  when stage in ('contacted','negotiating','won') then stage
  when stage = 'paused' then 'negotiating'
  when stage = 'cancelled' then 'contacted'
  else 'won' end
 where stage not in ('contacted','negotiating','won');
alter table public.customers alter column stage set default 'contacted';
alter table public.customers add constraint customers_stage_chk check (stage in ('contacted','negotiating','won'));
alter table public.customers drop constraint if exists customers_amount_chk;
alter table public.customers add constraint customers_amount_chk check (amount is null or amount >= 0);
-- Eski tek "tutar" alanı satış kalemine taşınır (bir kez)
insert into public.customer_sales (workspace_id, customer_id, product, quantity, amount, sold_at)
select c.workspace_id, c.id, 'Satış', 1, c.amount, c.stage_changed_at
  from public.customers c
 where c.amount is not null and c.amount > 0
   and not exists (select 1 from public.customer_sales s where s.customer_id = c.id);
update public.customers set amount = null where amount is not null;

-- ---------- Yetki yardımcıları ----------
-- Rol -> izin eşlemesi tek yerde.
--   leads: satış listeleri/geçmiş/rapor · scan: bölge tarama · customers: müşteri panosunu görme · customers_write: aşama/not/satış
--   team: ekip ve alan ayarları
create or replace function public.role_perms(r text) returns text[]
language sql immutable as $$
  select case r
    when 'admin'    then array['leads','scan','customers','customers_write','team']
    when 'sales'    then array['leads','scan','customers','customers_write']
    when 'designer' then array['customers','customers_write']
    else array[]::text[] end
$$;

create or replace function public.my_ws() returns uuid
language sql stable security definer set search_path = public as $$
  select ur.workspace_id from public.user_roles ur where ur.user_id = auth.uid()
$$;

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p = any (public.role_perms((select ur.role from public.user_roles ur where ur.user_id = auth.uid()))), false)
$$;

-- Platform (Vitrin) alanının yöneticisi mi? Alan açar, kullanıcıları alanlara atar.
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles ur join public.workspaces w on w.id = ur.workspace_id
                  where ur.user_id = auth.uid() and ur.role = 'admin' and w.is_platform)
$$;

-- Türkiye saatiyle ayın başı
create or replace function public.tr_month_start(t timestamptz default now()) returns timestamptz
language sql stable as $$
  select date_trunc('month', t at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul'
$$;

-- Bu ay taramayla kaydedilen işletme sayısı (kota). Tarama geçmişinden sayılır: silinen kayıtlar kotayı geri vermez.
create or replace function public.ws_leads_this_month(p_ws uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(saved), 0)::int from public.scan_history
   where workspace_id = p_ws and scanned_at >= public.tr_month_start()
$$;

-- Mevcut kullanıcılar kilitli kalmasın: rol tablosu boşsa en eski kullanıcı yönetici, diğerleri satış olur
insert into public.user_roles (user_id, role, workspace_id)
select u.id, case when row_number() over (order by u.created_at, u.id) = 1 then 'admin' else 'sales' end, public.platform_ws()
  from auth.users u
 where not exists (select 1 from public.user_roles)
on conflict do nothing;

-- Satışı kaydedilmiş ama müşteri kaydı olmayanlar (eski veriler) için müşteri oluştur
insert into public.customers (workspace_id, business_id, name, phone, city, sector, stage)
select b.workspace_id, b.id, b.name, coalesce(b.phone_raw, b.phone_normalized), nullif(b.city, ''), nullif(b.sector, ''), 'won'
  from public.businesses b
 where b.status = 'won' and not exists (select 1 from public.customers c where c.business_id = b.id);

-- ---------- Güvenlik: kayıt kapalı, tarayıcı sadece kendi alanını okur; yazma yalnızca fonksiyonlarla ----------
alter table public.workspaces     enable row level security;
alter table public.user_roles     enable row level security;
alter table public.businesses     enable row level security;
alter table public.calls          enable row level security;
alter table public.closed_regions enable row level security;
alter table public.scan_history   enable row level security;
alter table public.customers      enable row level security;
alter table public.customer_notes enable row level security;
alter table public.customer_sales enable row level security;

drop policy if exists p_read on public.workspaces;
create policy p_read on public.workspaces for select to authenticated
  using (id = (select public.my_ws()) or (select public.is_platform_admin()));
drop policy if exists p_own on public.user_roles;
create policy p_own on public.user_roles for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists p_read on public.businesses;
create policy p_read on public.businesses for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('leads')));
drop policy if exists p_read on public.calls;
create policy p_read on public.calls for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('leads')));
drop policy if exists p_read on public.closed_regions;
create policy p_read on public.closed_regions for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('scan')));
drop policy if exists p_read on public.scan_history;
create policy p_read on public.scan_history for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('scan')));
drop policy if exists p_read on public.customers;
create policy p_read on public.customers for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('customers')));
drop policy if exists p_read on public.customer_notes;
create policy p_read on public.customer_notes for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('customers')));
drop policy if exists p_read on public.customer_sales;
create policy p_read on public.customer_sales for select to authenticated
  using (workspace_id = (select public.my_ws()) and (select public.has_perm('customers')));

revoke all on public.workspaces, public.user_roles, public.businesses, public.calls, public.closed_regions, public.scan_history,
  public.customers, public.customer_notes, public.customer_sales from anon, authenticated;
grant select on public.workspaces, public.user_roles, public.businesses, public.calls, public.closed_regions, public.scan_history,
  public.customers, public.customer_notes, public.customer_sales to authenticated;

-- ---------- Liste mantığı (tek yerde) ----------
--  whatsapp : yeni + cep numarası + arama listesine alınmamış
--  call     : yeni + (sabit hat veya arama listesine alınmış), ya da açmayan (en çok 3 deneme) vadesi gelmiş
--  followup : vadesi gelen "sonra ara", WhatsApp'ı 3 gün önce gidenler, ilgilenenler
--  sent     : WhatsApp'ı son 3 günde gönderilenler (dönüş olursa sonucu değiştirmek için)
--  30 gün içinde hiç işlenmeyen kayıt listeye girmez (ve purge_stale_leads ile silinir)
drop view if exists public.v_queue;
create view public.v_queue with (security_invoker = true) as
select b.*,
  case
    when b.status = 'new' and b.attempt_count = 0 and b.created_at < now() - interval '30 days' then null
    when b.status = 'callback'                 and b.next_action_at <= now() then 'followup'
    when b.status in ('wa_sent','interested')  and b.next_action_at <= now() then 'followup'
    when b.status = 'wa_sent'                  and b.next_action_at >  now() then 'sent'
    when b.status = 'no_answer' and b.no_answer_count < 3 and b.next_action_at <= now() then 'call'
    when b.status = 'new' and (not b.is_mobile or b.call_list) then 'call'
    when b.status = 'new' then 'whatsapp'
  end as lst
from public.businesses b;

-- ---------- Fonksiyonlar ----------
-- Eski sürümlerden kalan farklı imzalı/dönüş tipli fonksiyonlar güncellemeyi engellemesin
drop function if exists public.next_business(text,text,text,uuid[]);
drop function if exists public.release_business(uuid);
drop function if exists public.move_to_call_list(uuid);
drop function if exists public.log_call(uuid,text,text,timestamptz);
drop function if exists public.log_call(uuid,text,text,timestamptz,text);
drop function if exists public.list_counts(text,text);
drop function if exists public.filter_options();
drop function if exists public.stats();
drop function if exists public.search_history(text,int);
drop function if exists public.ingest_businesses(jsonb);
drop function if exists public.ingest_businesses(uuid,jsonb);
drop function if exists public.my_access();
drop function if exists public.team_list();
drop function if exists public.set_user_role(uuid,text,text);
drop function if exists public.set_user_role(uuid,text,text,uuid);
drop function if exists public.create_customer(text,text,text,text,numeric,text);
drop function if exists public.create_customer(text,text,text,text,text);
drop function if exists public.update_customer(uuid,jsonb);
drop function if exists public.set_customer_stage(uuid,text,text);
drop function if exists public.add_customer_note(uuid,text);
drop function if exists public.user_can(uuid,text);
drop function if exists public.stage_label(text);
drop function if exists public.customer_timeline(uuid);
drop function if exists public.add_sale(uuid,text,int,numeric);
drop function if exists public.delete_sale(uuid);
drop function if exists public.scan_context(uuid);
drop function if exists public.purge_stale_leads();
drop function if exists public.monthly_report(date);
drop function if exists public.list_workspaces();
drop function if exists public.create_workspace(text,boolean,int);
drop function if exists public.update_workspace(uuid,jsonb);
drop function if exists public.admin_usage(date);

create or replace function public.next_business(p_list text, p_city text default null,
                                                p_sector text default null, p_skip uuid[] default '{}')
returns setof public.businesses
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ws uuid := public.my_ws(); v public.businesses; cand uuid; tries int := 0;
begin
  if uid is null or ws is null or not public.has_perm('leads') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_list not in ('whatsapp','call','followup','sent') then raise exception 'Geçersiz liste'; end if;
  loop
    tries := tries + 1;
    -- Başkasının son 15 dk içinde açtığı kart atlanır; kendi açık kartım önce gelir
    select q.id into cand from public.v_queue q
     where q.workspace_id = ws and q.lst = p_list
       and (p_city   is null or p_city   = '' or q.city   = p_city)
       and (p_sector is null or p_sector = '' or q.sector = p_sector)
       and (q.claimed_by is null or q.claimed_by = uid or q.claimed_at < now() - interval '15 minutes')
       and not (q.id = any (coalesce(p_skip, '{}')))
     order by (q.claimed_by = uid) desc nulls last,
              (case when p_list = 'sent' then q.updated_at end) desc nulls last,
              (q.status = 'callback') desc,
              q.next_action_at asc nulls last,
              q.lead_score desc, q.created_at asc
     limit 1;
    exit when cand is null;
    update public.businesses b set claimed_by = uid, claimed_at = now()
     where b.id = cand and b.workspace_id = ws
       and (b.claimed_by is null or b.claimed_by = uid or b.claimed_at < now() - interval '15 minutes')
     returning b.* into v;
    if found then return next v; return; end if;
    exit when tries >= 3;
  end loop;
  return;
end $$;

create or replace function public.release_business(p_business_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.businesses set claimed_by = null, claimed_at = null
   where id = p_business_id and claimed_by = auth.uid() and workspace_id = public.my_ws() and public.has_perm('leads');
$$;

create or replace function public.move_to_call_list(p_business_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('leads') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  update public.businesses set call_list = true, updated_at = now()
   where id = p_business_id and status = 'new' and workspace_id = public.my_ws();
end $$;

create or replace function public.stage_label(s text) returns text language sql immutable as $$
  select case s when 'contacted' then 'İletişimde' when 'negotiating' then 'Anlaşma aşamasında'
                when 'won' then 'Satış tamamlandı' else s end
$$;

create or replace function public.reason_label(r text) returns text language sql immutable as $$
  select case r when 'no_need' then 'İhtiyacı yok' when 'price' then 'Fiyat yüksek' when 'has_provider' then 'Başka firmayla çalışıyor'
                when 'timing' then 'Zamanlama uygun değil' when 'not_authorized' then 'Yetkili değil / ulaşılamadı'
                when 'other' then 'Diğer' else coalesce(r, 'Belirtilmedi') end
$$;

create or replace function public.log_call(p_business_id uuid, p_outcome text,
                                           p_note text default null, p_callback_at timestamptz default null,
                                           p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.businesses; new_status text; next_at timestamptz; na int; cid uuid; ws uuid := public.my_ws(); old_stage text;
begin
  if not public.has_perm('leads') or ws is null then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_outcome not in ('wa_sent','no_answer','callback','interested','won','rejected',
                       'do_not_contact','wrong_number','closed_business') then
    raise exception 'Geçersiz sonuç: %', p_outcome;
  end if;
  if p_reason is not null and (p_outcome not in ('rejected','do_not_contact')
     or p_reason not in ('no_need','price','has_provider','timing','not_authorized','other')) then
    raise exception 'Geçersiz ret sebebi';
  end if;
  select * into b from public.businesses where id = p_business_id and workspace_id = ws for update;
  if not found then raise exception 'İşletme bulunamadı'; end if;
  if b.status in ('rejected','do_not_contact','wrong_number','closed_business','won','unreachable') then
    raise exception 'Bu işletme kapatılmış, tekrar işlenemez';
  end if;

  na := b.no_answer_count;
  case p_outcome
    when 'wa_sent'    then new_status := 'wa_sent';    next_at := now() + interval '3 days';
    when 'no_answer'  then na := na + 1;
                           if na >= 3 then new_status := 'unreachable'; next_at := null;
                           else new_status := 'no_answer'; next_at := now() + interval '1 day'; end if;
    when 'callback'   then
      if p_callback_at is null then raise exception 'Geri arama tarihi gerekli'; end if;
      new_status := 'callback'; next_at := p_callback_at;
    when 'interested' then new_status := 'interested'; next_at := now() + interval '2 days';
    else new_status := p_outcome; next_at := null;     -- won / rejected / do_not_contact / wrong_number / closed_business
  end case;

  insert into public.calls (workspace_id, business_id, outcome, note, callback_at, user_id, reason)
  values (ws, p_business_id, p_outcome, nullif(btrim(p_note), ''), p_callback_at, auth.uid(), p_reason);

  update public.businesses
     set status = new_status, next_action_at = next_at, no_answer_count = na,
         attempt_count = attempt_count + 1, claimed_by = null, claimed_at = null, updated_at = now()
   where id = p_business_id;

  -- İlgilenen "İletişimde", satış "Satış tamamlandı" aşamasıyla Müşteriler'e düşer
  if p_outcome in ('interested','won') then
    select id, stage into cid, old_stage from public.customers where business_id = b.id;
    if cid is null then
      insert into public.customers (workspace_id, business_id, name, phone, city, sector, stage)
      values (ws, b.id, b.name, coalesce(b.phone_raw, b.phone_normalized), nullif(b.city, ''), nullif(b.sector, ''),
              case when p_outcome = 'won' then 'won' else 'contacted' end)
      returning id into cid;
      insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
      values (ws, cid, auth.uid(), 'created',
              (case when p_outcome = 'won' then 'Satış kaydedildi' else 'İlgilendi, iletişime geçildi' end)
              || coalesce(E'\n' || nullif(btrim(p_note), ''), ''));
    elsif p_outcome = 'won' and old_stage <> 'won' then
      update public.customers set stage = 'won', stage_changed_at = now(), updated_at = now() where id = cid;
      insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
      values (ws, cid, auth.uid(), 'stage', public.stage_label(old_stage) || ' → ' || public.stage_label('won')
              || coalesce(E'\n' || nullif(btrim(p_note), ''), ''));
    end if;
  end if;
end $$;

create or replace function public.list_counts(p_city text default null, p_sector text default null)
returns table (lst text, n bigint)
language sql stable security invoker set search_path = public as $$
  select q.lst, count(*) from public.v_queue q
   where q.lst is not null
     and (p_city   is null or p_city   = '' or q.city   = p_city)
     and (p_sector is null or p_sector = '' or q.sector = p_sector)
   group by q.lst;
$$;

create or replace function public.filter_options()
returns table (city text, sector text)
language sql stable security invoker set search_path = public as $$
  select distinct q.city, q.sector from public.v_queue q where q.lst is not null;
$$;

-- Hafta/gün sayaçları Türkiye saatine göre, alanın ekip toplamı
create or replace function public.stats()
returns table (week_total bigint, week_wa bigint, today_total bigint, today_wa bigint)
language sql stable security invoker set search_path = public as $$
  with b as (
    select (date_trunc('week', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul') as wk,
           (date_trunc('day',  now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul') as dy)
  select count(*) filter (where c.called_at >= b.wk),
         count(*) filter (where c.called_at >= b.wk and c.outcome = 'wa_sent'),
         count(*) filter (where c.called_at >= b.dy),
         count(*) filter (where c.called_at >= b.dy and c.outcome = 'wa_sent')
    from b left join public.calls c on c.called_at >= b.wk
   group by b.wk, b.dy;
$$;

create or replace function public.search_history(p_term text default '', p_limit int default 150)
returns table (called_at timestamptz, outcome text, note text, callback_at timestamptz,
               business_id uuid, name text, phone_raw text, city text, reason text)
language sql stable security invoker set search_path = public as $$
  select c.called_at, c.outcome, c.note, c.callback_at, b.id, b.name, b.phone_raw, b.city, c.reason
    from public.calls c join public.businesses b on b.id = c.business_id
   where coalesce(btrim(p_term), '') = ''
      or b.name ilike '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or c.note ilike '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or b.phone_raw like '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
   order by c.called_at desc
   limit least(coalesce(p_limit, 150), 500);
$$;

-- 30 gün kuralı: hiç işlenmemiş (aranmamış, yazılmamış) kayıtlar silinir; işlenenler kalır
create or replace function public.purge_stale_leads()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.businesses b
   where b.status = 'new' and b.attempt_count = 0 and b.created_at < now() - interval '30 days'
     and not exists (select 1 from public.customers c where c.business_id = b.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- Tarama servisi (service_role) için toplu ekleme: aynı alanda yinelenen place_id/telefon sessizce atlanır
create or replace function public.ingest_businesses(p_workspace uuid, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from public.workspaces where id = p_workspace) then raise exception 'Alan bulunamadı'; end if;
  perform public.purge_stale_leads();
  with ins as (
    insert into public.businesses (workspace_id, place_id, name, address, city, district, sector, phone_raw, phone_normalized,
                                   rating, review_count, website_status, maps_url, lead_score, source, category, category_type)
    select p_workspace, x.place_id, x.name, x.address, coalesce(x.city, ''), x.district, coalesce(x.sector, ''), x.phone_raw,
           x.phone_normalized, x.rating, x.review_count, coalesce(x.website_status, 'none'), x.maps_url,
           coalesce(x.lead_score, 0), 'google', left(nullif(btrim(x.category), ''), 80), left(nullif(btrim(x.category_type), ''), 60)
      from jsonb_to_recordset(p_rows) as x(place_id text, name text, address text, city text, district text,
             sector text, phone_raw text, phone_normalized text, rating numeric, review_count int,
             website_status text, maps_url text, lead_score int, category text, category_type text)
    on conflict do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

-- Tarama servisi (service_role) kullanıcının alanını, iznini ve kotasını sorar
create or replace function public.scan_context(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'workspace_id', w.id, 'can_scan', 'scan' = any (public.role_perms(ur.role)),
    'lead_quota', w.lead_quota, 'leads_this_month', public.ws_leads_this_month(w.id))
    from public.user_roles ur join public.workspaces w on w.id = ur.workspace_id
   where ur.user_id = p_user
$$;

-- ---------- Erişim, ekip ve alan fonksiyonları ----------
create or replace function public.my_access()
returns table (role text, perms text[], display_name text, workspace_id uuid, workspace_name text,
               is_platform boolean, is_platform_admin boolean, is_demo boolean, weekly_goal int, wa_daily_limit int,
               message_template text, sector_suggestions text[], lead_quota int, leads_this_month int)
language sql stable security definer set search_path = public as $$
  select coalesce(u.role, 'none'), public.role_perms(u.role), u.display_name, w.id, w.name,
         coalesce(w.is_platform, false), coalesce(u.role = 'admin' and w.is_platform, false), coalesce(w.is_demo, false),
         w.weekly_goal, w.wa_daily_limit, w.message_template, w.sector_suggestions, w.lead_quota,
         case when w.id is null then 0 else public.ws_leads_this_month(w.id) end
    from (select auth.uid() as id) a
    left join public.user_roles u on u.user_id = a.id
    left join public.workspaces w on w.id = u.workspace_id
   where a.id is not null;
$$;

-- Platform yöneticisi herkesi (alanı olmayanlar dahil) görür; alan yöneticisi yalnızca kendi alanını
-- Kayıt formunda girilen bilgiler (ad, şirket, telefon) kullanıcıya aittir: yalnızca gösterim için, platform yöneticisine
create or replace function public.team_list()
returns table (user_id uuid, email text, display_name text, role text, workspace_id uuid, workspace_name text,
               last_sign_in_at timestamptz, created_at timestamptz, full_name text, company text, phone text)
language plpgsql stable security definer set search_path = public as $$
declare plat boolean := public.is_platform_admin(); ws uuid := public.my_ws();
begin
  if not public.has_perm('team') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  return query
    select u.id, u.email::text, r.display_name, coalesce(r.role, 'none'), r.workspace_id, w.name,
           u.last_sign_in_at, u.created_at,
           left(nullif(btrim(u.raw_user_meta_data->>'full_name'), ''), 80),
           case when plat then left(nullif(btrim(u.raw_user_meta_data->>'company'), ''), 80) end,
           case when plat then left(nullif(btrim(u.raw_user_meta_data->>'phone'), ''), 30) end
      from auth.users u
      left join public.user_roles r on r.user_id = u.id
      left join public.workspaces w on w.id = r.workspace_id
     where plat or r.workspace_id = ws
     order by (r.workspace_id = ws) desc nulls last, w.name nulls first, u.created_at, u.id;
end $$;

create or replace function public.set_user_role(p_user uuid, p_role text, p_name text default null, p_workspace uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare plat boolean := public.is_platform_admin(); my uuid := public.my_ws(); cur public.user_roles; target_ws uuid;
begin
  if not public.has_perm('team') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_role not in ('admin','sales','designer','none') then raise exception 'Geçersiz rol: %', p_role; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Kullanıcı bulunamadı'; end if;
  select * into cur from public.user_roles where user_id = p_user;
  if not plat then
    -- alan yöneticisi yalnızca kendi alanındaki kişileri yönetir, başka alana taşıyamaz
    if cur.user_id is null or cur.workspace_id <> my then raise exception 'Bu kullanıcı sizin alanınızda değil'; end if;
    if p_workspace is not null and p_workspace <> my then raise exception 'Kullanıcıyı başka alana taşıyamazsınız'; end if;
  end if;
  -- Henüz bir alana bağlı olmayan kişi yanlışlıkla platform alanına düşmesin: alan açıkça seçilmeli
  if plat and cur.user_id is null and p_workspace is null and p_role <> 'none' then raise exception 'Önce şirketini seçin'; end if;
  target_ws := coalesce(p_workspace, cur.workspace_id, my);
  if not exists (select 1 from public.workspaces where id = target_ws) then raise exception 'Alan bulunamadı'; end if;
  -- Bir alanın son yöneticisi kaldırılamaz/düşürülemez/taşınamaz
  if cur.role = 'admin' and (p_role <> 'admin' or target_ws <> cur.workspace_id)
     and (select count(*) from public.user_roles where role = 'admin' and workspace_id = cur.workspace_id) <= 1 then
    raise exception 'Son yönetici kaldırılamaz veya düşürülemez';
  end if;
  if p_role = 'none' then
    delete from public.user_roles where user_id = p_user;
  else
    insert into public.user_roles (user_id, role, display_name, workspace_id) values (p_user, p_role, nullif(btrim(p_name), ''), target_ws)
    on conflict (user_id) do update set role = excluded.role, workspace_id = excluded.workspace_id,
      display_name = coalesce(nullif(btrim(p_name), ''), public.user_roles.display_name);
    -- başka alana taşınan kişinin açık kart kilidi bırakılır
    update public.businesses set claimed_by = null, claimed_at = null where claimed_by = p_user and workspace_id <> target_ws;
  end if;
end $$;

create or replace function public.list_workspaces()
returns table (id uuid, slug text, name text, is_platform boolean, is_demo boolean, lead_quota int, leads_this_month int,
               members bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Bu işlem için yetkiniz yok'; end if;
  return query
    select w.id, w.slug, w.name, w.is_platform, w.is_demo, w.lead_quota, public.ws_leads_this_month(w.id),
           (select count(*) from public.user_roles r where r.workspace_id = w.id), w.created_at
      from public.workspaces w order by w.is_platform desc, w.created_at;
end $$;

create or replace function public.create_workspace(p_name text, p_is_demo boolean default true, p_quota int default 500)
returns uuid language plpgsql security definer set search_path = public as $$
declare wid uuid; base text; s text; i int := 1;
begin
  if not public.is_platform_admin() then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 or length(p_name) > 60 then raise exception 'Alan adı 2-60 karakter olmalı'; end if;
  if p_quota is not null and p_quota < 0 then raise exception 'Kota negatif olamaz'; end if;
  base := regexp_replace(translate(lower(btrim(p_name)), 'çğıöşüâîû', 'cgiosuaiu'), '[^a-z0-9]+', '-', 'g');
  base := coalesce(nullif(btrim(base, '-'), ''), 'alan'); s := base;
  while exists (select 1 from public.workspaces where slug = s) loop i := i + 1; s := base || '-' || i; end loop;
  insert into public.workspaces (slug, name, is_demo, lead_quota, sector_suggestions)
  values (s, btrim(p_name), coalesce(p_is_demo, true), p_quota,
          array['özel hastane','diş kliniği','poliklinik','tıp merkezi','fizik tedavi merkezi','göz kliniği','estetik kliniği',
                'psikolog','diyetisyen','eczane','laboratuvar','avukat','hukuk bürosu','mali müşavir','danışmanlık firması'])
  returning id into wid;
  return wid;
end $$;

-- Alan ayarları. Alan yöneticisi: ad, hedef, WhatsApp sınırı, mesaj şablonu, sektör önerileri.
-- Demo/kota yalnızca platform yöneticisi tarafından değiştirilir.
create or replace function public.update_workspace(p_ws uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare plat boolean := public.is_platform_admin(); k text; tpl text; sec text[];
begin
  if not public.has_perm('team') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if not plat and p_ws is distinct from public.my_ws() then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if jsonb_typeof(p_patch) <> 'object' then raise exception 'Geçersiz istek'; end if;
  if not exists (select 1 from public.workspaces where id = p_ws) then raise exception 'Alan bulunamadı'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('name','weekly_goal','wa_daily_limit','message_template','sector_suggestions','is_demo','lead_quota') then
      raise exception 'Güncellenemeyen alan: %', k;
    end if;
    if k in ('is_demo','lead_quota') and not plat then raise exception 'Paket ve kota ayarlarını yalnızca Vitrin değiştirebilir'; end if;
  end loop;
  if p_patch ? 'message_template' then
    tpl := btrim(coalesce(p_patch->>'message_template', ''));
    if length(tpl) > 3000 then raise exception 'Mesaj şablonu en çok 3000 karakter olabilir'; end if;
    if tpl <> '' and tpl !~* 'iptal' then raise exception 'Mesajda "iptal" yazarak vazgeçme cümlesi bulunmalı'; end if;
  end if;
  if p_patch ? 'sector_suggestions' then
    if jsonb_typeof(p_patch->'sector_suggestions') <> 'array' then raise exception 'Sektör listesi geçersiz'; end if;
    select coalesce(array_agg(distinct lower(btrim(x))) filter (where length(btrim(x)) between 2 and 50), '{}')
      into sec from jsonb_array_elements_text(p_patch->'sector_suggestions') x;
    if cardinality(sec) > 40 then raise exception 'En fazla 40 sektör önerisi'; end if;
  end if;
  if p_patch ? 'name' and length(btrim(coalesce(p_patch->>'name', ''))) not between 2 and 60 then raise exception 'Alan adı 2-60 karakter olmalı'; end if;
  update public.workspaces set
    name               = case when p_patch ? 'name' then btrim(p_patch->>'name') else name end,
    weekly_goal        = case when p_patch ? 'weekly_goal' then (p_patch->>'weekly_goal')::int else weekly_goal end,
    wa_daily_limit     = case when p_patch ? 'wa_daily_limit' then (p_patch->>'wa_daily_limit')::int else wa_daily_limit end,
    message_template   = case when p_patch ? 'message_template' then tpl else message_template end,
    sector_suggestions = case when p_patch ? 'sector_suggestions' then sec else sector_suggestions end,
    is_demo            = case when p_patch ? 'is_demo' then (p_patch->>'is_demo')::boolean else is_demo end,
    lead_quota         = case when p_patch ? 'lead_quota' then nullif(p_patch->>'lead_quota', '')::int else lead_quota end
   where id = p_ws;
end $$;

-- ---------- Müşteri fonksiyonları ----------
drop view if exists public.v_customers;
create view public.v_customers with (security_invoker = true) as
select c.*, n.body as last_note, n.created_at as last_note_at,
       coalesce(s.total, 0)::numeric(12,2) as sales_total, coalesce(s.cnt, 0)::int as sales_count
  from public.customers c
  left join lateral (select body, created_at from public.customer_notes
                      where customer_id = c.id and kind in ('note','stage','sale')
                      order by created_at desc limit 1) n on true
  left join lateral (select sum(amount) as total, count(*) as cnt from public.customer_sales where customer_id = c.id) s on true;

create or replace function public.create_customer(p_name text, p_phone text default null, p_city text default null,
    p_sector text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; ws uuid := public.my_ws();
begin
  if not public.has_perm('customers_write') or ws is null then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 or length(p_name) > 120 then raise exception 'Müşteri adı 2-120 karakter olmalı'; end if;
  insert into public.customers (workspace_id, name, phone, city, sector, stage)
  values (ws, btrim(p_name), nullif(btrim(p_phone), ''), nullif(btrim(p_city), ''), nullif(btrim(p_sector), ''), 'contacted')
  returning id into cid;
  insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
  values (ws, cid, auth.uid(), 'created', coalesce(nullif(btrim(p_note), ''), 'Müşteri elle eklendi'));
  return cid;
end $$;

create or replace function public.update_customer(p_id uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k text; labels text[] := '{}'; ws uuid := public.my_ws();
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if jsonb_typeof(p_patch) <> 'object' then raise exception 'Geçersiz istek'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('name','phone','city','sector','next_step','next_step_at') then
      raise exception 'Güncellenemeyen alan: %', k;
    end if;
    labels := labels || case k when 'name' then 'ad' when 'phone' then 'telefon' when 'city' then 'şehir' when 'sector' then 'sektör'
      when 'next_step' then 'sıradaki adım' else 'adım tarihi' end;
  end loop;
  if p_patch ? 'name' and length(btrim(coalesce(p_patch->>'name', ''))) < 2 then raise exception 'Müşteri adı en az 2 karakter olmalı'; end if;
  perform 1 from public.customers where id = p_id and workspace_id = ws for update;
  if not found then raise exception 'Müşteri bulunamadı'; end if;
  update public.customers set
    name         = case when p_patch ? 'name'         then btrim(p_patch->>'name') else name end,
    phone        = case when p_patch ? 'phone'        then nullif(btrim(p_patch->>'phone'), '') else phone end,
    city         = case when p_patch ? 'city'         then nullif(btrim(p_patch->>'city'), '') else city end,
    sector       = case when p_patch ? 'sector'       then nullif(btrim(p_patch->>'sector'), '') else sector end,
    next_step    = case when p_patch ? 'next_step'    then nullif(btrim(p_patch->>'next_step'), '') else next_step end,
    next_step_at = case when p_patch ? 'next_step_at' then nullif(btrim(p_patch->>'next_step_at'), '')::timestamptz else next_step_at end,
    updated_at   = now()
   where id = p_id;
  if array_length(labels, 1) > 0 then
    insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
    values (ws, p_id, auth.uid(), 'edit', 'Güncellendi: ' || array_to_string(labels, ', '));
  end if;
end $$;

create or replace function public.set_customer_stage(p_id uuid, p_stage text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare old text; ws uuid := public.my_ws();
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_stage not in ('contacted','negotiating','won') then raise exception 'Geçersiz aşama: %', p_stage; end if;
  select stage into old from public.customers where id = p_id and workspace_id = ws for update;
  if not found then raise exception 'Müşteri bulunamadı'; end if;
  if old = p_stage then return; end if;
  update public.customers set stage = p_stage, stage_changed_at = now(), updated_at = now() where id = p_id;
  insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
  values (ws, p_id, auth.uid(), 'stage', public.stage_label(old) || ' → ' || public.stage_label(p_stage)
          || coalesce(E'\n' || nullif(btrim(p_note), ''), ''));
end $$;

create or replace function public.add_customer_note(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare ws uuid := public.my_ws();
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_body, ''))) = 0 or length(p_body) > 4000 then raise exception 'Not 1-4000 karakter olmalı'; end if;
  if not exists (select 1 from public.customers where id = p_id and workspace_id = ws) then raise exception 'Müşteri bulunamadı'; end if;
  insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body) values (ws, p_id, auth.uid(), 'note', btrim(p_body));
  update public.customers set updated_at = now() where id = p_id;
end $$;

-- Satış kalemi ekler; müşteri henüz "Satış tamamlandı"da değilse oraya geçer
create or replace function public.add_sale(p_customer uuid, p_product text, p_quantity int, p_amount numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare ws uuid := public.my_ws(); old text; sid uuid;
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_product, ''))) not between 1 and 120 then raise exception 'Ürün adı 1-120 karakter olmalı'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'Adet en az 1 olmalı'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Tutar 0 veya daha büyük olmalı'; end if;
  select stage into old from public.customers where id = p_customer and workspace_id = ws for update;
  if not found then raise exception 'Müşteri bulunamadı'; end if;
  insert into public.customer_sales (workspace_id, customer_id, product, quantity, amount, user_id)
  values (ws, p_customer, btrim(p_product), p_quantity, round(p_amount, 2), auth.uid()) returning id into sid;
  insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
  values (ws, p_customer, auth.uid(), 'sale', 'Satış: ' || p_quantity || ' × ' || btrim(p_product) || ' — '
          || replace(round(p_amount, 2)::text, '.', ',') || ' TL');
  if old <> 'won' then
    update public.customers set stage = 'won', stage_changed_at = now(), updated_at = now() where id = p_customer;
  else
    update public.customers set updated_at = now() where id = p_customer;
  end if;
  return sid;
end $$;

create or replace function public.delete_sale(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ws uuid := public.my_ws(); s public.customer_sales;
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  delete from public.customer_sales where id = p_id and workspace_id = ws returning * into s;
  if s.id is null then raise exception 'Satış kaydı bulunamadı'; end if;
  insert into public.customer_notes (workspace_id, customer_id, user_id, kind, body)
  values (ws, s.customer_id, auth.uid(), 'edit', 'Satış silindi: ' || s.quantity || ' × ' || s.product);
end $$;

-- Müşteri geçmişi: notlar + aşama değişiklikleri + satışlar, yazan kişinin adıyla (ad yoksa e-posta başı)
create or replace function public.customer_timeline(p_id uuid)
returns table (id uuid, kind text, body text, created_at timestamptz, author text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_perm('customers') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  return query
    select n.id, n.kind, n.body, n.created_at, coalesce(r.display_name, split_part(u.email::text, '@', 1), 'Ekip')
      from public.customer_notes n
      left join public.user_roles r on r.user_id = n.user_id
      left join auth.users u on u.id = n.user_id
     where n.customer_id = p_id and n.workspace_id = public.my_ws()
     order by n.created_at desc, n.id
     limit 300;
end $$;

-- ---------- Aylık rapor (Türkiye saati; alanın kendi verisi) ----------
-- p_month: ayın herhangi bir günü (boşsa bu ay)
create or replace function public.monthly_report(p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ws uuid := public.my_ws(); m0 timestamptz; m1 timestamptz; res jsonb;
begin
  if not public.has_perm('leads') or ws is null then raise exception 'Bu işlem için yetkiniz yok'; end if;
  m0 := date_trunc('month', coalesce(p_month, (now() at time zone 'Europe/Istanbul')::date)::timestamp) at time zone 'Europe/Istanbul';
  m1 := (date_trunc('month', coalesce(p_month, (now() at time zone 'Europe/Istanbul')::date)::timestamp) + interval '1 month') at time zone 'Europe/Istanbul';
  with c as (select * from public.calls where workspace_id = ws and called_at >= m0 and called_at < m1),
       s as (select * from public.customer_sales where workspace_id = ws and sold_at >= m0 and sold_at < m1)
  select jsonb_build_object(
    'month', to_char(m0 at time zone 'Europe/Istanbul', 'YYYY-MM'),
    'actions',     (select count(*) from c),
    'contacted',   (select count(distinct business_id) from c),
    'wa_sent',     (select count(*) from c where outcome = 'wa_sent'),
    'positive',    (select count(distinct business_id) from c where outcome in ('interested','callback','won')),
    'rejected',    (select count(distinct business_id) from c where outcome in ('rejected','do_not_contact')),
    'unreachable', (select count(distinct business_id) from c where outcome in ('no_answer','wrong_number','closed_business')),
    'won',         (select count(distinct business_id) from c where outcome = 'won'),
    'sales_count', (select count(*) from s),
    'sales_qty',   (select coalesce(sum(quantity), 0) from s),
    'sales_total', (select coalesce(sum(amount), 0) from s),
    'leads_found', (select coalesce(sum(saved), 0) from public.scan_history where workspace_id = ws and scanned_at >= m0 and scanned_at < m1),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'label', public.reason_label(reason), 'n', n) order by n desc)
                  from (select reason, count(*) as n from c where outcome in ('rejected','do_not_contact') group by reason) x), '[]'),
    'sectors', coalesce((select jsonb_agg(jsonb_build_object('sector', sector, 'contacted', contacted, 'positive', positive, 'won', won) order by contacted desc)
                  from (select b.sector, count(distinct c.business_id) as contacted,
                               count(distinct c.business_id) filter (where c.outcome in ('interested','callback','won')) as positive,
                               count(distinct c.business_id) filter (where c.outcome = 'won') as won
                          from c join public.businesses b on b.id = c.business_id group by b.sector order by 2 desc limit 15) x), '[]'),
    'people', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'actions', actions, 'positive', positive, 'won', won) order by actions desc)
                  from (select coalesce(r.display_name, split_part(u.email::text, '@', 1), 'Ekip') as name, count(*) as actions,
                               count(*) filter (where c.outcome in ('interested','callback','won')) as positive,
                               count(*) filter (where c.outcome = 'won') as won
                          from c left join public.user_roles r on r.user_id = c.user_id left join auth.users u on u.id = c.user_id
                         group by 1) x), '[]'),
    'products', coalesce((select jsonb_agg(jsonb_build_object('product', product, 'qty', qty, 'total', total) order by total desc)
                  from (select product, sum(quantity) as qty, sum(amount) as total from s group by product order by 3 desc limit 10) x), '[]')
  ) into res;
  return res;
end $$;

-- ---------- Yönetim paneli (yalnızca platform yöneticisi): kim, ne kadar kullandı ----------
-- Google çağrısı başına tahmini maliyet (USD, Text Search Enterprise). Fiyat değişirse burayı güncelleyin.
create or replace function public.google_cost_per_call() returns numeric language sql immutable as $$ select 0.035::numeric $$;

create or replace function public.admin_usage(p_month date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m0 timestamptz; m1 timestamptz; d date := coalesce(p_month, (now() at time zone 'Europe/Istanbul')::date); res jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Bu işlem için yetkiniz yok'; end if;
  m0 := date_trunc('month', d::timestamp) at time zone 'Europe/Istanbul';
  m1 := (date_trunc('month', d::timestamp) + interval '1 month') at time zone 'Europe/Istanbul';
  with sh as (select * from public.scan_history where scanned_at >= m0 and scanned_at < m1),
       c  as (select * from public.calls where called_at >= m0 and called_at < m1),
       s  as (select * from public.customer_sales where sold_at >= m0 and sold_at < m1)
  select jsonb_build_object(
    'month', to_char(m0 at time zone 'Europe/Istanbul', 'YYYY-MM'),
    'cost_per_call', public.google_cost_per_call(),
    'totals', jsonb_build_object(
      'api_calls',    (select coalesce(sum(api_calls), 0) from sh),
      'scans',        (select count(*) from sh),
      'leads',        (select coalesce(sum(saved), 0) from sh),
      'actions',      (select count(*) from c),
      'wa_sent',      (select count(*) from c where outcome = 'wa_sent'),
      'won',          (select count(*) from c where outcome = 'won'),
      'sales_total',  (select coalesce(sum(amount), 0) from s),
      'active_users', (select count(distinct x.uid) from (select user_id as uid from c union all select user_id from sh) x where x.uid is not null),
      'users',        (select count(*) from auth.users),
      'pending',      (select count(*) from auth.users u where not exists (select 1 from public.user_roles r where r.user_id = u.id))),
    'workspaces', coalesce((select jsonb_agg(to_jsonb(x) order by x.api_calls desc, x.actions desc, x.name) from (
        select w.id, w.name, w.is_platform, w.is_demo, w.lead_quota,
               (select count(*) from public.user_roles r where r.workspace_id = w.id) as members,
               (select coalesce(sum(api_calls), 0) from sh where sh.workspace_id = w.id) as api_calls,
               (select count(*) from sh where sh.workspace_id = w.id) as scans,
               (select coalesce(sum(saved), 0) from sh where sh.workspace_id = w.id) as leads,
               (select count(*) from c where c.workspace_id = w.id) as actions,
               (select count(*) from c where c.workspace_id = w.id and c.outcome in ('interested','callback','won')) as positive,
               (select count(*) from c where c.workspace_id = w.id and c.outcome = 'won') as won,
               (select coalesce(sum(amount), 0) from s where s.workspace_id = w.id) as sales_total,
               greatest((select max(scanned_at) from public.scan_history h where h.workspace_id = w.id),
                        (select max(called_at) from public.calls k where k.workspace_id = w.id)) as last_activity
          from public.workspaces w) x), '[]'),
    'users', coalesce((select jsonb_agg(to_jsonb(x) order by x.actions desc, x.api_calls desc, x.created_at desc) from (
        select u.id, u.email::text as email,
               coalesce(r.display_name, left(nullif(btrim(u.raw_user_meta_data->>'full_name'), ''), 80)) as name,
               left(nullif(btrim(u.raw_user_meta_data->>'company'), ''), 80) as company,
               w.name as workspace, coalesce(r.role, 'none') as role, u.created_at, u.last_sign_in_at,
               (select count(*) from c where c.user_id = u.id) as actions,
               (select count(*) from sh where sh.user_id = u.id) as scans,
               (select coalesce(sum(api_calls), 0) from sh where sh.user_id = u.id) as api_calls,
               (select coalesce(sum(saved), 0) from sh where sh.user_id = u.id) as leads,
               greatest((select max(called_at) from public.calls k where k.user_id = u.id),
                        (select max(scanned_at) from public.scan_history h where h.user_id = u.id)) as last_activity
          from auth.users u
          left join public.user_roles r on r.user_id = u.id
          left join public.workspaces w on w.id = r.workspace_id) x), '[]')
  ) into res;
  return res;
end $$;

-- Fonksiyon yetkileri: anon hiçbirini çağıramaz
revoke all on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz,text), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int), public.ingest_businesses(uuid,jsonb),
  public.my_access(), public.team_list(), public.set_user_role(uuid,text,text,uuid),
  public.create_customer(text,text,text,text,text), public.update_customer(uuid,jsonb),
  public.set_customer_stage(uuid,text,text), public.add_customer_note(uuid,text), public.customer_timeline(uuid),
  public.add_sale(uuid,text,int,numeric), public.delete_sale(uuid), public.scan_context(uuid), public.purge_stale_leads(),
  public.monthly_report(date), public.list_workspaces(), public.create_workspace(text,boolean,int), public.update_workspace(uuid,jsonb),
  public.admin_usage(date), public.google_cost_per_call(),
  public.has_perm(text), public.role_perms(text), public.stage_label(text), public.reason_label(text), public.my_ws(),
  public.is_platform_admin(), public.platform_ws(), public.ws_leads_this_month(uuid), public.tr_month_start(timestamptz)
  from public, anon, authenticated;
grant execute on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz,text), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int),
  public.my_access(), public.team_list(), public.set_user_role(uuid,text,text,uuid),
  public.create_customer(text,text,text,text,text), public.update_customer(uuid,jsonb),
  public.set_customer_stage(uuid,text,text), public.add_customer_note(uuid,text), public.customer_timeline(uuid),
  public.add_sale(uuid,text,int,numeric), public.delete_sale(uuid), public.monthly_report(date),
  public.list_workspaces(), public.create_workspace(text,boolean,int), public.update_workspace(uuid,jsonb),
  public.admin_usage(date), public.stage_label(text), public.reason_label(text), public.tr_month_start(timestamptz) to authenticated;
-- Politikalar ve görünümler bu fonksiyonları çağırdığı için giriş yapmış kullanıcıda çalışabilmeli
grant execute on function public.has_perm(text), public.role_perms(text), public.my_ws(), public.is_platform_admin() to authenticated;
grant execute on function public.ingest_businesses(uuid,jsonb), public.scan_context(uuid), public.purge_stale_leads() to service_role;

-- ---------- Raporlar (Türkiye saati; giriş yapan yetkili kullanıcı kendi alanını okur) ----------
--  donen = bir cevap alınan işlem (ilgilendi, sonra ara, satış, ret); ulasilamadi = açmadı / yanlış numara / kapanmış
drop view if exists public.rapor_gunluk, public.rapor_haftalik, public.rapor_bolge_sektor;
create view public.rapor_gunluk with (security_invoker = true) as
select (c.called_at at time zone 'Europe/Istanbul')::date as gun,
       count(*) as islem,
       count(*) filter (where c.outcome = 'wa_sent') as wa_gonderilen,
       count(*) filter (where c.outcome in ('interested','callback','won','rejected','do_not_contact')) as donen,
       count(*) filter (where c.outcome in ('interested','callback')) as ilgilenen,
       count(*) filter (where c.outcome = 'won') as satis,
       count(*) filter (where c.outcome in ('rejected','do_not_contact')) as red,
       count(*) filter (where c.outcome in ('no_answer','wrong_number','closed_business')) as ulasilamadi
  from public.calls c group by 1;
create view public.rapor_haftalik with (security_invoker = true) as
select date_trunc('week', c.called_at at time zone 'Europe/Istanbul')::date as hafta,
       count(*) as islem,
       count(*) filter (where c.outcome = 'wa_sent') as wa_gonderilen,
       count(*) filter (where c.outcome in ('interested','callback','won','rejected','do_not_contact')) as donen,
       count(*) filter (where c.outcome in ('interested','callback')) as ilgilenen,
       count(*) filter (where c.outcome = 'won') as satis,
       count(*) filter (where c.outcome in ('rejected','do_not_contact')) as red,
       count(*) filter (where c.outcome in ('no_answer','wrong_number','closed_business')) as ulasilamadi
  from public.calls c group by 1;
create view public.rapor_bolge_sektor with (security_invoker = true) as
select b.city, b.sector,
       count(distinct b.id) as islenen,
       count(distinct b.id) filter (where c.outcome = 'wa_sent') as wa,
       count(distinct b.id) filter (where c.outcome in ('interested','callback','won','rejected','do_not_contact')) as donen,
       count(distinct b.id) filter (where c.outcome = 'won') as satis
  from public.calls c join public.businesses b on b.id = c.business_id
 group by b.city, b.sector;
revoke all on public.rapor_gunluk, public.rapor_haftalik, public.rapor_bolge_sektor from anon;
grant select on public.rapor_gunluk, public.rapor_haftalik, public.rapor_bolge_sektor to authenticated;

revoke all on public.v_queue, public.v_customers from anon;
grant select on public.v_queue, public.v_customers to authenticated;

-- ---------- 30 gün kuralı: her gece otomatik (Supabase'de pg_cron açıksa) ----------
-- pg_cron kapalıysa da sorun yok: her taramada ayrıca çalışır ve eski kayıtlar listede zaten görünmez.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $c$select cron.schedule('vitrin-purge-stale-leads', '15 0 * * *', 'select public.purge_stale_leads()')$c$;
  end if;
exception when others then raise notice 'pg_cron zamanlaması kurulamadı: %', sqlerrm;
end $$;
