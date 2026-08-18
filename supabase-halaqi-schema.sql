-- Halaqi / حلاقي — Supabase schema v8.3.3.0
-- Run ONCE in Supabase Dashboard > SQL Editor > New query > Run.
-- Safe for the browser only because every exposed table below uses RLS.

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'customer' check (role in ('customer','barber','salon','developer')),
  display_name text not null default '',
  username text,
  phone text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists profiles_username_lower_uidx on public.profiles(lower(username)) where username is not null and username <> '';
create unique index if not exists profiles_phone_uidx on public.profiles(phone) where phone is not null and phone <> '';
drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create or replace function public.protect_profile_role()
returns trigger language plpgsql as $$
begin new.role := old.role; return new; end $$;
drop trigger if exists profiles_protect_role on public.profiles;
create trigger profiles_protect_role before update on public.profiles for each row execute function public.protect_profile_role();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_username text; v_phone text;
begin
  v_username := nullif(lower(trim(new.raw_user_meta_data->>'username')), '');
  v_phone := nullif(trim(new.raw_user_meta_data->>'phone'), '');
  insert into public.profiles(id,role,display_name,username,phone)
  values(
    new.id,
    'customer',
    coalesce(nullif(new.raw_user_meta_data->>'display_name',''), nullif(new.raw_user_meta_data->>'name',''), ''),
    v_username,
    v_phone
  )
  on conflict(id) do update set
    display_name=excluded.display_name,
    username=coalesce(excluded.username,public.profiles.username),
    phone=coalesce(excluded.phone,public.profiles.phone),
    updated_at=now();
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of raw_user_meta_data on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_username_available(p_username text)
returns boolean language sql stable security definer set search_path=public as $$
  select not exists(select 1 from public.profiles where lower(username)=lower(trim(p_username)));
$$;
create or replace function public.is_phone_available(p_phone text)
returns boolean language sql stable security definer set search_path=public as $$
  select not exists(select 1 from public.profiles where phone=trim(p_phone));
$$;

