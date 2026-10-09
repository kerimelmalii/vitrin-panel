-- =====================================================================
-- Vitrin Web – arama sistemi şeması (tek dosya, tekrar çalıştırılabilir)
-- Supabase > SQL Editor'e yapıştırıp Run. Mevcut tabloları silmez;
-- eksik tablo/sütun/fonksiyonları ekler, fonksiyonları günceller.
-- (WhatsApp / üç liste / kilitleme güncellemesini de kapsar:
--  ayrıca migration_whatsapp.sql çalıştırmaya gerek kalmaz.)
-- =====================================================================

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
  add column if not exists updated_at      timestamptz not null default now();

-- Cep numarası mı? (+905XXXXXXXXX) – WhatsApp listesi bununla ayrılır
do $$ begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='businesses' and column_name='is_mobile') then
    alter table public.businesses add column is_mobile boolean
      generated always as (coalesce(phone_normalized ~ '^\+905[0-9]{9}$', false)) stored;
  end if;
end $$;

-- Aynı işletme / aynı telefon iki kez eklenemez
create unique index if not exists businesses_place_id_uniq on public.businesses (place_id) where place_id is not null;
create unique index if not exists businesses_phone_uniq    on public.businesses (phone_normalized) where phone_normalized is not null;
create index if not exists businesses_queue_idx  on public.businesses (status, next_action_at);
create index if not exists businesses_filter_idx on public.businesses (city, sector);

alter table public.businesses drop constraint if exists businesses_status_chk;
alter table public.businesses add constraint businesses_status_chk check (status in
  ('new','wa_sent','no_answer','callback','interested','won','rejected','do_not_contact',
   'wrong_number','closed_business','unreachable')) not valid;
alter table public.businesses drop constraint if exists businesses_website_chk;
alter table public.businesses add constraint businesses_website_chk
  check (website_status in ('none','social_only')) not valid;

create table if not exists public.calls (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  outcome     text not null,
  note        text,
  callback_at timestamptz,
  called_at   timestamptz not null default now()
);
alter table public.calls add column if not exists user_id uuid;
alter table public.calls drop constraint if exists calls_outcome_chk;
alter table public.calls add constraint calls_outcome_chk check (outcome in
  ('wa_sent','no_answer','callback','interested','won','rejected','do_not_contact',
   'wrong_number','closed_business')) not valid;
create index if not exists calls_called_at_idx on public.calls (called_at desc);
create index if not exists calls_business_idx  on public.calls (business_id);

-- Taranmayacak bölgeler (district boşsa şehrin tamamı kapalı)
create table if not exists public.closed_regions (
  id         uuid primary key default gen_random_uuid(),
  city       text not null,
  district   text,
  reason     text,
  created_at timestamptz not null default now()
);
create unique index if not exists closed_regions_uniq
  on public.closed_regions (lower(city), lower(coalesce(district, '')));
insert into public.closed_regions (city, reason)
select 'Bursa', 'Kapalı bölge'
where not exists (select 1 from public.closed_regions where lower(city) = 'bursa' and district is null);

-- Tarama geçmişi (aynı bölge+sektör 90 gün tekrar taranmaz)
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
create index if not exists scan_history_lookup on public.scan_history (city, district, sector, scanned_at desc);

-- ---------- Roller ve yetkiler ----------
-- Kullanıcıyı Supabase > Authentication > Users'tan siz eklersiniz; rolünü panelde "Ekip" sekmesinden (yönetici) verirsiniz.
-- Rolü olmayan kullanıcı hiçbir veriyi göremez.
create table if not exists public.user_roles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  role         text not null check (role in ('admin','sales','designer')),
  display_name text,
  created_at   timestamptz not null default now()
);

