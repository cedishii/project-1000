-- Project: 1000 archive in the cloud: the same journeys, items, memories,
-- photos, profile and settings as the phone's SQLite database
-- (lib/data/database.dart), owned per account.
--
-- Ownership: every row carries user_id. Child rows reference their parent
-- by (id, user_id), so a row can never be attached to another account's
-- journey, item or memory, even by the API functions.
--
-- Access: users can only ever SELECT their own rows, and only while their
-- membership is active. Journeys, items, memories and photos are changed
-- only through the functions in 20261012000300_archive_api.sql, which hold
-- the app's rules (numbering, 1,000 limit, read-only archived journeys).
-- The profile and settings are plain per-user rows written directly.
--
-- Sync: each account has a change counter. Every insert/update stamps the
-- row with the next value (`revision`) and every delete leaves a tombstone,
-- so a client can ask for "everything changed since revision N".

-- ------------------------------------------------------------ sync helpers

create table private.revisions (
  user_id uuid primary key,
  value   bigint not null
);

create table private.deletions (
  user_id    uuid not null,
  table_name text not null,
  record_id  text not null,
  revision   bigint not null,
  deleted_at timestamptz not null default now()
);
create index deletions_user_revision on private.deletions (user_id, revision);

alter table private.revisions enable row level security;
alter table private.deletions enable row level security;

-- Next change number for an account. The row lock serialises an
-- account's writes, so revisions become visible in increasing order and
-- "changes since N" never misses a commit.
create function private.next_revision(p_user uuid) returns bigint
language sql volatile security definer set search_path = '' as $$
  insert into private.revisions as r (user_id, value) values (p_user, 1)
  on conflict (user_id) do update set value = r.value + 1
  returning value
$$;

create function private.stamp_revision() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.user_id is distinct from old.user_id then
    raise exception using errcode = 'PT403', message = 'owner_change_forbidden';
  end if;
  new.revision := private.next_revision(new.user_id);
  return new;
end $$;

create function private.record_deletion() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.deletions (user_id, table_name, record_id, revision)
  values (
    old.user_id,
    tg_table_name,
    -- id for most tables, key for settings, user_id for profiles.
    coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'key', old.user_id::text),
    private.next_revision(old.user_id)
  );
  return old;
end $$;

-- Hashtags as the app stores them: no '#', no spaces, 1–100 characters.
create function private.valid_hashtags(tags text[]) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(cardinality(tags), 0) <= 100
     and not exists (
       select 1 from unnest(tags) t
       where t is null or char_length(t) not between 1 and 100
          or t ~ '[[:space:]#,]'
     )
$$;

-- --------------------------------------------------------------- journeys

create table public.journeys (
  id           uuid primary key,
  user_id      uuid not null default auth.uid()
               references auth.users (id) on delete cascade,
  number       int not null check (number >= 1),
  status       text not null check (status in ('active', 'archived')),
  started_on   date,
  completed_on date,
  -- The profile as it was when the journey was archived (Profile.toJson).
  snapshot     jsonb check (snapshot is null or jsonb_typeof(snapshot) = 'object'),
  created_at   timestamptz not null default now(),
  archived_at  timestamptz,
  revision     bigint not null default 0,
  unique (user_id, number),
  unique (id, user_id)
);
-- At most one active journey per account.
create unique index journeys_one_active on public.journeys (user_id)
  where status = 'active';

-- ------------------------------------------------------------------ items

create table public.items (
  id           uuid primary key,
  user_id      uuid not null default auth.uid(),
  journey_id   uuid not null,
  number       int not null check (number between 1 and 1000),
  position     int not null check (position >= 0),
  title        text not null check (char_length(title) <= 500),
  description  text not null default '' check (char_length(description) <= 10000),
  is_completed boolean not null default false,
  -- Kept when an item is un-completed (history is never silently lost).
  completed_on date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  revision     bigint not null default 0,
  foreign key (journey_id, user_id)
    references public.journeys (id, user_id) on delete cascade,
  unique (journey_id, number),
  unique (id, user_id)
);
create index items_journey_position on public.items (journey_id, position);
create index items_user on public.items (user_id);

-- --------------------------------------------------------------- memories

