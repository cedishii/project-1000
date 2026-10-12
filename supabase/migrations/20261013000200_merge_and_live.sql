-- Project: 1000: merging a backup or a phone's archive into an account
-- that already has its own list, and live change signals.
--
-- merge_archive adds what the account doesn't have yet and never removes
-- or rewrites anything the account already holds:
-- * Records keep their ids, so merging the same file again changes
--   nothing (no duplicates, no EXP awarded twice: EXP is still derived
--   from the completed count).
-- * Things of the file's current journey join the account's current
--   list, after its own things, in the file's order. A thing whose id is
--   already in the account, or (optionally) with the same title, counts
--   as the same thing: its missing memories are added, and if the file
--   has it completed and the account doesn't, it becomes completed with
--   the file's date. Its text stays as the account has it.
-- * A thing's number is kept unless the account's list already uses it;
--   then it gets the lowest free number.
-- * Finished journeys from the file are added when the account has no
--   finished journeys of its own (or the same ones). Two different
--   histories are not combined ('history_conflict').
-- * The profile is taken from the file only when the account's is empty;
--   settings only for keys the account doesn't have.
-- * With p_apply = false nothing is stored: the same work is done and
--   rolled back, and the summary says exactly what applying would do.
--
-- sync_heads: one row per account, bumped once per statement that
-- changes the account's archive. Clients subscribe to their own row
-- through Supabase Realtime and then fetch the changes (pull_changes);
-- the signal itself carries no data.

-- ------------------------------------------------------------------ merge

create function private.merge_into(p_user uuid, p_data jsonb, p_match_titles boolean)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_journeys jsonb := p_data -> 'journeys';
  v_file_active jsonb;
  ja public.journeys;
  v_target uuid;
  v_new int := 0; v_by_id int := 0; v_by_title int := 0; v_completions int := 0;
  v_memories int := 0; v_photos int := 0; v_renumbered int := 0; v_text_kept int := 0;
  v_journeys_added int := 0; v_replaced boolean := false;
  v_profile text := 'none'; v_settings int := 0;
  fi jsonb; fm jsonb; fj jsonb;
  t public.items;
  v_item uuid;
  v_number int; v_position int; v_mpos int;
  v_max_file_archived int;
  n int;
  p public.profiles;
