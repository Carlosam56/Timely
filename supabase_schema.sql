-- Timely Supabase schema
-- Run this in the Supabase SQL editor before using the app.

create extension if not exists pgcrypto;

create table if not exists public.schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  webuntis_school text,
  created_at timestamptz not null default now(),
  unique (webuntis_school)
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  full_name text not null,
  school_id uuid references public.schools(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (
    username = lower(username)
    and username ~ '^[a-z0-9_]{3,24}$'
  )
);

create unique index if not exists profiles_username_unique
  on public.profiles (username);

create index if not exists profiles_search_index
  on public.profiles (username, full_name);

create table if not exists public.webuntis_connections (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  webuntis_school text not null,
  webuntis_username text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$
begin
  if not exists (
    select 1 from pg_type where typname = 'friend_request_status'
  ) then
    create type public.friend_request_status as enum (
      'pending',
      'accepted',
      'declined',
      'cancelled',
      'removed'
    );
  end if;
end $$;

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status public.friend_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  responded_at timestamptz,
  user_low_id uuid generated always as (
    least(requester_id, addressee_id)
  ) stored,
  user_high_id uuid generated always as (
    greatest(requester_id, addressee_id)
  ) stored,
  constraint friend_requests_no_self_request check (requester_id <> addressee_id)
);

create unique index if not exists friend_requests_one_active_relationship
  on public.friend_requests (user_low_id, user_high_id)
  where status in ('pending', 'accepted');

create index if not exists friend_requests_requester_index
  on public.friend_requests (requester_id, status);

create index if not exists friend_requests_addressee_index
  on public.friend_requests (addressee_id, status);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.prevent_friend_participant_changes()
returns trigger
language plpgsql
as $$
begin
  if new.requester_id <> old.requester_id
    or new.addressee_id <> old.addressee_id then
    raise exception 'Friend request participants cannot be changed.';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists friend_requests_set_updated_at on public.friend_requests;
create trigger friend_requests_set_updated_at
before update on public.friend_requests
for each row execute function public.set_updated_at();

drop trigger if exists friend_requests_prevent_participant_changes on public.friend_requests;
create trigger friend_requests_prevent_participant_changes
before update on public.friend_requests
for each row execute function public.prevent_friend_participant_changes();

drop trigger if exists webuntis_connections_set_updated_at on public.webuntis_connections;
create trigger webuntis_connections_set_updated_at
before update on public.webuntis_connections
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  wanted_username text;
  base_username text;
  wanted_full_name text;
  suffix integer := 0;
begin
  base_username := lower(
    regexp_replace(
      coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
      '[^a-zA-Z0-9_]',
      '_',
      'g'
    )
  );

  if length(base_username) < 3 then
    base_username := base_username || substr(replace(new.id::text, '-', ''), 1, 3);
  end if;

  base_username := substr(base_username, 1, 24);
  wanted_username := base_username;
  wanted_full_name := coalesce(new.raw_user_meta_data->>'full_name', wanted_username);

  while exists (
    select 1 from public.profiles where username = wanted_username
  ) loop
    suffix := suffix + 1;
    wanted_username := substr(base_username, 1, 24 - length(suffix::text) - 1)
      || '_' || suffix::text;
  end loop;

  insert into public.profiles (id, username, full_name)
  values (new.id, wanted_username, wanted_full_name)
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.search_profiles(search_text text)
returns table (
  id uuid,
  username text,
  full_name text,
  school_id uuid
)
language sql
security invoker
stable
as $$
  select p.id, p.username, p.full_name, p.school_id
  from public.profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and length(trim(search_text)) >= 2
    and (
      p.username ilike '%' || trim(search_text) || '%'
      or p.full_name ilike '%' || trim(search_text) || '%'
    )
  order by
    case
      when p.username ilike trim(search_text) || '%' then 0
      else 1
    end,
    p.username
  limit 20;
$$;

alter table public.schools enable row level security;
alter table public.profiles enable row level security;
alter table public.webuntis_connections enable row level security;
alter table public.friend_requests enable row level security;

drop policy if exists "Authenticated users can read schools" on public.schools;
create policy "Authenticated users can read schools"
on public.schools
for select
to authenticated
using (true);

drop policy if exists "Authenticated users can search public profile fields" on public.profiles;
create policy "Authenticated users can search public profile fields"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists "Users can insert their own profile" on public.profiles;
create policy "Users can insert their own profile"
on public.profiles
for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "Users can read their own WebUntis connection" on public.webuntis_connections;
create policy "Users can read their own WebUntis connection"
on public.webuntis_connections
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "Users can insert their own WebUntis connection" on public.webuntis_connections;
create policy "Users can insert their own WebUntis connection"
on public.webuntis_connections
for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "Users can update their own WebUntis connection" on public.webuntis_connections;
create policy "Users can update their own WebUntis connection"
on public.webuntis_connections
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "Users can read their own friend request rows" on public.friend_requests;
create policy "Users can read their own friend request rows"
on public.friend_requests
for select
to authenticated
using (
  requester_id = auth.uid()
  or addressee_id = auth.uid()
);

drop policy if exists "Users can send friend requests" on public.friend_requests;
create policy "Users can send friend requests"
on public.friend_requests
for insert
to authenticated
with check (
  requester_id = auth.uid()
  and addressee_id <> auth.uid()
  and status = 'pending'
);

drop policy if exists "Request addressees can accept pending requests" on public.friend_requests;
create policy "Request addressees can accept pending requests"
on public.friend_requests
for update
to authenticated
using (
  addressee_id = auth.uid()
  and status = 'pending'
)
with check (
  addressee_id = auth.uid()
  and status in ('accepted', 'declined')
);

drop policy if exists "Request senders can cancel pending requests" on public.friend_requests;
create policy "Request senders can cancel pending requests"
on public.friend_requests
for update
to authenticated
using (
  requester_id = auth.uid()
  and status = 'pending'
)
with check (
  requester_id = auth.uid()
  and status = 'cancelled'
);

drop policy if exists "Friends can remove accepted friendships" on public.friend_requests;
create policy "Friends can remove accepted friendships"
on public.friend_requests
for update
to authenticated
using (
  status = 'accepted'
  and (
    requester_id = auth.uid()
    or addressee_id = auth.uid()
  )
)
with check (
  status = 'removed'
  and (
    requester_id = auth.uid()
    or addressee_id = auth.uid()
  )
);

grant usage on schema public to anon, authenticated;
grant select on public.schools to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.webuntis_connections to authenticated;
grant select, insert, update on public.friend_requests to authenticated;
grant execute on function public.search_profiles(text) to authenticated;
