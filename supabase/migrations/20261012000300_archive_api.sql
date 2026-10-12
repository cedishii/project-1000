-- Project: 1000 archive API: every change to journeys, items, memories and
-- photos goes through these functions (called with supabase.rpc(...) from
-- the phone and the web app alike), so the app's rules live in one place.
--
-- They follow lib/data/archive_repository.dart and lib/state/app_store.dart
-- exactly:
-- * a new item gets the lowest free number (#1–#1000) and goes to the end;
--   numbers never change, the order changes only through save_order;
-- * un-completing keeps the completion date;
-- * archived journeys are read-only;
-- * a journey can only be archived at 1,000 / 1,000, and archiving never
--   deletes anything.
-- EXP and levels are never stored: journey_progress derives them from the
-- completed count with the formula in lib/data/progression.dart, so a
-- repeated completion can never award EXP twice.
--
-- Safe to retry: records get their UUID from the client, so repeating a
-- request that already succeeded returns the existing record instead of
-- creating a duplicate. Updates can pass the revision the client last saw
-- (p_expected_revision); if the record changed since, the request fails
-- with HTTP 409 'stale_revision' instead of overwriting newer data.
--
-- Errors use PostgREST's PTxxx codes, so they arrive as HTTP statuses:
--   403 not_a_member · 404 not_found · 409 stale_revision, list_full,
--   journey_not_complete, invalid_order, id_conflict, cloud_has_other_data
--   · 422 invalid input.

-- ------------------------------------------------------------------ helpers

create function private.fail(p_status text, p_message text) returns void
language plpgsql volatile set search_path = '' as $$
begin
  raise exception using errcode = 'PT' || p_status, message = p_message;
end $$;

-- Dart's String.trim(): strips all leading/trailing whitespace.
create function private.trim_text(s text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(coalesce(s, ''), '^\s+|\s+$', '', 'g')
$$;

-- Starts a write: checks membership and serialises the account's writes,
-- so concurrent requests can't both take the same item number.
create function private.begin_write() returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 1000));
  return v_user;
end $$;

-- The account's active journey. An account with no journeys at all (a
-- new member) gets Journey 1, as a new phone does.
create function private.active_journey(p_user uuid) returns public.journeys
language plpgsql volatile security definer set search_path = '' as $$
declare
  j public.journeys;
begin
  select * into j from public.journeys where user_id = p_user and status = 'active';
  if found then
    return j;
  end if;
  if exists (select 1 from public.journeys where user_id = p_user) then
    raise exception 'Account % has journeys but none is active', p_user;
  end if;
  insert into public.journeys (id, user_id, number, status)
    values (gen_random_uuid(), p_user, 1, 'active')
    returning * into j;
  return j;
end $$;

-- An item of the caller's active journey, or 404.
create function private.active_item(p_user uuid, p_id uuid) returns public.items
language plpgsql stable security definer set search_path = '' as $$
declare
  v public.items;
begin
  select i.* into v from public.items i
    join public.journeys j on j.id = i.journey_id
    where i.id = p_id and i.user_id = p_user and j.status = 'active';
  if not found then
    perform private.fail('404', 'not_found');
  end if;
  return v;
end $$;

create function private.check_revision(p_expected bigint, p_actual bigint) returns void
language plpgsql volatile set search_path = '' as $$
begin
  if p_expected is not null and p_expected <> p_actual then
    perform private.fail('409', 'stale_revision');
  end if;
end $$;

create function private.check_title(p_title text) returns text
language plpgsql volatile set search_path = '' as $$
declare
  t text := private.trim_text(p_title);
begin
  if t = '' then
    perform private.fail('422', 'title_required');
  end if;
  return t;
end $$;

create function private.iso_date(d date) returns text
language sql immutable set search_path = '' as $$
  select to_char(d, 'YYYY-MM-DD')
$$;

