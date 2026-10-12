-- Project: 1000 friends: find other members, send and answer friend
-- requests, and see what friends chose to share.
--
-- Privacy rules (all enforced here, not in the app):
-- * Nobody can be found until they choose a username (a row in
--   public.social_profiles). Existing accounts have none, so they stay
--   invisible until they opt in.
-- * Search shows only what identifies an account: username, display
--   name, and the profile photo if its owner allows it.
-- * Everything else a friend may see (bio, start date, stats, level,
--   the list itself) is off until the owner turns it on, and is checked
--   on every request against the current friendship and setting, so
--   removing a friend or making the list private takes effect at once.
-- * Friends can only ever read. Every change to a list still goes
--   through the archive functions, which only touch the caller's rows.
-- * Memories, photos of memories and journey history are never shared.
--   memory_visibility exists so they can be shared separately later.
-- * Requests and friendships are written only by the functions below;
--   the tables accept no direct writes.
--
-- See docs/FRIENDS.md.

-- ---------------------------------------------------------------- profiles

create table public.social_profiles (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  -- Lowercase letters, digits and underscores; unique.
  username          text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name      text not null
                    check (char_length(display_name) between 1 and 60
                           and display_name !~ '^\s|\s$'),
  -- In search results and to friends.
  show_photo        boolean not null default false,
  -- To friends only.
  show_bio          boolean not null default false,
  show_started_on   boolean not null default false,
  show_stats        boolean not null default false,
  show_level        boolean not null default false,
  -- Who can see the bucket list (the whole list, for now; see
  -- private.visible_items for where per-entry visibility would go).
  list_visibility   text not null default 'private'
                    check (list_visibility in ('private', 'friends')),
  -- Reserved: memories and their photos are never shared yet.
  memory_visibility text not null default 'private'
                    check (memory_visibility in ('private')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- -------------------------------------------------------- friend requests

create table public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  sender_id    uuid not null references auth.users (id) on delete cascade,
  recipient_id uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'pending'
               check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (sender_id <> recipient_id)
);

-- At most one open request between two people, whichever way it goes.
create unique index friend_requests_one_pending on public.friend_requests
  (least(sender_id, recipient_id), greatest(sender_id, recipient_id))
  where status = 'pending';
create index friend_requests_recipient on public.friend_requests (recipient_id)
  where status = 'pending';
create index friend_requests_sender on public.friend_requests (sender_id, created_at);

-- ------------------------------------------------------------ friendships

-- One row per pair, the smaller id first, so a pair can't be stored twice.
create table public.friendships (
  user_low   uuid not null references auth.users (id) on delete cascade,
  user_high  uuid not null references auth.users (id) on delete cascade,
  request_id uuid,
  created_at timestamptz not null default now(),
  primary key (user_low, user_high),
  check (user_low < user_high)
);
create index friendships_high on public.friendships (user_high);

-- ------------------------------------------------------ row-level security

alter table public.social_profiles enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;

revoke all on public.social_profiles, public.friend_requests, public.friendships from anon;
revoke insert, update, delete, truncate
  on public.social_profiles, public.friend_requests, public.friendships
  from authenticated;

-- Each user reads their own settings, and the requests and friendships
-- they are part of. Other people's details come only through the
-- functions below, which apply the owner's choices.
create policy social_profiles_select_own on public.social_profiles
  for select to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_member()));
create policy friend_requests_select_own on public.friend_requests
  for select to authenticated
  using ((select auth.uid()) in (sender_id, recipient_id)
         and (select private.is_active_member()));
create policy friendships_select_own on public.friendships
  for select to authenticated
  using ((select auth.uid()) in (user_low, user_high)
         and (select private.is_active_member()));

-- ------------------------------------------------------------------ helpers

-- An active member with a username: someone who can be found and
-- befriended. Disabled members disappear from everyone's view.
create function private.is_findable(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.social_profiles s
    join public.members m on m.user_id = s.user_id and m.status = 'active'
    where s.user_id = p_user)
