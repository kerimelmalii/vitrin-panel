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

-- ---------- Güvenlik: kayıt kapalı, tarayıcı sadece okur; yazma yalnızca fonksiyonlarla ----------
alter table public.businesses    enable row level security;
alter table public.calls         enable row level security;
alter table public.closed_regions enable row level security;
alter table public.scan_history  enable row level security;

drop policy if exists p_read on public.businesses;     create policy p_read on public.businesses     for select to authenticated using (true);
drop policy if exists p_read on public.calls;          create policy p_read on public.calls          for select to authenticated using (true);
drop policy if exists p_read on public.closed_regions; create policy p_read on public.closed_regions for select to authenticated using (true);
drop policy if exists p_read on public.scan_history;   create policy p_read on public.scan_history   for select to authenticated using (true);

revoke all on public.businesses, public.calls, public.closed_regions, public.scan_history from anon, authenticated;
grant select on public.businesses, public.calls, public.closed_regions, public.scan_history to authenticated;

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

create or replace function public.next_business(p_list text, p_city text default null,
                                                p_sector text default null, p_skip uuid[] default '{}')
returns setof public.businesses
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); v public.businesses; cand uuid; tries int := 0;
begin
  if uid is null then raise exception 'Giriş gerekli'; end if;
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
   where id = p_business_id and claimed_by = auth.uid();
$$;

create or replace function public.move_to_call_list(p_business_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Giriş gerekli'; end if;
  update public.businesses set call_list = true, updated_at = now()
   where id = p_business_id and status = 'new';
end $$;

create or replace function public.log_call(p_business_id uuid, p_outcome text,
                                           p_note text default null, p_callback_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare b public.businesses; new_status text; next_at timestamptz; na int;
begin
  if auth.uid() is null then raise exception 'Giriş gerekli'; end if;
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

-- Fonksiyon yetkileri: anon hiçbirini çağıramaz
revoke all on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int), public.ingest_businesses(jsonb)
  from public, anon, authenticated;
grant execute on function public.next_business(text,text,text,uuid[]), public.release_business(uuid),
  public.move_to_call_list(uuid), public.log_call(uuid,text,text,timestamptz), public.list_counts(text,text),
  public.filter_options(), public.stats(), public.search_history(text,int) to authenticated;
grant execute on function public.ingest_businesses(jsonb) to service_role;
revoke all on public.v_queue from anon;
grant select on public.v_queue to authenticated;