-- UTC ISO-8601 with microseconds, as the phone writes timestamps.
create function private.iso_time(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

create function private.profile_is_empty(p public.profiles) returns boolean
language sql immutable set search_path = '' as $$
  select p.user_id is null or (
    p.name = '' and p.nickname = '' and p.age is null
    and p.started_on is null and p.bio = '' and p.photo is null)
$$;

-- -------------------------------------------------------------- progression

-- lib/data/progression.dart: 1,000 EXP per completed thing, a level every
-- 10,000 EXP (10 things), at most Level 100 (1,000 things).
create function public.progression(p_completed int)
returns table (
  completed int, exp int, level int, exp_into_level int,
  exp_to_next_level int, remaining int, is_complete boolean
)
language sql immutable set search_path = '' as $$
  with c as (select least(greatest(coalesce(p_completed, 0), 0), 1000) as n),
       e as (select n, n * 1000 as exp, least(n * 1000 / 10000, 100) as level from c)
  select n, exp, level,
    case when level >= 100 then 10000 else exp - level * 10000 end,
    case when level >= 100 then 0 else 10000 - (exp - level * 10000) end,
    1000 - n,
    n >= 1000
  from e
$$;

-- Each journey with its counts and progress (JourneySummary + Progression).
-- security_invoker: the caller's row-level security applies.
create view public.journey_progress with (security_invoker = true) as
select
  j.id as journey_id, j.user_id, j.number, j.status,
  j.started_on, j.completed_on,
  c.item_count, c.completed_count, c.memory_count, c.photo_count,
  p.exp, p.level, p.exp_into_level, p.exp_to_next_level, p.remaining,
  p.is_complete,
  round(c.completed_count * 100.0 / 1000, 1) as percent
from public.journeys j
cross join lateral (
  select
    (select count(*) from public.items i where i.journey_id = j.id)::int as item_count,
    (select count(*) from public.items i
       where i.journey_id = j.id and i.is_completed)::int as completed_count,
    (select count(*) from public.memories m join public.items i on i.id = m.item_id
       where i.journey_id = j.id)::int as memory_count,
    (select count(*) from public.photos ph join public.memories m on m.id = ph.memory_id
       join public.items i on i.id = m.item_id where i.journey_id = j.id)::int as photo_count
) c
cross join lateral public.progression(c.completed_count) p;

revoke all on public.journey_progress from anon;
revoke insert, update, delete, truncate on public.journey_progress from authenticated;
grant select on public.journey_progress to authenticated;

-- -------------------------------------------------------------------- items

-- ArchiveRepository.addItem. Retrying with the same p_id returns the item
-- created the first time.
create function public.add_item(p_id uuid, p_title text, p_description text default '')
returns public.items
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_item public.items;
  j public.journeys;
  v_number int;
  v_position int;
begin
  if p_id is null then
    perform private.fail('422', 'id_required');
  end if;
  select * into v_item from public.items where id = p_id;
  if found then
    if v_item.user_id <> v_user then
      perform private.fail('409', 'id_conflict');
    end if;
    return v_item;
  end if;

  j := private.active_journey(v_user);
  select min(n) into v_number from generate_series(1, 1000) n
    where not exists (
      select 1 from public.items i where i.journey_id = j.id and i.number = n);
  if v_number is null then
    perform private.fail('409', 'list_full');
  end if;
  select coalesce(max(position), -1) + 1 into v_position
    from public.items where journey_id = j.id;

  insert into public.items (id, user_id, journey_id, number, position, title, description)
    values (p_id, v_user, j.id, v_number, v_position,
            private.check_title(p_title), private.trim_text(p_description))
    returning * into v_item;
  return v_item;
end $$;

-- ArchiveRepository.updateItemText.
create function public.update_item(
  p_id uuid, p_title text, p_description text,
  p_expected_revision bigint default null
) returns public.items
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_item public.items := private.active_item(v_user, p_id);
begin
  perform private.check_revision(p_expected_revision, v_item.revision);
  update public.items
    set title = private.check_title(p_title),
        description = private.trim_text(p_description),
        updated_at = now()
    where id = p_id
    returning * into v_item;
  return v_item;
end $$;

-- ArchiveRepository.setCompleted. Sets a state rather than toggling, so
-- repeating it changes nothing. Pass the user's local date as p_on.
-- Un-completing keeps the old completion date on record.
create function public.set_item_completed(p_id uuid, p_completed boolean, p_on date default null)
returns public.items
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_item public.items := private.active_item(v_user, p_id);
  v_on date := coalesce(p_on, current_date);
begin
  if p_completed is null then
    perform private.fail('422', 'completed_required');
  end if;
  if v_item.is_completed = p_completed
     and (not p_completed or v_item.completed_on = v_on) then
    return v_item;
  end if;
  update public.items
    set is_completed = p_completed,
        completed_on = case when p_completed then v_on else completed_on end,
        updated_at = now()
    where id = p_id
    returning * into v_item;
  return v_item;
end $$;

-- ArchiveRepository.deleteItem: removes the item with its memories and
-- photo records. Returns the storage paths the client should now remove
-- ({"deleted": bool, "files": [...]}). Deleting again is harmless.
create function public.delete_item(p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_files jsonb;
begin
  if not exists (select 1 from public.items where id = p_id and user_id = v_user) then
    return jsonb_build_object('deleted', false, 'files', '[]'::jsonb);
  end if;
  perform private.active_item(v_user, p_id);
  select coalesce(jsonb_agg(f), '[]'::jsonb) into v_files from (
    select unnest(array[ph.file, ph.thumb]) as f
    from public.photos ph join public.memories m on m.id = ph.memory_id
    where m.item_id = p_id
  ) s;
  delete from public.items where id = p_id;
  return jsonb_build_object('deleted', true, 'files', v_files);
end $$;

-- ArchiveRepository.saveOrder: p_ids must be exactly the active
-- journey's items; otherwise nothing changes.
create function public.save_order(p_ids uuid[]) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  j public.journeys := private.active_journey(v_user);
begin
  if p_ids is null
     or cardinality(p_ids) <> (select count(*) from public.items where journey_id = j.id)
     or cardinality(p_ids) <> (select count(distinct x) from unnest(p_ids) x)
     or exists (
       select 1 from unnest(p_ids) x
       where not exists (select 1 from public.items i where i.id = x and i.journey_id = j.id))
  then
    perform private.fail('409', 'invalid_order');
  end if;
  update public.items i
    set position = o.ord - 1
    from unnest(p_ids) with ordinality as o(id, ord)
    where i.id = o.id and i.position <> o.ord - 1;
end $$;

-- ------------------------------------------------------------------ memories

-- ArchiveRepository.saveMemory. p_memory:
--   { "id": uuid (new memories too: generated by the client),
--     "itemId": uuid, "title", "text", "date": "YYYY-MM-DD", "location",
--     "hashtags": [..], "expectedRevision": optional,
--     "photos": [{ "id", "file", "thumb", "width", "height", "createdAt" }] }
-- Photo files must already be uploaded. Photos not in the list are
-- removed; returns { "memory": row, "removedFiles": [...] }.
create function public.save_memory(p_memory jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_id uuid := (p_memory ->> 'id')::uuid;
  v_item_id uuid := (p_memory ->> 'itemId')::uuid;
  v_existing public.memories;
  v_memory public.memories;
  v_tags text[];
  v_photos jsonb := coalesce(p_memory -> 'photos', '[]'::jsonb);
  v_removed jsonb;
begin
  if v_id is null or v_item_id is null or p_memory ->> 'date' is null then
    perform private.fail('422', 'invalid_memory');
  end if;
  if jsonb_typeof(v_photos) <> 'array'
     or jsonb_typeof(coalesce(p_memory -> 'hashtags', '[]'::jsonb)) <> 'array' then
    perform private.fail('422', 'invalid_memory');
  end if;
  perform private.active_item(v_user, v_item_id);
  v_tags := array(select jsonb_array_elements_text(coalesce(p_memory -> 'hashtags', '[]'::jsonb)));

  select * into v_existing from public.memories where id = v_id;
  if found then
    if v_existing.user_id <> v_user or v_existing.item_id <> v_item_id then
      perform private.fail('404', 'not_found');
    end if;
    perform private.check_revision((p_memory ->> 'expectedRevision')::bigint, v_existing.revision);
    update public.memories set
        title = private.trim_text(p_memory ->> 'title'),
        body = private.trim_text(p_memory ->> 'text'),
        date = (p_memory ->> 'date')::date,
        location = private.trim_text(p_memory ->> 'location'),
        hashtags = v_tags,
        updated_at = now()
      where id = v_id
      returning * into v_memory;
  else
    insert into public.memories (id, user_id, item_id, position, title, body, date, location, hashtags)
      values (
        v_id, v_user, v_item_id,
        (select coalesce(max(position), -1) + 1 from public.memories where item_id = v_item_id),
        private.trim_text(p_memory ->> 'title'),
        private.trim_text(p_memory ->> 'text'),
        (p_memory ->> 'date')::date,
        private.trim_text(p_memory ->> 'location'),
        v_tags)
      returning * into v_memory;
  end if;

  -- Photos: remove those no longer listed, re-position the rest, add new.
  select coalesce(jsonb_agg(f), '[]'::jsonb) into v_removed from (
    select unnest(array[ph.file, ph.thumb]) as f from public.photos ph
    where ph.memory_id = v_id
      and ph.id not in (select (e ->> 'id')::uuid from jsonb_array_elements(v_photos) e)
  ) s;
  delete from public.photos ph
    where ph.memory_id = v_id
      and ph.id not in (select (e ->> 'id')::uuid from jsonb_array_elements(v_photos) e);

  insert into public.photos as ph (id, user_id, memory_id, position, file, thumb, width, height, created_at)
    select (e ->> 'id')::uuid, v_user, v_id, (o - 1)::int, e ->> 'file', e ->> 'thumb',
           (e ->> 'width')::int, (e ->> 'height')::int,
           coalesce((e ->> 'createdAt')::timestamptz, now())
    from jsonb_array_elements(v_photos) with ordinality as x(e, o)
    on conflict (id) do update set position = excluded.position
      where ph.memory_id = v_id and ph.position <> excluded.position;
  -- A photo id that exists on another memory or account was not updated
  -- by the statement above; refuse rather than silently skip it.
  if exists (
    select 1 from jsonb_array_elements(v_photos) e
    join public.photos ph on ph.id = (e ->> 'id')::uuid
    where ph.memory_id <> v_id
  ) then
    perform private.fail('409', 'id_conflict');
  end if;

  update public.items set updated_at = now() where id = v_item_id;
  return jsonb_build_object('memory', to_jsonb(v_memory), 'removedFiles', v_removed);
end $$;

-- ArchiveRepository.deleteMemory. Returns {"deleted", "files"}.
create function public.delete_memory(p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_memory public.memories;
  v_files jsonb;
begin
  select * into v_memory from public.memories where id = p_id and user_id = v_user;
  if not found then
    return jsonb_build_object('deleted', false, 'files', '[]'::jsonb);
  end if;
  perform private.active_item(v_user, v_memory.item_id);
  select coalesce(jsonb_agg(f), '[]'::jsonb) into v_files from (
    select unnest(array[ph.file, ph.thumb]) as f from public.photos ph where ph.memory_id = p_id
  ) s;
  delete from public.memories where id = p_id;
  return jsonb_build_object('deleted', true, 'files', v_files);
end $$;

-- ------------------------------------------------------------------ journeys

-- AppStore.setJourneyStart: Journey 1's start is the profile's started
-- date; later journeys store their own.
create function public.set_journey_start(p_date date) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  j public.journeys := private.active_journey(v_user);
begin
  if j.number = 1 then
    insert into public.profiles (user_id, started_on) values (v_user, p_date)
      on conflict (user_id) do update
        set started_on = excluded.started_on, updated_at = now();
  else
    update public.journeys set started_on = p_date where id = j.id;
  end if;
end $$;

-- AppStore.startNewJourney + ArchiveRepository.archiveAndStartNew ("regress"):
-- archives the finished active journey (1,000 / 1,000) and begins the
-- next. Nothing is deleted. The profile as it is now is kept with the
-- archived journey; p_snapshot_photo is a copy of the profile picture the
-- client made in storage first (profile/<new id>.jpg), or null.
-- With p_reuse_list the new journey starts with the same numbers, titles,
-- descriptions and order, none completed, without memories.
-- Pass the finishing journey's id as p_finishing_journey to make a retry
-- of a request that already succeeded return the new journey.
create function public.start_new_journey(
  p_new_started_on date,
  p_reuse_list boolean,
  p_snapshot_photo text default null,
  p_finishing_journey uuid default null
) returns public.journeys
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  j public.journeys := private.active_journey(v_user);
  v_profile public.profiles;
  v_completed int;
  v_last date;
  v_snapshot jsonb;
  v_new public.journeys;
begin
  if p_new_started_on is null or p_reuse_list is null then
    perform private.fail('422', 'invalid_request');
  end if;
  if p_finishing_journey is not null and p_finishing_journey <> j.id then
    if exists (select 1 from public.journeys where id = p_finishing_journey
               and user_id = v_user and status = 'archived') then
      return j;
    end if;
    perform private.fail('404', 'not_found');
  end if;
  if p_snapshot_photo is not null
     and p_snapshot_photo !~ '^profile/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$' then
    perform private.fail('422', 'invalid_photo_path');
  end if;

  select count(*) filter (where is_completed),
         max(completed_on) filter (where is_completed)
    into v_completed, v_last
    from public.items where journey_id = j.id;
  if v_completed < 1000 then
    perform private.fail('409', 'journey_not_complete');
  end if;

  select * into v_profile from public.profiles where user_id = v_user;
  if not private.profile_is_empty(v_profile) then
    v_snapshot := jsonb_build_object(
      'name', v_profile.name, 'nickname', v_profile.nickname, 'age', v_profile.age,
      'startedOn', private.iso_date(v_profile.started_on), 'bio', v_profile.bio,
      'photo', p_snapshot_photo);
  end if;

  update public.journeys set
      status = 'archived',
      started_on = coalesce(started_on,
        case when j.number = 1 then v_profile.started_on end),
      completed_on = coalesce(v_last, current_date),
      snapshot = v_snapshot,
      archived_at = now()
    where id = j.id;

  insert into public.journeys (id, user_id, number, status, started_on)
    values (gen_random_uuid(), v_user,
            (select max(number) + 1 from public.journeys where user_id = v_user),
            'active', p_new_started_on)
    returning * into v_new;

  if p_reuse_list then
    insert into public.items (id, user_id, journey_id, number, position, title, description)
      select gen_random_uuid(), v_user, v_new.id, number, position, title, description
      from public.items where journey_id = j.id
      order by position, created_at, id;
  end if;
  return v_new;
end $$;

-- ------------------------------------------------------- export / import

-- The whole archive in the backup data.json format (version 2,
-- docs/BACKUP_FORMAT.md), in list order. Used to verify a migration, as
-- a cloud backup, and by a web client that wants everything at once.
create function public.export_archive() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  return jsonb_build_object(
    'dataFormatVersion', 2,
    'settings', coalesce((select jsonb_object_agg(s.key, s.value)
                          from public.settings s where s.user_id = v_user), '{}'::jsonb),
    'profile', (select jsonb_build_object(
        'name', p.name, 'nickname', p.nickname, 'age', p.age,
        'startedOn', private.iso_date(p.started_on), 'bio', p.bio,
        'photo', p.photo, 'updatedAt', private.iso_time(p.updated_at))
      from public.profiles p where p.user_id = v_user),
    'journeys', coalesce((select jsonb_agg(jsonb_build_object(
        'id', j.id, 'number', j.number, 'status', j.status,
        'startedOn', private.iso_date(j.started_on),
        'completedOn', private.iso_date(j.completed_on),
        'snapshot', j.snapshot,
        'createdAt', private.iso_time(j.created_at),
        'archivedAt', private.iso_time(j.archived_at),
        'items', coalesce((select jsonb_agg(jsonb_build_object(
            'id', i.id, 'number', i.number, 'position', i.position,
            'title', i.title, 'description', i.description,
            'isCompleted', i.is_completed,
            'completedOn', private.iso_date(i.completed_on),
            'createdAt', private.iso_time(i.created_at),
            'updatedAt', private.iso_time(i.updated_at),
            'memories', coalesce((select jsonb_agg(jsonb_build_object(
                'id', m.id, 'position', m.position, 'title', m.title,
                'text', m.body, 'date', private.iso_date(m.date),
                'location', m.location, 'hashtags', to_jsonb(m.hashtags),
                'createdAt', private.iso_time(m.created_at),
                'updatedAt', private.iso_time(m.updated_at),
                'photos', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', ph.id, 'position', ph.position, 'file', ph.file,
                    'thumb', ph.thumb, 'width', ph.width, 'height', ph.height,
                    'createdAt', private.iso_time(ph.created_at))
                  order by ph.position, ph.created_at, ph.id)
                  from public.photos ph where ph.memory_id = m.id), '[]'::jsonb))
              order by m.position, m.created_at, m.id)
              from public.memories m where m.item_id = i.id), '[]'::jsonb))
          order by i.position, i.created_at, i.id)
          from public.items i where i.journey_id = j.id), '[]'::jsonb))
      order by j.number)
      from public.journeys j where j.user_id = v_user), '[]'::jsonb)
  );
