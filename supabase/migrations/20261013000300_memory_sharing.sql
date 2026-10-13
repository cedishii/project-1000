-- Project: 1000 friends: optionally share memories with friends.
--
-- Privacy rules (all enforced here, not in the app):
-- * Off by default: memory_visibility stays 'private' until its owner
--   chooses 'friends'. Nothing changes for anyone who doesn't.
-- * Only on top of a shared list: a friend sees memories only while they
--   may see the list itself (private.can_view_list: still friends, list
--   set to "Friends only", both active), and only for entries of the
--   current journey. Making the list or the memories private, or
--   removing the friend, ends access on the next request.
-- * Read-only, like the list.
-- * Locations are a separate choice (show_memory_location, off by
--   default): where someone was is more sensitive than what they wrote.
-- * Photos of shared memories (full size and thumbnail) become readable
--   by those friends through the storage policy below, checked against
--   the same rule on every download. Nothing else in the bucket is.
--
-- See docs/FRIENDS.md.

alter table public.social_profiles
  drop constraint social_profiles_memory_visibility_check,
  add constraint social_profiles_memory_visibility_check
    check (memory_visibility in ('private', 'friends')),
  add column show_memory_location boolean not null default false;

-- ------------------------------------------------------------------ helpers

-- Whether p_viewer may see p_owner's memories right now.
create function private.can_view_memories(p_owner uuid, p_viewer uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_owner = p_viewer
      or (private.can_view_list(p_owner, p_viewer)
          and exists (select 1 from public.social_profiles s
                      where s.user_id = p_owner
                        and s.memory_visibility = 'friends'))
$$;

-- ---------------------------------------------------------------- settings

-- Replaces the 1.4 version, which had no memory settings. The new
-- arguments default to null, meaning "keep what is saved", so an older
-- app saving its settings never turns memory sharing on or off.
drop function public.save_social_profile(
  text, text, boolean, boolean, boolean, boolean, boolean, text);

create function public.save_social_profile(
  p_username             text,
  p_display_name         text,
  p_show_photo           boolean default false,
  p_show_bio             boolean default false,
  p_show_started_on      boolean default false,
  p_show_stats           boolean default false,
  p_show_level           boolean default false,
  p_list_visibility      text default 'private',
  p_memory_visibility    text default null,
  p_show_memory_location boolean default null
) returns public.social_profiles
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
  v_username text := lower(private.trim_text(p_username));
  v_name text := private.trim_text(p_display_name);
  v_row public.social_profiles;
begin
  if v_username like '@%' then
    v_username := substr(v_username, 2);
  end if;
  if v_username !~ '^[a-z0-9_]{3,20}$' then
    perform private.fail('422', 'invalid_username');
  end if;
  if char_length(v_name) not between 1 and 60 then
    perform private.fail('422', 'invalid_display_name');
  end if;
  if p_list_visibility is null or p_list_visibility not in ('private', 'friends') then
    perform private.fail('422', 'invalid_visibility');
  end if;
  if p_memory_visibility is not null
     and p_memory_visibility not in ('private', 'friends') then
    perform private.fail('422', 'invalid_visibility');
  end if;
  begin
    insert into public.social_profiles as s (
      user_id, username, display_name, show_photo, show_bio, show_started_on,
      show_stats, show_level, list_visibility, memory_visibility,
      show_memory_location)
    values (
      v_user, v_username, v_name, coalesce(p_show_photo, false),
      coalesce(p_show_bio, false), coalesce(p_show_started_on, false),
      coalesce(p_show_stats, false), coalesce(p_show_level, false),
      p_list_visibility, coalesce(p_memory_visibility, 'private'),
      coalesce(p_show_memory_location, false))
    on conflict (user_id) do update set
      username = excluded.username,
      display_name = excluded.display_name,
      show_photo = excluded.show_photo,
      show_bio = excluded.show_bio,
      show_started_on = excluded.show_started_on,
      show_stats = excluded.show_stats,
      show_level = excluded.show_level,
      list_visibility = excluded.list_visibility,
      memory_visibility = coalesce(p_memory_visibility, s.memory_visibility),
      show_memory_location = coalesce(p_show_memory_location, s.show_memory_location),
      updated_at = now()
    returning * into v_row;
  exception when unique_violation then
    perform private.fail('409', 'username_taken');
  end;
  return v_row;
end $$;

-- -------------------------------------------------------------------- list

-- As in 1.4, plus whether memories are shared and, if so, how many each
-- entry has (so the app knows which entries have something to open).
create or replace function public.friend_list(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  v_memories boolean;
begin
  if p_user is null or not private.can_view_list(p_user, v_user) then
    perform private.fail('403', 'list_not_shared');
  end if;
  v_memories := private.can_view_memories(p_user, v_user);
  return jsonb_build_object(
    'memoriesShared', v_memories,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number', i.number,
               'title', i.title,
               'description', i.description,
               'isCompleted', i.is_completed,
               'completedOn', case when i.is_completed then i.completed_on end,
               'memories', case when v_memories then
                 (select count(*) from public.memories m
                  where m.item_id = i.id and m.user_id = p_user) else 0 end)
             order by i.position)
      from private.visible_items(p_user, v_user) i), '[]'::jsonb));