-- Rol -> izin eşlemesi tek yerde. Yeni modül (örn. abonelikler) eklemek = buraya izin eklemek.
--   leads: satış listeleri/geçmiş · scan: bölge tarama · customers: müşteri panosunu görme · customers_write: aşama/not
--   team: ekip ve roller · subscriptions: (ileride) abonelik takibi
create or replace function public.role_perms(r text) returns text[]
language sql immutable as $$
  select case r
    when 'admin'    then array['leads','scan','customers','customers_write','team','subscriptions']
    when 'sales'    then array['leads','scan','customers','customers_write']
    when 'designer' then array['customers','customers_write']
    else array[]::text[] end
$$;

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p = any (public.role_perms((select ur.role from public.user_roles ur where ur.user_id = auth.uid()))), false)
$$;

-- Mevcut kullanıcılar kilitli kalmasın: rol tablosu boşsa en eski kullanıcı yönetici, diğerleri satış olur
insert into public.user_roles (user_id, role)
select u.id, case when row_number() over (order by u.created_at, u.id) = 1 then 'admin' else 'sales' end
  from auth.users u
 where not exists (select 1 from public.user_roles)
on conflict do nothing;

alter table public.user_roles enable row level security;
drop policy if exists p_own on public.user_roles;
create policy p_own on public.user_roles for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.user_roles from anon, authenticated;
grant select on public.user_roles to authenticated;

