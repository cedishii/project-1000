-- Reads the apps need besides plain table selects, matching
-- lib/data/archive_repository.dart.

-- The active journey, creating Journey 1 for a brand-new account (as a
-- new phone does).
create function public.ensure_active_journey() returns public.journeys
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := private.begin_write();
begin
  return private.active_journey(v_user);
end $$;

-- ArchiveRepository.searchItemIds: items of the journey (default: the
-- active one) matching the term in their number, title, description, or
-- any memory's title, text, location or hashtags. Case-insensitive like
-- SQLite's LIKE; a leading '#' is ignored.
create function public.search_item_ids(p_query text, p_journey_id uuid default null)
returns setof uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
  v_term text := regexp_replace(private.trim_text(p_query), '^#', '');
  v_like text;
  v_number int;
  v_journey uuid := coalesce(p_journey_id,
    (select id from public.journeys where user_id = v_user and status = 'active'));
begin
  if v_term = '' or v_journey is null then
    return;
  end if;
  v_like := '%' || regexp_replace(v_term, '([\\%_])', '\\\1', 'g') || '%';
  v_number := case when v_term ~ '^\d{1,4}$' then v_term::int end;
  return query
    select i.id from public.items i
    where i.user_id = v_user and i.journey_id = v_journey and (
      i.number = v_number or i.title ilike v_like or i.description ilike v_like
      or exists (select 1 from public.memories m
                 where m.item_id = i.id and (
                   m.title ilike v_like or m.body ilike v_like or m.location ilike v_like
                   or exists (select 1 from unnest(m.hashtags) t where t ilike v_like))));
end $$;

-- ArchiveRepository.memoryCounts.
create function public.memory_counts(p_journey_id uuid default null)
returns table (item_id uuid, memory_count int)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
  v_journey uuid := coalesce(p_journey_id,
    (select id from public.journeys where user_id = v_user and status = 'active'));
begin
  return query
    select m.item_id, count(*)::int from public.memories m
    join public.items i on i.id = m.item_id
    where i.user_id = v_user and i.journey_id = v_journey
    group by m.item_id;
end $$;

-- ArchiveRepository.albumOutline: completed items in list order, each
-- with the size of its memories.
create function public.album_outline(p_journey_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'item', to_jsonb(i) - 'user_id',
      'memories', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', m.id,
          'textLength', length(m.body) + length(m.title),
          'photoCount', (select count(*) from public.photos ph where ph.memory_id = m.id))
          order by m.position, m.created_at, m.id)
        from public.memories m where m.item_id = i.id), '[]'::jsonb))
      order by i.position, i.created_at, i.id)
    from public.items i
    where i.user_id = v_user and i.journey_id = p_journey_id and i.is_completed), '[]'::jsonb);
end $$;

revoke execute on function
  public.ensure_active_journey(), public.search_item_ids(text, uuid),
  public.memory_counts(uuid), public.album_outline(uuid)
from public, anon;
grant execute on function
  public.ensure_active_journey(), public.search_item_ids(text, uuid),
  public.memory_counts(uuid), public.album_outline(uuid)
to authenticated;