end $$;

-- Uploads a phone's archive (the backup data.json, version 2) into the
-- caller's account, keeping every id, number, position, date and text.
-- Runs in one transaction: all of it is stored or none of it.
--
-- Safe to repeat: when the account already holds exactly these journeys
-- (an earlier run), only missing records are added and nothing is
-- overwritten. It refuses ('cloud_has_other_data') when the account holds
-- different journeys, because merging two archives is not supported — the
-- same rule as importing a backup on the phone. An account that only has
-- the empty Journey 1 a new member starts with counts as empty.
-- An existing profile or setting is never overwritten.
create function public.import_archive(p_data jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_journeys jsonb := p_data -> 'journeys';
  v_payload_ids uuid[];
  v_server_ids uuid[];
  v_status text;
begin
  if (p_data ->> 'dataFormatVersion') is distinct from '2'
     or jsonb_typeof(v_journeys) is distinct from 'array' then
    perform private.fail('422', 'unsupported_format');
  end if;
  if (select count(*) from jsonb_array_elements(v_journeys) e
      where e ->> 'status' = 'active') <> 1 then
    perform private.fail('422', 'invalid_data');
  end if;

  -- Ids already used by another account (practically impossible with
  -- random UUIDs; checked so nothing is silently skipped).
  if exists (select 1 from public.journeys t
             where t.user_id <> v_user and t.id in (
               select (x #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].id') x))
     or exists (select 1 from public.items t
             where t.user_id <> v_user and t.id in (
               select (x #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].id') x))
     or exists (select 1 from public.memories t
             where t.user_id <> v_user and t.id in (
               select (x #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].memories[*].id') x))
     or exists (select 1 from public.photos t
             where t.user_id <> v_user and t.id in (
               select (x #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].memories[*].photos[*].id') x))
  then
    perform private.fail('409', 'id_conflict');
  end if;

  v_payload_ids := array(select (e ->> 'id')::uuid from jsonb_array_elements(v_journeys) e order by 1);
  v_server_ids := array(select id from public.journeys where user_id = v_user order by 1);

  if cardinality(v_server_ids) = 0 then
    v_status := 'imported';
  elsif v_server_ids = v_payload_ids then
    v_status := 'resumed';
  elsif cardinality(v_server_ids) = 1
        and not (v_server_ids[1] = any (v_payload_ids))
        and exists (select 1 from public.journeys j
                    where j.id = v_server_ids[1] and j.number = 1 and j.status = 'active')
        and not exists (select 1 from public.items where user_id = v_user) then
    delete from public.journeys where id = v_server_ids[1];
    v_status := 'imported';
  else
    perform private.fail('409', 'cloud_has_other_data');
  end if;

  insert into public.journeys (id, user_id, number, status, started_on, completed_on,
                               snapshot, created_at, archived_at)
    select (j ->> 'id')::uuid, v_user, (j ->> 'number')::int, j ->> 'status',
           (j ->> 'startedOn')::date, (j ->> 'completedOn')::date,
           case when jsonb_typeof(j -> 'snapshot') = 'object' then j -> 'snapshot' end,
           (j ->> 'createdAt')::timestamptz, (j ->> 'archivedAt')::timestamptz
    from jsonb_array_elements(v_journeys) j
    on conflict (id) do nothing;

  insert into public.items (id, user_id, journey_id, number, position, title, description,
                            is_completed, completed_on, created_at, updated_at)
    select (i ->> 'id')::uuid, v_user, (j ->> 'id')::uuid, (i ->> 'number')::int,
           (i ->> 'position')::int, i ->> 'title', coalesce(i ->> 'description', ''),
           coalesce((i ->> 'isCompleted')::boolean, false), (i ->> 'completedOn')::date,
           (i ->> 'createdAt')::timestamptz, (i ->> 'updatedAt')::timestamptz
    from jsonb_array_elements(v_journeys) j,
         jsonb_array_elements(coalesce(j -> 'items', '[]'::jsonb)) i
    on conflict (id) do nothing;

  insert into public.memories (id, user_id, item_id, position, title, body, date, location,
                               hashtags, created_at, updated_at)
    select (m ->> 'id')::uuid, v_user, (i ->> 'id')::uuid, (m ->> 'position')::int,
           coalesce(m ->> 'title', ''), coalesce(m ->> 'text', ''), (m ->> 'date')::date,
           coalesce(m ->> 'location', ''),
           array(select jsonb_array_elements_text(coalesce(m -> 'hashtags', '[]'::jsonb))),
           (m ->> 'createdAt')::timestamptz, (m ->> 'updatedAt')::timestamptz
    from jsonb_array_elements(v_journeys) j,
         jsonb_array_elements(coalesce(j -> 'items', '[]'::jsonb)) i,
         jsonb_array_elements(coalesce(i -> 'memories', '[]'::jsonb)) m
    on conflict (id) do nothing;

  insert into public.photos (id, user_id, memory_id, position, file, thumb, width, height, created_at)
    select (ph ->> 'id')::uuid, v_user, (m ->> 'id')::uuid, (ph ->> 'position')::int,
           ph ->> 'file', ph ->> 'thumb', (ph ->> 'width')::int, (ph ->> 'height')::int,
           (ph ->> 'createdAt')::timestamptz
    from jsonb_array_elements(v_journeys) j,
         jsonb_array_elements(coalesce(j -> 'items', '[]'::jsonb)) i,
         jsonb_array_elements(coalesce(i -> 'memories', '[]'::jsonb)) m,
         jsonb_array_elements(coalesce(m -> 'photos', '[]'::jsonb)) ph
    on conflict (id) do nothing;

  if jsonb_typeof(p_data -> 'profile') = 'object' then
    insert into public.profiles (user_id, name, nickname, age, started_on, bio, photo, updated_at)
      select v_user, coalesce(p ->> 'name', ''), coalesce(p ->> 'nickname', ''),
             (p ->> 'age')::int, (p ->> 'startedOn')::date, coalesce(p ->> 'bio', ''),
             p ->> 'photo', coalesce((p ->> 'updatedAt')::timestamptz, now())
      from (select p_data -> 'profile' as p) s
      on conflict (user_id) do nothing;
  end if;

  if jsonb_typeof(p_data -> 'settings') = 'object' then
    insert into public.settings (user_id, key, value)
      select v_user, s.key, s.value from jsonb_each_text(p_data -> 'settings') s
      on conflict (user_id, key) do nothing;
  end if;

  return jsonb_build_object(
    'status', v_status,
    'journeys', (select count(*) from public.journeys where user_id = v_user),
    'items', (select count(*) from public.items where user_id = v_user),
    'memories', (select count(*) from public.memories where user_id = v_user),
    'photos', (select count(*) from public.photos where user_id = v_user));
end $$;

-- ---------------------------------------------------------------------- sync

-- Everything of the caller's that changed after revision p_since, plus
-- the ids deleted since then. Start with 0 for a full copy, then pass the
-- returned "revision" next time. Rows are the table rows (snake_case).
create function public.pull_changes(p_since bigint default 0) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
  v_since bigint := coalesce(p_since, 0);
begin
  return jsonb_build_object(
    'revision', coalesce((select value from private.revisions where user_id = v_user), 0),
    'journeys', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.journeys t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.items t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'memories', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.memories t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'photos', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.photos t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.profiles t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'settings', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.revision)
       from public.settings t where t.user_id = v_user and t.revision > v_since), '[]'::jsonb),
    'deletions', coalesce((select jsonb_agg(jsonb_build_object(
         'table', d.table_name, 'id', d.record_id, 'revision', d.revision) order by d.revision)
       from private.deletions d where d.user_id = v_user and d.revision > v_since), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------- privileges

revoke execute on all functions in schema private from public;
grant execute on function private.is_active_member() to authenticated;

revoke execute on function
  public.progression(int),
  public.add_item(uuid, text, text),
  public.update_item(uuid, text, text, bigint),
  public.set_item_completed(uuid, boolean, date),
  public.delete_item(uuid),
  public.save_order(uuid[]),
  public.save_memory(jsonb),
  public.delete_memory(uuid),
  public.set_journey_start(date),
  public.start_new_journey(date, boolean, text, uuid),
  public.export_archive(),
  public.import_archive(jsonb),
  public.pull_changes(bigint)
from public, anon;

grant execute on function
  public.progression(int),
  public.add_item(uuid, text, text),
  public.update_item(uuid, text, text, bigint),
  public.set_item_completed(uuid, boolean, date),
  public.delete_item(uuid),
  public.save_order(uuid[]),
  public.save_memory(jsonb),
  public.delete_memory(uuid),
  public.set_journey_start(date),
  public.start_new_journey(date, boolean, text, uuid),
  public.export_archive(),
  public.import_archive(jsonb),
  public.pull_changes(bigint)
to authenticated;