-- ---------- Müşteriler (satışı gerçekleşenler) ----------
create table if not exists public.customers (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid unique references public.businesses(id) on delete set null,
  name             text not null,
  phone            text,
  city             text,
  sector           text,
  stage            text not null default 'sale_done',
  amount           numeric(12,2),
  domain           text,
  next_step        text,
  next_step_at     timestamptz,
  stage_changed_at timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.customers drop constraint if exists customers_stage_chk;
alter table public.customers add constraint customers_stage_chk check (stage in
  ('sale_done','collecting','designing','client_review','live','paused','cancelled'));
alter table public.customers drop constraint if exists customers_amount_chk;
alter table public.customers add constraint customers_amount_chk check (amount is null or amount >= 0);
create index if not exists customers_stage_idx on public.customers (stage, stage_changed_at desc);

create table if not exists public.customer_notes (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  user_id     uuid,
  kind        text not null default 'note' check (kind in ('note','stage','created','edit')),
  body        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists customer_notes_idx on public.customer_notes (customer_id, created_at desc);

-- Satışı kaydedilmiş ama müşteri kaydı olmayanlar (eski veriler) için müşteri oluştur
insert into public.customers (business_id, name, phone, city, sector)
select b.id, b.name, coalesce(b.phone_raw, b.phone_normalized), nullif(b.city, ''), nullif(b.sector, '')
  from public.businesses b
 where b.status = 'won' and not exists (select 1 from public.customers c where c.business_id = b.id);

-- ---------- Güvenlik: kayıt kapalı, tarayıcı sadece okur; yazma yalnızca fonksiyonlarla ----------
alter table public.businesses    enable row level security;
alter table public.calls         enable row level security;
alter table public.closed_regions enable row level security;
alter table public.scan_history  enable row level security;

drop policy if exists p_read on public.businesses;      create policy p_read on public.businesses      for select to authenticated using ((select public.has_perm('leads')));
drop policy if exists p_read on public.calls;           create policy p_read on public.calls           for select to authenticated using ((select public.has_perm('leads')));
drop policy if exists p_read on public.closed_regions;  create policy p_read on public.closed_regions  for select to authenticated using ((select public.has_perm('scan')));
drop policy if exists p_read on public.scan_history;    create policy p_read on public.scan_history    for select to authenticated using ((select public.has_perm('scan')));
alter table public.customers      enable row level security;
alter table public.customer_notes enable row level security;
drop policy if exists p_read on public.customers;       create policy p_read on public.customers       for select to authenticated using ((select public.has_perm('customers')));
drop policy if exists p_read on public.customer_notes;  create policy p_read on public.customer_notes  for select to authenticated using ((select public.has_perm('customers')));

revoke all on public.businesses, public.calls, public.closed_regions, public.scan_history, public.customers, public.customer_notes from anon, authenticated;
grant select on public.businesses, public.calls, public.closed_regions, public.scan_history, public.customers, public.customer_notes to authenticated;

-- ---------- Liste mantığı (tek yerde) ----------
--  whatsapp : yeni + cep numarası + arama listesine alınmamış
--  call     : yeni + (sabit hat veya arama listesine alınmış), ya da açmayan (en çok 3 deneme) vadesi gelmiş
--  followup : vadesi gelen "sonra ara", WhatsApp'ı 3 gün önce gidenler, ilgilenenler
drop view if exists public.v_queue;
create view public.v_queue with (security_invoker = true) as
select b.*,
  case
    when b.status = 'callback'                 and b.next_action_at <= now() then 'followup'
    when b.status in ('wa_sent','interested')  and b.next_action_at <= now() then 'followup'
    when b.status = 'no_answer' and b.no_answer_count < 3 and b.next_action_at <= now() then 'call'
    when b.status = 'new' and (not b.is_mobile or b.call_list) then 'call'
    when b.status = 'new' then 'whatsapp'
  end as lst
from public.businesses b;

-- ---------- Fonksiyonlar (yalnızca giriş yapmış kullanıcı) ----------
-- Eski sürümlerden kalan farklı imzalı/dönüş tipli fonksiyonlar güncellemeyi engellemesin
drop function if exists public.next_business(text,text,text,uuid[]);
drop function if exists public.release_business(uuid);
drop function if exists public.move_to_call_list(uuid);
drop function if exists public.log_call(uuid,text,text,timestamptz);
drop function if exists public.list_counts(text,text);
drop function if exists public.filter_options();
drop function if exists public.stats();
drop function if exists public.search_history(text,int);
drop function if exists public.ingest_businesses(jsonb);
drop function if exists public.my_access();
drop function if exists public.team_list();
drop function if exists public.set_user_role(uuid,text,text);
drop function if exists public.create_customer(text,text,text,text,numeric,text);
drop function if exists public.update_customer(uuid,jsonb);
drop function if exists public.set_customer_stage(uuid,text,text);
drop function if exists public.add_customer_note(uuid,text);
drop function if exists public.user_can(uuid,text);
drop function if exists public.stage_label(text);
drop function if exists public.customer_timeline(uuid);

create or replace function public.next_business(p_list text, p_city text default null,
                                                p_sector text default null, p_skip uuid[] default '{}')
returns setof public.businesses
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); v public.businesses; cand uuid; tries int := 0;
begin
  if uid is null or not public.has_perm('leads') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_list not in ('whatsapp','call','followup') then raise exception 'Geçersiz liste'; end if;
  loop
    tries := tries + 1;
    -- Başkasının son 15 dk içinde açtığı kart atlanır; kendi açık kartım önce gelir
    select q.id into cand from public.v_queue q
     where q.lst = p_list
       and (p_city   is null or p_city   = '' or q.city   = p_city)
       and (p_sector is null or p_sector = '' or q.sector = p_sector)
       and (q.claimed_by is null or q.claimed_by = uid or q.claimed_at < now() - interval '15 minutes')
       and not (q.id = any (coalesce(p_skip, '{}')))
     order by (q.claimed_by = uid) desc nulls last,
              (q.status = 'callback') desc,
              q.next_action_at asc nulls last,
              q.lead_score desc, q.created_at asc
     limit 1;
    exit when cand is null;
    update public.businesses b set claimed_by = uid, claimed_at = now()
     where b.id = cand
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
   where id = p_business_id and claimed_by = auth.uid() and public.has_perm('leads');
$$;

create or replace function public.move_to_call_list(p_business_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('leads') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  update public.businesses set call_list = true, updated_at = now()
   where id = p_business_id and status = 'new';
end $$;

create or replace function public.log_call(p_business_id uuid, p_outcome text,
                                           p_note text default null, p_callback_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.businesses; new_status text; next_at timestamptz; na int; cid uuid;
begin
  if not public.has_perm('leads') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_outcome not in ('wa_sent','no_answer','callback','interested','won','rejected',
                       'do_not_contact','wrong_number','closed_business') then
    raise exception 'Geçersiz sonuç: %', p_outcome;
  end if;
  select * into b from public.businesses where id = p_business_id for update;
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

  insert into public.calls (business_id, outcome, note, callback_at, user_id)
  values (p_business_id, p_outcome, nullif(btrim(p_note), ''), p_callback_at, auth.uid());

  update public.businesses
     set status = new_status, next_action_at = next_at, no_answer_count = na,
         attempt_count = attempt_count + 1, claimed_by = null, claimed_at = null, updated_at = now()
   where id = p_business_id;

  -- Satış gerçekleştiyse müşteri panosuna otomatik düşer
  if p_outcome = 'won' then
    insert into public.customers (business_id, name, phone, city, sector)
    values (b.id, b.name, coalesce(b.phone_raw, b.phone_normalized), nullif(b.city, ''), nullif(b.sector, ''))
    on conflict (business_id) do nothing returning id into cid;
    if cid is not null then
      insert into public.customer_notes (customer_id, user_id, kind, body)
      values (cid, auth.uid(), 'created', 'Satış kaydedildi' || coalesce(E'\n' || nullif(btrim(p_note), ''), ''));
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

-- Hafta/gün sayaçları Türkiye saatine göre, ekibin toplamı
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
               business_id uuid, name text, phone_raw text, city text)
language sql stable security invoker set search_path = public as $$
  select c.called_at, c.outcome, c.note, c.callback_at, b.id, b.name, b.phone_raw, b.city
    from public.calls c join public.businesses b on b.id = c.business_id
   where coalesce(btrim(p_term), '') = ''
      or b.name ilike '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or c.note ilike '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
      or b.phone_raw like '%' || replace(replace(replace(btrim(p_term), '\', '\\'), '%', '\%'), '_', '\_') || '%'
   order by c.called_at desc
   limit least(coalesce(p_limit, 150), 500);
$$;

-- Tarama scripti (service_role) için toplu ekleme: yinelenen place_id/telefon sessizce atlanır
create or replace function public.ingest_businesses(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with ins as (
    insert into public.businesses (place_id, name, address, city, district, sector, phone_raw, phone_normalized,
                                   rating, review_count, website_status, maps_url, lead_score)
    select x.place_id, x.name, x.address, coalesce(x.city, ''), x.district, coalesce(x.sector, ''), x.phone_raw,
           x.phone_normalized, x.rating, x.review_count, coalesce(x.website_status, 'none'), x.maps_url,
           coalesce(x.lead_score, 0)
      from jsonb_to_recordset(p_rows) as x(place_id text, name text, address text, city text, district text,
             sector text, phone_raw text, phone_normalized text, rating numeric, review_count int,
             website_status text, maps_url text, lead_score int)
    on conflict do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;


-- ---------- Erişim, ekip ve müşteri fonksiyonları ----------
create or replace function public.my_access()
returns table (role text, perms text[], display_name text)
language sql stable security definer set search_path = public as $$
  select coalesce(u.role, 'none'), public.role_perms(u.role), u.display_name
    from (select auth.uid() as id) a left join public.user_roles u on u.user_id = a.id
   where a.id is not null;
$$;

create or replace function public.team_list()
returns table (user_id uuid, email text, display_name text, role text, last_sign_in_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_perm('team') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  return query
    select u.id, u.email::text, r.display_name, coalesce(r.role, 'none'), u.last_sign_in_at, u.created_at
      from auth.users u left join public.user_roles r on r.user_id = u.id
     order by u.created_at, u.id;
end $$;

create or replace function public.set_user_role(p_user uuid, p_role text, p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('team') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_role not in ('admin','sales','designer','none') then raise exception 'Geçersiz rol: %', p_role; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Kullanıcı bulunamadı'; end if;
  if p_role <> 'admin' and exists (select 1 from public.user_roles where user_id = p_user and role = 'admin')
     and (select count(*) from public.user_roles where role = 'admin') <= 1 then
    raise exception 'Son yönetici kaldırılamaz veya düşürülemez';
  end if;
  if p_role = 'none' then
    delete from public.user_roles where user_id = p_user;
  else
    insert into public.user_roles (user_id, role, display_name) values (p_user, p_role, nullif(btrim(p_name), ''))
    on conflict (user_id) do update set role = excluded.role,
      display_name = coalesce(nullif(btrim(p_name), ''), public.user_roles.display_name);
  end if;
end $$;

-- Tarama servisi (service_role) bir kullanıcının iznini sorar
create or replace function public.user_can(p_user uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_perm = any (public.role_perms((select role from public.user_roles where user_id = p_user))), false);
$$;

create or replace function public.stage_label(s text) returns text language sql immutable as $$
  select case s
    when 'sale_done' then 'Satış gerçekleşti' when 'collecting' then 'Bilgi toplanıyor'
    when 'designing' then 'Site tasarlanıyor' when 'client_review' then 'Müşteri onayında'
    when 'live' then 'Yayında' when 'paused' then 'Beklemede' when 'cancelled' then 'İptal' else s end
$$;

create or replace view public.v_customers with (security_invoker = true) as
select c.*, n.body as last_note, n.created_at as last_note_at
  from public.customers c
  left join lateral (select body, created_at from public.customer_notes
                      where customer_id = c.id and kind in ('note','stage')
                      order by created_at desc limit 1) n on true;

create or replace function public.create_customer(p_name text, p_phone text default null, p_city text default null,
    p_sector text default null, p_amount numeric default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 or length(p_name) > 120 then raise exception 'Müşteri adı 2-120 karakter olmalı'; end if;
  insert into public.customers (name, phone, city, sector, amount)
  values (btrim(p_name), nullif(btrim(p_phone), ''), nullif(btrim(p_city), ''), nullif(btrim(p_sector), ''), p_amount)
  returning id into cid;
  insert into public.customer_notes (customer_id, user_id, kind, body)
  values (cid, auth.uid(), 'created', coalesce(nullif(btrim(p_note), ''), 'Müşteri elle eklendi'));
  return cid;
end $$;

create or replace function public.update_customer(p_id uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare k text; labels text[] := '{}';
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if jsonb_typeof(p_patch) <> 'object' then raise exception 'Geçersiz istek'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('name','phone','city','sector','amount','domain','next_step','next_step_at') then
      raise exception 'Güncellenemeyen alan: %', k;
    end if;
    labels := labels || case k when 'name' then 'ad' when 'phone' then 'telefon' when 'city' then 'şehir' when 'sector' then 'sektör'
      when 'amount' then 'tutar' when 'domain' then 'alan adı' when 'next_step' then 'sıradaki adım' else 'adım tarihi' end;
  end loop;
  if p_patch ? 'name' and length(btrim(coalesce(p_patch->>'name', ''))) < 2 then raise exception 'Müşteri adı en az 2 karakter olmalı'; end if;
  perform 1 from public.customers where id = p_id for update;
  if not found then raise exception 'Müşteri bulunamadı'; end if;
  update public.customers set
    name         = case when p_patch ? 'name'         then btrim(p_patch->>'name') else name end,
    phone        = case when p_patch ? 'phone'        then nullif(btrim(p_patch->>'phone'), '') else phone end,
    city         = case when p_patch ? 'city'         then nullif(btrim(p_patch->>'city'), '') else city end,
    sector       = case when p_patch ? 'sector'       then nullif(btrim(p_patch->>'sector'), '') else sector end,
    amount       = case when p_patch ? 'amount'       then nullif(btrim(p_patch->>'amount'), '')::numeric else amount end,
    domain       = case when p_patch ? 'domain'       then nullif(btrim(p_patch->>'domain'), '') else domain end,
    next_step    = case when p_patch ? 'next_step'    then nullif(btrim(p_patch->>'next_step'), '') else next_step end,
    next_step_at = case when p_patch ? 'next_step_at' then nullif(btrim(p_patch->>'next_step_at'), '')::timestamptz else next_step_at end,
    updated_at   = now()
   where id = p_id;
  if array_length(labels, 1) > 0 then
    insert into public.customer_notes (customer_id, user_id, kind, body)
    values (p_id, auth.uid(), 'edit', 'Güncellendi: ' || array_to_string(labels, ', '));
  end if;
end $$;

create or replace function public.set_customer_stage(p_id uuid, p_stage text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare old text;
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if p_stage not in ('sale_done','collecting','designing','client_review','live','paused','cancelled') then
    raise exception 'Geçersiz aşama: %', p_stage;
  end if;
  select stage into old from public.customers where id = p_id for update;
  if not found then raise exception 'Müşteri bulunamadı'; end if;
  if old = p_stage then return; end if;
  update public.customers set stage = p_stage, stage_changed_at = now(), updated_at = now() where id = p_id;
  insert into public.customer_notes (customer_id, user_id, kind, body)
  values (p_id, auth.uid(), 'stage', public.stage_label(old) || ' → ' || public.stage_label(p_stage)
          || coalesce(E'\n' || nullif(btrim(p_note), ''), ''));
end $$;

create or replace function public.add_customer_note(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('customers_write') then raise exception 'Bu işlem için yetkiniz yok'; end if;
  if length(btrim(coalesce(p_body, ''))) = 0 or length(p_body) > 4000 then raise exception 'Not 1-4000 karakter olmalı'; end if;
  if not exists (select 1 from public.customers where id = p_id) then raise exception 'Müşteri bulunamadı'; end if;
  insert into public.customer_notes (customer_id, user_id, kind, body) values (p_id, auth.uid(), 'note', btrim(p_body));
  update public.customers set updated_at = now() where id = p_id;
end $$;

-- Müşteri geçmişi: notlar + aşama değişiklikleri, yazan kişinin adıyla (ad yoksa e-posta başı)
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
     where n.customer_id = p_id
     order by n.created_at desc, n.id
     limit 300;
end $$;

-- Fonksiyon yetkileri: anon hiçbirini çağıramaz
revoke all on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int), public.ingest_businesses(jsonb),
  public.my_access(), public.team_list(), public.set_user_role(uuid,text,text),
  public.create_customer(text,text,text,text,numeric,text), public.update_customer(uuid,jsonb),
  public.set_customer_stage(uuid,text,text), public.add_customer_note(uuid,text), public.user_can(uuid,text), public.customer_timeline(uuid),
  public.has_perm(text), public.role_perms(text), public.stage_label(text)
  from public, anon, authenticated;
grant execute on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int),
  public.my_access(), public.team_list(), public.set_user_role(uuid,text,text),
  public.create_customer(text,text,text,text,numeric,text), public.update_customer(uuid,jsonb),
  public.set_customer_stage(uuid,text,text), public.add_customer_note(uuid,text), public.stage_label(text), public.customer_timeline(uuid) to authenticated;
-- Politikalar ve görünümler bu iki fonksiyonu çağırdığı için giriş yapmış kullanıcıda çalışabilmeli
grant execute on function public.has_perm(text), public.role_perms(text) to authenticated;
grant execute on function public.ingest_businesses(jsonb), public.user_can(uuid,text) to service_role;
revoke all on public.v_queue, public.v_customers from anon;
grant select on public.v_queue, public.v_customers to authenticated;