end $$;

-- --------------------------------------------------------------- memories

-- The memories of entry p_number of p_user's current list, oldest first,
-- if p_user shares memories with the caller. The same refusal whether
-- the list, the memories or the friendship is missing.
create function public.friend_memories(p_user uuid, p_number int) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  v_item uuid;
  v_location boolean;
begin
  if p_user is null or not private.can_view_memories(p_user, v_user) then
    perform private.fail('403', 'memories_not_shared');
  end if;
  select i.id into v_item from private.visible_items(p_user, v_user) i
    where i.number = p_number;
  if v_item is null then
    perform private.fail('404', 'item_not_found');
  end if;
  v_location := p_user = v_user or exists (
    select 1 from public.social_profiles
    where user_id = p_user and show_memory_location);
  return jsonb_build_object('memories', coalesce((
    select jsonb_agg(jsonb_build_object(
             'title', m.title,
             'body', m.body,
             'date', m.date,
             'location', case when v_location then m.location else '' end,
             'hashtags', to_jsonb(m.hashtags),
             'photos', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'file', ph.file,
                        'thumb', ph.thumb,
                        'width', ph.width,
                        'height', ph.height)
                      order by ph.position)
               from public.photos ph
               where ph.memory_id = m.id and ph.user_id = p_user), '[]'::jsonb))
           order by m.position)
    from public.memories m
    where m.item_id = v_item and m.user_id = p_user), '[]'::jsonb));
end $$;

-- ----------------------------------------------------------------- photos

-- A photo (or its thumbnail) of a memory the caller may see right now.
create function private.is_shared_memory_photo(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.photos ph
    join public.memories m on m.id = ph.memory_id and m.user_id = ph.user_id
    join public.items i on i.id = m.item_id and i.user_id = ph.user_id
    join public.journeys j on j.id = i.journey_id and j.user_id = ph.user_id
                          and j.status = 'active'
    where ph.user_id::text = split_part(p_name, '/', 1)
      and p_name in (ph.user_id::text || '/' || ph.file,
                     ph.user_id::text || '/' || ph.thumb)
      and private.can_view_memories(ph.user_id, (select auth.uid())))
$$;

create policy p1000_photos_select_shared_memory on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and private.is_shared_memory_photo(name));

-- ------------------------------------------------------------------ grants

revoke execute on function private.can_view_memories(uuid, uuid)
  from public, anon, authenticated;
revoke execute on function private.is_shared_memory_photo(text) from public, anon;
grant execute on function private.is_shared_memory_photo(text) to authenticated;

revoke execute on function
  public.save_social_profile(text, text, boolean, boolean, boolean, boolean,
                             boolean, text, text, boolean),
  public.friend_memories(uuid, int)
  from public, anon;
grant execute on function
  public.save_social_profile(text, text, boolean, boolean, boolean, boolean,
                             boolean, text, text, boolean),
  public.friend_memories(uuid, int)
  to authenticated;