$$;

create function private.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where f.user_low = least(a, b) and f.user_high = greatest(a, b))
$$;

-- Serialises everything that happens between two people (requests in
-- both directions, accepting, removing), so they can't race.
create function private.lock_pair(a uuid, b uuid) returns void
language sql volatile set search_path = '' as $$
  select pg_advisory_xact_lock(
    hashtextextended(least(a, b)::text || greatest(a, b)::text, 1000))
$$;

-- The caller, if they are an active member who chose a username.
create function private.require_social() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  if not exists (select 1 from public.social_profiles where user_id = v_user) then
    perform private.fail('409', 'username_required');
  end if;
  return v_user;
end $$;

-- Whether p_viewer may see p_owner's list right now.
create function private.can_view_list(p_owner uuid, p_viewer uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_owner = p_viewer
      or (private.is_findable(p_owner)
          and private.is_findable(p_viewer)
          and exists (select 1 from public.social_profiles s
                      where s.user_id = p_owner and s.list_visibility = 'friends')
          and private.are_friends(p_owner, p_viewer))
$$;

-- The entries of p_owner's current list that p_viewer may see, in the
-- owner's order. Per-entry visibility, if added later, belongs here.
create function private.visible_items(p_owner uuid, p_viewer uuid)
returns setof public.items
language sql stable security definer set search_path = '' as $$
  select i.* from public.items i
  join public.journeys j on j.id = i.journey_id and j.status = 'active'
  where i.user_id = p_owner and j.user_id = p_owner
    and private.can_view_list(p_owner, p_viewer)
  order by i.position
$$;

-- How someone appears to others: only what identifies them.
create function private.person(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'userId', s.user_id,
    'username', s.username,
    'displayName', s.display_name,
    'photo', case when s.show_photo then p.photo end)
  from public.social_profiles s
  left join public.profiles p on p.user_id = s.user_id
  where s.user_id = p_user
$$;

-- Where p_other stands with p_viewer: self, friend, sent (by the
-- viewer, waiting), received (from them, waiting) or none.
create function private.relation(p_viewer uuid, p_other uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  r public.friend_requests;
begin
  if p_viewer = p_other then
    return jsonb_build_object('relation', 'self');
  end if;
  if private.are_friends(p_viewer, p_other) then
    return jsonb_build_object('relation', 'friend');
  end if;
  select * into r from public.friend_requests
    where status = 'pending'
      and ((sender_id = p_viewer and recipient_id = p_other)
        or (sender_id = p_other and recipient_id = p_viewer));
  if found then
    return jsonb_build_object(
      'relation', case when r.sender_id = p_viewer then 'sent' else 'received' end,
      'requestId', r.id);
  end if;
  return jsonb_build_object('relation', 'none');
end $$;

-- ------------------------------------------------------- your own profile

-- Creates or changes the caller's username and sharing choices.
create function public.save_social_profile(
  p_username        text,
  p_display_name    text,
  p_show_photo      boolean default false,
  p_show_bio        boolean default false,
  p_show_started_on boolean default false,
  p_show_stats      boolean default false,
  p_show_level      boolean default false,
  p_list_visibility text default 'private'
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
  begin
    insert into public.social_profiles as s (
      user_id, username, display_name, show_photo, show_bio, show_started_on,
      show_stats, show_level, list_visibility)
    values (
      v_user, v_username, v_name, coalesce(p_show_photo, false),
      coalesce(p_show_bio, false), coalesce(p_show_started_on, false),
      coalesce(p_show_stats, false), coalesce(p_show_level, false),
      p_list_visibility)
    on conflict (user_id) do update set
      username = excluded.username,
      display_name = excluded.display_name,
      show_photo = excluded.show_photo,
      show_bio = excluded.show_bio,
      show_started_on = excluded.show_started_on,
      show_stats = excluded.show_stats,
      show_level = excluded.show_level,
      list_visibility = excluded.list_visibility,
      updated_at = now()
    returning * into v_row;
  exception when unique_violation then
    perform private.fail('409', 'username_taken');
  end;
  return v_row;
end $$;

-- Stops using Friends: removes the username (so nobody can find the
-- caller), every friendship and every request they are part of. The
-- caller's own list, memories and progress are not touched.
create function public.delete_social_profile() returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  delete from public.friendships where v_user in (user_low, user_high);
  delete from public.friend_requests where v_user in (sender_id, recipient_id);
  delete from public.social_profiles where user_id = v_user;
  return found;
end $$;

-- ------------------------------------------------------------------ search

-- Members with a username matching p_query (username prefix, or part of
-- the display name), at most 20, each with where they stand with the
-- caller. Only identifying details are returned.
create function public.search_people(p_query text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  v_query text := lower(private.trim_text(p_query));
  v_like text;
begin
  if v_query like '@%' then
    v_query := substr(v_query, 2);
  end if;
  if char_length(v_query) < 2 then
    return '[]'::jsonb;
  end if;
  v_like := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');
  return coalesce((
    select jsonb_agg(private.person(s.user_id) || private.relation(v_user, s.user_id)
                     order by (s.username = v_query) desc,
                              (s.username like v_like || '%') desc,
                              lower(s.display_name), s.username)
    from (
      select s.* from public.social_profiles s
      join public.members m on m.user_id = s.user_id and m.status = 'active'
      where s.user_id <> v_user
        and (s.username like v_like || '%'
             or lower(s.display_name) like '%' || v_like || '%')
      order by (s.username = v_query) desc, (s.username like v_like || '%') desc,
               lower(s.display_name), s.username
      limit 20
    ) s
  ), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- requests

-- Sends a friend request to p_user. Sending again while it is waiting
-- returns the same request.
create function public.send_friend_request(p_user uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  r public.friend_requests;
begin
  if p_user is null or p_user = v_user then
    perform private.fail('422', 'cannot_add_yourself');
  end if;
  if not private.is_findable(p_user) then
    perform private.fail('404', 'person_not_found');
  end if;
  perform private.lock_pair(v_user, p_user);
  if private.are_friends(v_user, p_user) then
    perform private.fail('409', 'already_friends');
  end if;
  select * into r from public.friend_requests
    where status = 'pending'
      and least(sender_id, recipient_id) = least(v_user, p_user)
      and greatest(sender_id, recipient_id) = greatest(v_user, p_user);
  if found then
    if r.sender_id = v_user then
      return jsonb_build_object('requestId', r.id, 'status', 'pending');
    end if;
    perform private.fail('409', 'they_already_asked_you');
  end if;
  -- Declined: wait a week before asking the same person again.
  if exists (select 1 from public.friend_requests
             where sender_id = v_user and recipient_id = p_user
               and status = 'declined' and responded_at > now() - interval '7 days') then
    perform private.fail('409', 'recently_declined');
  end if;
  if (select count(*) from public.friend_requests
      where sender_id = v_user and created_at > now() - interval '1 day') >= 50 then
    perform private.fail('429', 'too_many_requests');
  end if;
  insert into public.friend_requests (sender_id, recipient_id)
    values (v_user, p_user) returning * into r;
  return jsonb_build_object('requestId', r.id, 'status', 'pending');
end $$;

-- The recipient accepts or declines a waiting request. Repeating the
-- same answer is harmless; anything else that isn't waiting fails.
create function public.respond_friend_request(p_request uuid, p_accept boolean)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  r public.friend_requests;
begin
  select * into r from public.friend_requests
    where id = p_request and recipient_id = v_user;
  if not found or p_accept is null then
    perform private.fail('404', 'request_not_found');
  end if;
  perform private.lock_pair(v_user, r.sender_id);
  select * into r from public.friend_requests where id = p_request for update;
  if r.status = (case when p_accept then 'accepted' else 'declined' end) then
    return jsonb_build_object('status', r.status);
  end if;
  if r.status <> 'pending' then
    perform private.fail('409', 'request_not_pending');
  end if;
  if p_accept then
    if not private.is_findable(r.sender_id) then
      perform private.fail('404', 'person_not_found');
    end if;
    insert into public.friendships (user_low, user_high, request_id)
      values (least(v_user, r.sender_id), greatest(v_user, r.sender_id), r.id)
      on conflict do nothing;
  end if;
  update public.friend_requests
    set status = case when p_accept then 'accepted' else 'declined' end,
        responded_at = now()
    where id = r.id;
  return jsonb_build_object('status', case when p_accept then 'accepted' else 'declined' end);
end $$;

-- The sender withdraws a waiting request.
create function public.cancel_friend_request(p_request uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  r public.friend_requests;
begin
  select * into r from public.friend_requests
    where id = p_request and sender_id = v_user;
  if not found then
    perform private.fail('404', 'request_not_found');
  end if;
  perform private.lock_pair(v_user, r.recipient_id);
  select * into r from public.friend_requests where id = p_request for update;
  if r.status = 'cancelled' then
    return jsonb_build_object('status', 'cancelled');
  end if;
  if r.status <> 'pending' then
    perform private.fail('409', 'request_not_pending');
  end if;
  update public.friend_requests
    set status = 'cancelled', responded_at = now() where id = r.id;
  return jsonb_build_object('status', 'cancelled');
end $$;

-- Ends a friendship (either friend may). Returns false if they weren't
-- friends.
create function public.remove_friend(p_user uuid) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  if p_user is null then
    return false;
  end if;
  perform private.lock_pair(v_user, p_user);
  delete from public.friendships
    where user_low = least(v_user, p_user) and user_high = greatest(v_user, p_user);
  return found;
end $$;

-- --------------------------------------------------------------- listings

-- The caller's friends, by name.
create function public.list_friends() returns jsonb
language sql stable security definer set search_path = '' as $$
  with me as (select private.require_social() as id)
  select coalesce(jsonb_agg(
           private.person(f.friend) || jsonb_build_object('relation', 'friend', 'since', f.created_at)
           order by lower(s.display_name), s.username), '[]'::jsonb)
  from me
  cross join lateral (
    select case when fs.user_low = me.id then fs.user_high else fs.user_low end as friend,
           fs.created_at
    from public.friendships fs
    where me.id in (fs.user_low, fs.user_high)
  ) f
  join public.social_profiles s on s.user_id = f.friend
  where private.is_findable(f.friend)
$$;

-- Waiting requests: received (newest first) and sent.
create function public.list_friend_requests() returns jsonb
language sql stable security definer set search_path = '' as $$
  with me as (select private.require_social() as id)
  select jsonb_build_object(
    'received', coalesce((
      select jsonb_agg(private.person(r.sender_id) || jsonb_build_object(
               'relation', 'received', 'requestId', r.id, 'sentAt', r.created_at)
             order by r.created_at desc)
      from public.friend_requests r, me
      where r.recipient_id = me.id and r.status = 'pending'
        and private.is_findable(r.sender_id)), '[]'::jsonb),
    'sent', coalesce((
      select jsonb_agg(private.person(r.recipient_id) || jsonb_build_object(
               'relation', 'sent', 'requestId', r.id, 'sentAt', r.created_at)
             order by r.created_at desc)
      from public.friend_requests r, me
      where r.sender_id = me.id and r.status = 'pending'
        and private.is_findable(r.recipient_id)), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------- profile

-- What the caller may see of p_user. Anyone with a username: who they
-- are. Friends (and the user themselves, as a preview): also what the
-- owner chose to share.
create function public.friend_profile(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
  s public.social_profiles;
  p public.profiles;
  v_result jsonb;
  v_completed int;
  v_listed int;
  pr record;
begin
  if p_user is null or not private.is_findable(p_user) then
    perform private.fail('404', 'person_not_found');
  end if;
  v_result := private.person(p_user) || private.relation(v_user, p_user);
  if v_user <> p_user and not private.are_friends(v_user, p_user) then
    return v_result;
  end if;

  select * into s from public.social_profiles where user_id = p_user;
  select * into p from public.profiles where user_id = p_user;
  v_result := v_result || jsonb_build_object('listShared', s.list_visibility = 'friends');
  if s.show_bio and coalesce(p.bio, '') <> '' then
    v_result := v_result || jsonb_build_object('bio', p.bio);
  end if;
  if s.show_started_on and p.started_on is not null then
    v_result := v_result || jsonb_build_object('startedOn', p.started_on);
  end if;
  if s.show_stats or s.show_level then
    select count(*) filter (where i.is_completed), count(*)
      into v_completed, v_listed
      from public.items i
      join public.journeys j on j.id = i.journey_id and j.status = 'active'
      where i.user_id = p_user;
  end if;
  if s.show_stats then
    v_result := v_result || jsonb_build_object('stats', jsonb_build_object(
      'completed', v_completed,
      'listed', v_listed,
      'journeysFinished', (select count(*) from public.journeys
                           where user_id = p_user and status = 'archived')));
  end if;
  if s.show_level then
    select * into pr from public.progression(v_completed);
    v_result := v_result || jsonb_build_object('progress', jsonb_build_object(
      'level', pr.level, 'exp', pr.exp));
  end if;
  return v_result;
end $$;

-- p_user's current list, read-only, if they share it with the caller.
-- The same refusal whether the list is private or the caller isn't a
-- friend, so it reveals nothing.
create function public.friend_list(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_social();
begin
  if p_user is null or not private.can_view_list(p_user, v_user) then
    perform private.fail('403', 'list_not_shared');
  end if;
  return jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'number', i.number,
             'title', i.title,
             'description', i.description,
             'isCompleted', i.is_completed,
             'completedOn', case when i.is_completed then i.completed_on end)
           order by i.position)
    from private.visible_items(p_user, v_user) i), '[]'::jsonb));
end $$;

-- ----------------------------------------------------------------- photos

-- Profile photos their owners chose to show: readable by members who use
-- Friends, and only the current profile photo (not older ones kept with
-- archived journeys, and nothing from memories).
create function private.is_shared_profile_photo(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_active_member()
     and exists (select 1 from public.social_profiles where user_id = (select auth.uid()))
     and exists (
       select 1 from public.social_profiles s
       join public.members m on m.user_id = s.user_id and m.status = 'active'
       join public.profiles p on p.user_id = s.user_id
       where s.show_photo and p.photo is not null
         and p_name = s.user_id::text || '/' || p.photo)
$$;

create policy p1000_photos_select_shared_profile on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and private.is_shared_profile_photo(name));

-- ------------------------------------------------------------------ grants

revoke execute on all functions in schema private from public;
grant execute on function private.is_active_member() to authenticated;
grant execute on function private.is_own_media_path(text) to authenticated;
grant execute on function private.is_shared_profile_photo(text) to authenticated;

revoke execute on function
  public.save_social_profile(text, text, boolean, boolean, boolean, boolean, boolean, text),
  public.delete_social_profile(),
  public.search_people(text),
  public.send_friend_request(uuid),
  public.respond_friend_request(uuid, boolean),
  public.cancel_friend_request(uuid),
  public.remove_friend(uuid),
  public.list_friends(),
  public.list_friend_requests(),
  public.friend_profile(uuid),
  public.friend_list(uuid)
  from public, anon;
grant execute on function
  public.save_social_profile(text, text, boolean, boolean, boolean, boolean, boolean, text),
  public.delete_social_profile(),
  public.search_people(text),
  public.send_friend_request(uuid),
  public.respond_friend_request(uuid, boolean),
  public.cancel_friend_request(uuid),
  public.remove_friend(uuid),
  public.list_friends(),
  public.list_friend_requests(),
  public.friend_profile(uuid),
  public.friend_list(uuid)
  to authenticated;