begin
  if (p_data ->> 'dataFormatVersion') is distinct from '2'
     or jsonb_typeof(v_journeys) is distinct from 'array' then
    perform private.fail('422', 'unsupported_format');
  end if;
  if (select count(*) from jsonb_array_elements(v_journeys) e
      where e ->> 'status' = 'active') <> 1 then
    perform private.fail('422', 'invalid_data');
  end if;
  -- Ids that belong to another account are never taken over.
  if exists (select 1 from public.journeys x where x.user_id <> p_user and x.id in (
               select (y #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].id') y))
     or exists (select 1 from public.items x where x.user_id <> p_user and x.id in (
               select (y #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].id') y))
     or exists (select 1 from public.memories x where x.user_id <> p_user and x.id in (
               select (y #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].memories[*].id') y))
     or exists (select 1 from public.photos x where x.user_id <> p_user and x.id in (
               select (y #>> '{}')::uuid from jsonb_path_query(p_data, '$.journeys[*].items[*].memories[*].photos[*].id') y))
  then
    perform private.fail('409', 'id_conflict');
  end if;

  select e into v_file_active from jsonb_array_elements(v_journeys) e
    where e ->> 'status' = 'active';
  ja := private.active_journey(p_user);

  -- An account with nothing but its empty first journey takes the file's
  -- journeys as they are (like a first copy from a phone).
  if ja.number = 1
     and not exists (select 1 from public.journeys where user_id = p_user and id <> ja.id)
     and not exists (select 1 from public.items where user_id = p_user)
     and not exists (select 1 from jsonb_array_elements(v_journeys) e
                     where (e ->> 'id')::uuid = ja.id) then
    delete from public.journeys where id = ja.id;
    v_replaced := true;
    insert into public.journeys (id, user_id, number, status, started_on, completed_on,
                                 snapshot, created_at, archived_at)
      select (j ->> 'id')::uuid, p_user, (j ->> 'number')::int, j ->> 'status',
             (j ->> 'startedOn')::date, (j ->> 'completedOn')::date,
             case when jsonb_typeof(j -> 'snapshot') = 'object' then j -> 'snapshot' end,
             coalesce((j ->> 'createdAt')::timestamptz, now()), (j ->> 'archivedAt')::timestamptz
      from jsonb_array_elements(v_journeys) j;
    v_journeys_added := jsonb_array_length(v_journeys);
    select * into ja from public.journeys where user_id = p_user and status = 'active';
  else
    -- Finished journeys of the file.
    if exists (select 1 from jsonb_array_elements(v_journeys) e
               where e ->> 'status' = 'archived'
                 and not exists (select 1 from public.journeys x where x.id = (e ->> 'id')::uuid)) then
      if exists (select 1 from public.journeys x
                 where x.user_id = p_user and x.status = 'archived'
                   and not exists (select 1 from jsonb_array_elements(v_journeys) e
                                   where (e ->> 'id')::uuid = x.id)) then
        perform private.fail('409', 'history_conflict');
      end if;
      select max((e ->> 'number')::int) into v_max_file_archived
        from jsonb_array_elements(v_journeys) e where e ->> 'status' = 'archived';
      if ja.number <= v_max_file_archived then
        update public.journeys set number = v_max_file_archived + 1 where id = ja.id
          returning * into ja;
      end if;
      insert into public.journeys (id, user_id, number, status, started_on, completed_on,
                                   snapshot, created_at, archived_at)
        select (j ->> 'id')::uuid, p_user, (j ->> 'number')::int, 'archived',
               (j ->> 'startedOn')::date, (j ->> 'completedOn')::date,
               case when jsonb_typeof(j -> 'snapshot') = 'object' then j -> 'snapshot' end,
               coalesce((j ->> 'createdAt')::timestamptz, now()), (j ->> 'archivedAt')::timestamptz
        from jsonb_array_elements(v_journeys) j
        where j ->> 'status' = 'archived'
          and not exists (select 1 from public.journeys x where x.id = (j ->> 'id')::uuid);
      get diagnostics n = row_count;
      v_journeys_added := n;
    end if;
    if ja.started_on is null and (v_file_active ->> 'startedOn') is not null then
      update public.journeys set started_on = (v_file_active ->> 'startedOn')::date
        where id = ja.id;
    end if;
  end if;

  -- Things, journey by journey: the file's current journey goes into the
  -- account's current one; a finished journey into itself.
  for fj in select e from jsonb_array_elements(v_journeys) e
            order by (e ->> 'status' = 'active'), (e ->> 'number')::int loop
    if fj ->> 'status' = 'active' then
      v_target := ja.id;
    else
      v_target := (fj ->> 'id')::uuid;
      if not exists (select 1 from public.journeys
                     where id = v_target and user_id = p_user and status = 'archived') then
        continue;
      end if;
    end if;

    for fi in select e from jsonb_array_elements(coalesce(fj -> 'items', '[]'::jsonb)) e
              order by (e ->> 'position')::int loop
      select * into t from public.items where id = (fi ->> 'id')::uuid;
      if found then
        v_by_id := v_by_id + 1;
      elsif p_match_titles and fj ->> 'status' = 'active' then
        select * into t from public.items i
          where i.journey_id = v_target
            and lower(private.trim_text(i.title)) = lower(private.trim_text(fi ->> 'title'))
          order by i.position limit 1;
        if found then
          v_by_title := v_by_title + 1;
        end if;
      end if;

      if found then
        v_item := t.id;
        if (t.title, t.description) is distinct from
           (fi ->> 'title', coalesce(fi ->> 'description', '')) then
          v_text_kept := v_text_kept + 1;
        end if;
        if coalesce((fi ->> 'isCompleted')::boolean, false) and not t.is_completed then
          if exists (select 1 from public.journeys where id = t.journey_id and status = 'active') then
            update public.items
              set is_completed = true,
                  completed_on = coalesce((fi ->> 'completedOn')::date, t.completed_on),
                  updated_at = now()
              where id = t.id;
            v_completions := v_completions + 1;
          end if;
        end if;
      else
        if (select count(*) from public.items where journey_id = v_target) >= 1000 then
          perform private.fail('409', 'list_full');
        end if;
        v_number := (fi ->> 'number')::int;
        if v_number is null or v_number not between 1 and 1000
           or exists (select 1 from public.items where journey_id = v_target and number = v_number) then
          select min(x) into v_number from generate_series(1, 1000) x
            where not exists (select 1 from public.items i
                              where i.journey_id = v_target and i.number = x);
          v_renumbered := v_renumbered + 1;
        end if;
        select coalesce(max(position) + 1, 0) into v_position
          from public.items where journey_id = v_target;
        insert into public.items (id, user_id, journey_id, number, position, title, description,
                                  is_completed, completed_on, created_at, updated_at)
          values ((fi ->> 'id')::uuid, p_user, v_target, v_number, v_position,
                  private.check_title(fi ->> 'title'), coalesce(fi ->> 'description', ''),
                  coalesce((fi ->> 'isCompleted')::boolean, false), (fi ->> 'completedOn')::date,
                  coalesce((fi ->> 'createdAt')::timestamptz, now()),
                  coalesce((fi ->> 'updatedAt')::timestamptz, now()))
          returning id into v_item;
        v_new := v_new + 1;
      end if;

      -- Memories the account doesn't have yet, after its own.
      for fm in select e from jsonb_array_elements(coalesce(fi -> 'memories', '[]'::jsonb)) e
                order by (e ->> 'position')::int loop
        continue when exists (select 1 from public.memories where id = (fm ->> 'id')::uuid);
        select coalesce(max(position) + 1, 0) into v_mpos
          from public.memories where item_id = v_item;
        insert into public.memories (id, user_id, item_id, position, title, body, date, location,
                                     hashtags, created_at, updated_at)
          values ((fm ->> 'id')::uuid, p_user, v_item, v_mpos,
                  coalesce(fm ->> 'title', ''), coalesce(fm ->> 'text', ''), (fm ->> 'date')::date,
                  coalesce(fm ->> 'location', ''),
                  array(select jsonb_array_elements_text(coalesce(fm -> 'hashtags', '[]'::jsonb))),
                  coalesce((fm ->> 'createdAt')::timestamptz, now()),
                  coalesce((fm ->> 'updatedAt')::timestamptz, now()));
        v_memories := v_memories + 1;
        insert into public.photos (id, user_id, memory_id, position, file, thumb, width, height,
                                   created_at)
          select (ph ->> 'id')::uuid, p_user, (fm ->> 'id')::uuid, (ph ->> 'position')::int,
                 ph ->> 'file', ph ->> 'thumb', (ph ->> 'width')::int, (ph ->> 'height')::int,
                 coalesce((ph ->> 'createdAt')::timestamptz, now())
          from jsonb_array_elements(coalesce(fm -> 'photos', '[]'::jsonb)) ph
          on conflict (id) do nothing;
        get diagnostics n = row_count;
        v_photos := v_photos + n;
      end loop;
    end loop;
  end loop;

  -- Profile: only into an empty one.
  if jsonb_typeof(p_data -> 'profile') = 'object' then
    select * into p from public.profiles where user_id = p_user;
    if private.profile_is_empty(p) then
      insert into public.profiles as x (user_id, name, nickname, age, started_on, bio, photo, updated_at)
        select p_user, coalesce(f ->> 'name', ''), coalesce(f ->> 'nickname', ''),
               (f ->> 'age')::int, (f ->> 'startedOn')::date, coalesce(f ->> 'bio', ''),
               f ->> 'photo', coalesce((f ->> 'updatedAt')::timestamptz, now())
        from (select p_data -> 'profile' as f) s
        on conflict (user_id) do update set
          name = excluded.name, nickname = excluded.nickname, age = excluded.age,
          started_on = excluded.started_on, bio = excluded.bio, photo = excluded.photo,
          updated_at = excluded.updated_at;
      v_profile := 'added';
    elsif (select count(*) from jsonb_each(p_data -> 'profile') e
           where e.key in ('name', 'nickname', 'bio', 'photo', 'age', 'startedOn')
             and e.value not in ('null'::jsonb, '""'::jsonb)) > 0
          and (p.name, p.nickname, p.bio, p.photo, p.age, p.started_on) is distinct from
              (coalesce(p_data #>> '{profile,name}', ''), coalesce(p_data #>> '{profile,nickname}', ''),
               coalesce(p_data #>> '{profile,bio}', ''), p_data #>> '{profile,photo}',
               (p_data #>> '{profile,age}')::int, (p_data #>> '{profile,startedOn}')::date) then
      v_profile := 'kept';
    end if;
  end if;

  if jsonb_typeof(p_data -> 'settings') = 'object' then
    insert into public.settings (user_id, key, value)
      select p_user, s.key, s.value from jsonb_each_text(p_data -> 'settings') s
      on conflict (user_id, key) do nothing;
    get diagnostics n = row_count;
    v_settings := n;
  end if;

  return jsonb_build_object(
    'replacedEmptyJourney', v_replaced,
    'journeysAdded', v_journeys_added,
    'itemsAdded', v_new,
    'matchedById', v_by_id,
    'matchedByTitle', v_by_title,
    'completionsAdded', v_completions,
    'textKept', v_text_kept,
    'renumbered', v_renumbered,
    'memoriesAdded', v_memories,
    'photosAdded', v_photos,
    'profile', v_profile,
    'settingsAdded', v_settings);
end $$;

create function private.archive_totals(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'journeys', (select count(*) from public.journeys where user_id = p_user),
    'items', (select count(*) from public.items where user_id = p_user),
    'memories', (select count(*) from public.memories where user_id = p_user),
    'photos', (select count(*) from public.photos where user_id = p_user),
    'completed', coalesce((select count(*) from public.items i
                           join public.journeys j on j.id = i.journey_id and j.status = 'active'
                           where i.user_id = p_user and i.is_completed), 0),
    'listed', coalesce((select count(*) from public.items i
                        join public.journeys j on j.id = i.journey_id and j.status = 'active'
                        where i.user_id = p_user), 0))
$$;

-- Merges p_data (a backup's data.json, version 2) into the caller's
-- account. p_apply = false: only reports what would happen. Returns
-- {applied, before, after, changes, ...} where before/after are record
-- counts and the current journey's completed count (EXP follows from it).
-- Photo files are uploaded by the client afterwards (archive_files lists
-- what is still missing).
create function public.merge_archive(
  p_data jsonb, p_apply boolean default false, p_match_titles boolean default true)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
  v_before jsonb := private.archive_totals(v_user);
  v_changes jsonb;
  v_after jsonb;
begin
  if pg_column_size(p_data) > 50 * 1024 * 1024 then
    perform private.fail('413', 'too_large');
  end if;
  begin
    v_changes := private.merge_into(v_user, p_data, coalesce(p_match_titles, true));
    v_after := private.archive_totals(v_user);
    if not coalesce(p_apply, false) then
      -- Undo everything done above; the summary stays.
      raise exception using errcode = 'PXDRY', message = 'dry_run';
    end if;
  exception when sqlstate 'PXDRY' then
    null;
  end;
  return jsonb_build_object(
    'applied', coalesce(p_apply, false),
    'before', v_before,
    'after', v_after,
    'changes', v_changes,
    'nothingToAdd', (v_changes ->> 'itemsAdded')::int = 0
                    and (v_changes ->> 'completionsAdded')::int = 0
                    and (v_changes ->> 'memoriesAdded')::int = 0
                    and (v_changes ->> 'photosAdded')::int = 0
                    and (v_changes ->> 'journeysAdded')::int = 0
                    and v_changes ->> 'profile' <> 'added'
                    and (v_changes ->> 'settingsAdded')::int = 0);
end $$;

revoke execute on function public.merge_archive(jsonb, boolean, boolean) from public, anon;
grant execute on function public.merge_archive(jsonb, boolean, boolean) to authenticated;

-- ------------------------------------------------------------ live signal

create table public.sync_heads (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  revision   bigint not null default 0,
  changed_at timestamptz not null default now()
);
alter table public.sync_heads enable row level security;
revoke all on public.sync_heads from anon;
revoke insert, update, delete, truncate on public.sync_heads from authenticated;
create policy sync_heads_select_own on public.sync_heads for select to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_member()));

create function private.bump_sync_head() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.sync_heads as h (user_id, revision, changed_at)
    select c.user_id, coalesce(r.value, 0), now()
    from (select distinct user_id from changed) c
    left join private.revisions r on r.user_id = c.user_id
    where exists (select 1 from auth.users u where u.id = c.user_id)
  on conflict (user_id) do update
    set revision = excluded.revision, changed_at = excluded.changed_at;
  return null;
end $$;

do $$
declare
  t text;
begin
  foreach t in array array['journeys', 'items', 'memories', 'photos', 'profiles', 'settings']
  loop
    execute format(
      'create trigger bump_sync_head_ins after insert on public.%I '
      'referencing new table as changed for each statement execute function private.bump_sync_head()', t);
    execute format(
      'create trigger bump_sync_head_upd after update on public.%I '
      'referencing new table as changed for each statement execute function private.bump_sync_head()', t);
    execute format(
      'create trigger bump_sync_head_del after delete on public.%I '
      'referencing old table as changed for each statement execute function private.bump_sync_head()', t);
  end loop;
end $$;

-- Realtime delivers changes of this table (to its owner only: RLS).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.sync_heads;
  end if;
end $$;

revoke execute on all functions in schema private from public;
grant execute on function private.is_active_member() to authenticated;
grant execute on function private.is_own_media_path(text) to authenticated;
grant execute on function private.is_shared_profile_photo(text) to authenticated;