create table if not exists public.salons (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  owner_user_id uuid references auth.users(id) on delete set null,
  username text,
  name text not null,
  owner_name text,
  bio text not null default '',
  phone text,
  rating numeric(3,2) not null default 0,
  status text not null default 'offline' check (status in ('online','busy','full','offline')),
  lat double precision,
  lng double precision,
  gallery jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists salons_username_lower_uidx on public.salons(lower(username)) where username is not null and username<>'';
drop trigger if exists salons_set_updated_at on public.salons;
create trigger salons_set_updated_at before update on public.salons for each row execute function public.set_updated_at();

create table if not exists public.barbers (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  auth_user_id uuid references auth.users(id) on delete set null,
  salon_id uuid references public.salons(id) on delete set null,
  username text,
  display_name text not null,
  phone text,
  years integer not null default 0,
  rating numeric(3,2) not null default 0,
  level text not null default '',
  status text not null default 'offline' check (status in ('online','busy','full','offline')),
  smoking boolean not null default false,
  lat double precision,
  lng double precision,
  featured_until timestamptz,
  event_price numeric(12,2) not null default 0,
  event_bio text not null default '',
  home_price numeric(12,2) not null default 0,
  horizon integer not null default 7,
  schedule jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists barbers_username_lower_uidx on public.barbers(lower(username)) where username is not null and username<>'';
create index if not exists barbers_salon_idx on public.barbers(salon_id);
create index if not exists barbers_auth_user_idx on public.barbers(auth_user_id);
drop trigger if exists barbers_set_updated_at on public.barbers;
create trigger barbers_set_updated_at before update on public.barbers for each row execute function public.set_updated_at();

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text,
  price numeric(12,2) not null default 0,
  duration_minutes integer not null default 30,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  client_ref text unique,
  customer_id uuid not null references auth.users(id) on delete cascade,
  barber_id uuid not null references public.barbers(id) on delete restrict,
  salon_id uuid references public.salons(id) on delete set null,
  booking_day date not null,
  booking_time time not null,
  status text not null default 'confirmed' check (status in ('pending','confirmed','completed','cancelled')),
  total numeric(12,2) not null default 0,
  style text not null default '',
  hair_length text not null default '',
  texture text not null default '',
  beard text not null default '',
  reference_url text,
  service_codes text[] not null default '{}',
  group_ref text,
  group_parallel boolean not null default false,
  group_size integer not null default 1,
  group_total numeric(12,2) not null default 0,
  person_index integer not null default 0,
  person_name text not null default '',
  duration_minutes integer,
  end_time time,
  people jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bookings_customer_idx on public.bookings(customer_id,created_at desc);
create index if not exists bookings_barber_slot_idx on public.bookings(barber_id,booking_day,booking_time);
create index if not exists bookings_salon_idx on public.bookings(salon_id,booking_day);
drop trigger if exists bookings_set_updated_at on public.bookings;
create trigger bookings_set_updated_at before update on public.bookings for each row execute function public.set_updated_at();

-- RLS
alter table public.profiles enable row level security;
alter table public.salons enable row level security;
alter table public.barbers enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;

-- Re-runnable policies
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
drop policy if exists "salons_public_read" on public.salons;
drop policy if exists "salons_owner_insert" on public.salons;
drop policy if exists "salons_owner_update" on public.salons;
drop policy if exists "salons_owner_delete" on public.salons;
drop policy if exists "barbers_public_read" on public.barbers;
drop policy if exists "barbers_self_insert" on public.barbers;
drop policy if exists "barbers_self_update" on public.barbers;
drop policy if exists "barbers_self_delete" on public.barbers;
drop policy if exists "services_public_read" on public.services;
drop policy if exists "bookings_read_participants" on public.bookings;
drop policy if exists "bookings_customer_insert" on public.bookings;
drop policy if exists "bookings_participant_update" on public.bookings;
drop policy if exists "bookings_customer_delete" on public.bookings;

create policy "profiles_select_own" on public.profiles for select to authenticated using ((select auth.uid())=id);
create policy "profiles_insert_own" on public.profiles for insert to authenticated with check ((select auth.uid())=id);
create policy "profiles_update_own" on public.profiles for update to authenticated using ((select auth.uid())=id) with check ((select auth.uid())=id);

create policy "salons_public_read" on public.salons for select to anon,authenticated using (true);
create policy "salons_owner_insert" on public.salons for insert to authenticated with check ((select auth.uid())=owner_user_id);
create policy "salons_owner_update" on public.salons for update to authenticated using ((select auth.uid())=owner_user_id) with check ((select auth.uid())=owner_user_id);
create policy "salons_owner_delete" on public.salons for delete to authenticated using ((select auth.uid())=owner_user_id);

create policy "barbers_public_read" on public.barbers for select to anon,authenticated using (true);
create policy "barbers_self_insert" on public.barbers for insert to authenticated with check ((select auth.uid())=auth_user_id);
create policy "barbers_self_update" on public.barbers for update to authenticated using ((select auth.uid())=auth_user_id) with check ((select auth.uid())=auth_user_id);
create policy "barbers_self_delete" on public.barbers for delete to authenticated using ((select auth.uid())=auth_user_id);

create policy "services_public_read" on public.services for select to anon,authenticated using (active=true);

create policy "bookings_read_participants" on public.bookings for select to authenticated using (
  (select auth.uid())=customer_id
  or exists(select 1 from public.barbers b where b.id=bookings.barber_id and b.auth_user_id=(select auth.uid()))
  or exists(select 1 from public.salons s where s.id=bookings.salon_id and s.owner_user_id=(select auth.uid()))
);
create policy "bookings_customer_insert" on public.bookings for insert to authenticated with check ((select auth.uid())=customer_id);
create policy "bookings_participant_update" on public.bookings for update to authenticated using (
  (select auth.uid())=customer_id
  or exists(select 1 from public.barbers b where b.id=bookings.barber_id and b.auth_user_id=(select auth.uid()))
  or exists(select 1 from public.salons s where s.id=bookings.salon_id and s.owner_user_id=(select auth.uid()))
) with check (
  (select auth.uid())=customer_id
  or exists(select 1 from public.barbers b where b.id=bookings.barber_id and b.auth_user_id=(select auth.uid()))
  or exists(select 1 from public.salons s where s.id=bookings.salon_id and s.owner_user_id=(select auth.uid()))
);
create policy "bookings_customer_delete" on public.bookings for delete to authenticated using ((select auth.uid())=customer_id);

grant usage on schema public to anon, authenticated;
grant select on public.salons, public.barbers, public.services to anon, authenticated;
grant select,insert,update on public.profiles to authenticated;
grant insert,update,delete on public.salons,public.barbers to authenticated;
grant select,insert,update,delete on public.bookings to authenticated;
grant execute on function public.is_username_available(text) to anon,authenticated;
grant execute on function public.is_phone_available(text) to anon,authenticated;

-- Seed Halaqi's current catalog. Real locations can remain NULL until set by GPS.
insert into public.salons(legacy_id,username,name,owner_name,bio,rating,status,lat,lng)
values
 ('s1',null,'صالون الملك','أحمد سالم','صالون رجالي متكامل في المنصور.',4.8,'online',33.315,44.354),
 ('s2',null,'صالون النخبة','مهند قاسم','صالون رجالي حديث في اليرموك.',4.7,'online',33.301,44.367),
 ('s_delusso','1','صالون دي لوسو','حسين الجوزي','صالون دي لوسو على حلاقي.',0,'offline',null,null)
on conflict(legacy_id) do update set name=excluded.name,username=coalesce(excluded.username,public.salons.username),owner_name=excluded.owner_name,bio=excluded.bio,rating=excluded.rating,status=excluded.status;

insert into public.barbers(legacy_id,username,display_name,phone,salon_id,years,rating,level,status,smoking,lat,lng,event_price,event_bio,home_price,horizon)
values
 ('b1',null,'علي حسين','07700000011',(select id from public.salons where legacy_id='s1'),9,4.9,'ذهبي','online',false,33.314,44.356,35000,'تنظيف بشرة، أدوات استخدام مرة واحدة، تصفيف كامل ولمسات نهائية للمناسبة.',25000,7),
 ('b2',null,'مصطفى كريم','07700000022',null,6,4.8,'موثق','busy',true,33.302,44.369,30000,'قص وتصفيف مناسب للمناسبات مع ترتيب اللحية.',22000,5),
 ('b3',null,'سيف مهدي','07700000044',null,4,4.7,'موثق','online',false,33.325,44.341,28000,'تجهيز كامل للمناسبة.',20000,7),
 ('b_hussein313','313','حسين الجوزي','',(select id from public.salons where legacy_id='s_delusso'),0,0,'حساب مؤسس','offline',false,null,null,0,'',0,7)
on conflict(legacy_id) do update set display_name=excluded.display_name,username=coalesce(excluded.username,public.barbers.username),phone=excluded.phone,salon_id=excluded.salon_id,years=excluded.years,rating=excluded.rating,level=excluded.level,status=excluded.status,smoking=excluded.smoking;

insert into public.services(code,name_ar,name_en,price,duration_minutes) values
 ('hair','حلاقة شعر','Haircut',12000,30),
 ('beard','ترتيب لحية','Beard trim',8000,20),
 ('wash','غسل وتصفيف','Wash & style',5000,15),
 ('facial','تنظيف بشرة','Facial cleaning',10000,20),
 ('event','حلاقة مناسبات','Event grooming',0,60),
 ('home','حلاقة في منزلك','Home service',0,60)
on conflict(code) do update set name_ar=excluded.name_ar,name_en=excluded.name_en,price=excluded.price,duration_minutes=excluded.duration_minutes,active=true;