create table public.memories (
  id         uuid primary key,
  user_id    uuid not null default auth.uid(),
  item_id    uuid not null,
  position   int not null check (position >= 0),
  title      text not null default '' check (char_length(title) <= 500),
  body       text not null default '' check (char_length(body) <= 100000),
  date       date not null,
  location   text not null default '' check (char_length(location) <= 500),
  hashtags   text[] not null default '{}' check (private.valid_hashtags(hashtags)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revision   bigint not null default 0,
  foreign key (item_id, user_id)
    references public.items (id, user_id) on delete cascade,
  unique (id, user_id)
);
create index memories_item on public.memories (item_id, position);
create index memories_user on public.memories (user_id);
create index memories_hashtags on public.memories using gin (hashtags);

-- ----------------------------------------------------------------- photos

-- Metadata only; the files are in the private `photos` storage bucket at
-- <user_id>/<file> and <user_id>/<thumb>.
create table public.photos (
  id         uuid primary key,
  user_id    uuid not null default auth.uid(),
  memory_id  uuid not null,
  position   int not null check (position >= 0),
  file       text not null check (file ~ '^photos/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$'),
  thumb      text not null check (thumb ~ '^thumbs/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$'),
  width      int check (width > 0),
  height     int check (height > 0),
  created_at timestamptz not null default now(),
  revision   bigint not null default 0,
  foreign key (memory_id, user_id)
    references public.memories (id, user_id) on delete cascade
);
create index photos_memory on public.photos (memory_id, position);
create index photos_user on public.photos (user_id);

-- ---------------------------------------------------------------- profile

create table public.profiles (
  user_id    uuid primary key default auth.uid()
             references auth.users (id) on delete cascade,
  name       text not null default '' check (char_length(name) <= 500),
  nickname   text not null default '' check (char_length(nickname) <= 200),
  age        int check (age between 0 and 200),
  started_on date,
  bio        text not null default '' check (char_length(bio) <= 5000),
  photo      text check (photo ~ '^profile/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$'),
  updated_at timestamptz not null default now(),
  revision   bigint not null default 0
);

-- --------------------------------------------------------------- settings

create table public.settings (
  user_id  uuid not null default auth.uid()
           references auth.users (id) on delete cascade,
  key      text not null check (key ~ '^[a-z][a-z0-9_]{0,63}$'),
  value    text not null check (char_length(value) <= 1000),
  revision bigint not null default 0,
  primary key (user_id, key)
);

-- --------------------------------------------------------------- triggers

do $$
declare
  t text;
begin
  foreach t in array array['journeys', 'items', 'memories', 'photos', 'profiles', 'settings']
  loop
    execute format(
      'create trigger stamp_revision before insert or update on public.%I '
      'for each row execute function private.stamp_revision()', t);
    execute format(
      'create trigger record_deletion after delete on public.%I '
      'for each row execute function private.record_deletion()', t);
  end loop;
end $$;

-- --------------------------------------------------- row-level security

do $$
declare
  t text;
begin
  foreach t in array array['journeys', 'items', 'memories', 'photos', 'profiles', 'settings']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format(
      'create policy %I on public.%I for select to authenticated '
      'using (user_id = (select auth.uid()) and (select private.is_active_member()))',
      t || '_select_own', t);
  end loop;
end $$;

-- Journeys, items, memories and photos: only through the API functions.
revoke insert, update, delete, truncate
  on public.journeys, public.items, public.memories, public.photos
  from authenticated;

-- Profile and settings: each user writes their own rows directly.
revoke truncate on public.profiles, public.settings from authenticated;

create policy profiles_insert_own on public.profiles for insert to authenticated
  with check (user_id = (select auth.uid()) and (select private.is_active_member()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_member()))
  with check (user_id = (select auth.uid()));

create policy settings_insert_own on public.settings for insert to authenticated
  with check (user_id = (select auth.uid()) and (select private.is_active_member()));
create policy settings_update_own on public.settings for update to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_member()))
  with check (user_id = (select auth.uid()));
create policy settings_delete_own on public.settings for delete to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_member()));

-- `revision` is always overwritten by the stamp_revision trigger, so
-- clients can't choose it.

revoke execute on all functions in schema private from public;
grant execute on function private.is_active_member() to authenticated;
