-- Project: 1000 photo storage: one private bucket, one folder per account.
--
--   photos/<user_id>/photos/<photo id>.<ext>   full photos
--   photos/<user_id>/thumbs/<photo id>.jpg     thumbnails (480 px)
--   photos/<user_id>/profile/<id>.jpg          profile pictures
--
-- The paths after <user_id>/ are exactly the archive-relative paths the
-- phone already uses (photos.file, photos.thumb, profiles.photo), so a
-- record points at the same file on every device.
--
-- The bucket is private: there are no public URLs. Clients download with
-- their session or use short-lived signed URLs (createSignedUrl), and
-- lists should show the thumbnail, not the full photo.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'photos', 'photos', false,
  52428800, -- 50 MB; photos from a phone are far smaller
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'image/gif']
)
on conflict (id) do nothing;

-- A path the caller may use: inside their own folder, in one of the three
-- media folders, with a plain file name (same rule as backup import).
create function private.is_own_media_path(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and p_name ~ ('^' || (select auth.uid())::text
                   || '/(photos|thumbs|profile)/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$')
     and p_name not like '%..%'
     and private.is_active_member()
$$;
revoke execute on function private.is_own_media_path(text) from public;
grant execute on function private.is_own_media_path(text) to authenticated;

create policy p1000_photos_select on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (select private.is_own_media_path(name)));
create policy p1000_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (select private.is_own_media_path(name)));
create policy p1000_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (select private.is_own_media_path(name)))
  with check (bucket_id = 'photos' and (select private.is_own_media_path(name)));
create policy p1000_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (select private.is_own_media_path(name)));

-- Every file the caller's records refer to, and whether it is in storage
-- (with its size). Used to finish and verify a migration: a photo counts
-- as migrated only when the server has the file, not when an upload
-- request merely returned.
create function public.archive_files()
returns table (path text, kind text, present boolean, size bigint)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
begin
  return query
    with expected as (
      select ph.file as path, 'photo' as kind from public.photos ph where ph.user_id = v_user
      union
      select ph.thumb, 'thumb' from public.photos ph where ph.user_id = v_user
      union
      select p.photo, 'profile' from public.profiles p
        where p.user_id = v_user and p.photo is not null
      union
      select j.snapshot ->> 'photo', 'profile' from public.journeys j
        where j.user_id = v_user and j.snapshot ->> 'photo' is not null
    )
    select e.path, e.kind, o.id is not null, (o.metadata ->> 'size')::bigint
    from expected e
    left join storage.objects o
      on o.bucket_id = 'photos' and o.name = v_user::text || '/' || e.path
    order by e.path;
end $$;

-- Files in the caller's folder that no record refers to (left behind by
-- an interrupted save or delete). Clients may remove them.
create function public.orphan_files() returns table (path text, size bigint)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_user uuid := private.require_member();
  v_prefix text := v_user::text || '/';
begin
  return query
    select substr(o.name, length(v_prefix) + 1), (o.metadata ->> 'size')::bigint
    from storage.objects o
    where o.bucket_id = 'photos' and o.name like v_prefix || '%'
      and substr(o.name, length(v_prefix) + 1) not in (
        select ph.file from public.photos ph where ph.user_id = v_user
        union select ph.thumb from public.photos ph where ph.user_id = v_user
        union select p.photo from public.profiles p
          where p.user_id = v_user and p.photo is not null
        union select j.snapshot ->> 'photo' from public.journeys j
          where j.user_id = v_user and j.snapshot ->> 'photo' is not null)
    order by 1;
end $$;

revoke execute on function public.archive_files(), public.orphan_files() from public, anon;
grant execute on function public.archive_files(), public.orphan_files() to authenticated;
