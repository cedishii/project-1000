-- Live security smoke test for a real Supabase project. Leaves no trace:
-- everything runs in one transaction that is rolled back at the end (or
-- aborted at the first failure).
--
--   supabase db query --linked -f supabase/tests/live_smoke.sql
--
-- It acts as the existing owner and as throwaway accounts through the real
-- `authenticated` / `anon` roles and Supabase's own auth.uid(), RLS and
-- storage policies. Any failed check raises 'SMOKE FAIL: …'. On success
-- the last result is 'SMOKE OK'.

begin;

-- Throwaway accounts (rolled back).
insert into auth.users (id, email, email_confirmed_at, aud, role) values
  ('5e000000-0000-4000-8000-00000000000a', 'p1000-smoke-a@example.test', now(), 'authenticated', 'authenticated'),
  ('5e000000-0000-4000-8000-00000000000b', 'p1000-smoke-b@example.test', now(), 'authenticated', 'authenticated'),
  ('5e000000-0000-4000-8000-00000000000c', 'p1000-smoke-stranger@example.test', now(), 'authenticated', 'authenticated');

create temporary table smoke (k text primary key, v text) on commit drop;
grant all on smoke to authenticated, anon;
insert into smoke values ('owner', (select user_id::text from public.members where role = 'owner'));

do $$ begin
  if (select v from smoke where k = 'owner') is null then
    raise exception 'SMOKE FAIL: no owner (run private.bootstrap_owner first)';
  end if;
end $$;

-- ---- owner invites a and b -------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from smoke where k = 'owner'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into smoke select 'token_a', token from public.create_invitation('p1000-smoke-a@example.test');
insert into smoke select 'token_b', token from public.create_invitation('p1000-smoke-b@example.test');
reset role;

-- ---- a and b redeem; the stranger can't use a's token -----------------------
select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if public.redeem_invitation((select v from smoke where k = 'token_a')) <> 'invalid' then
    raise exception 'SMOKE FAIL: stranger redeemed someone else''s invitation';
  end if;
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if public.redeem_invitation((select v from smoke where k = 'token_a')) <> 'accepted' then
    raise exception 'SMOKE FAIL: a could not redeem';
  end if;
  if public.redeem_invitation((select v from smoke where k = 'token_a')) <> 'already_member' then
    raise exception 'SMOKE FAIL: second redeem';
  end if;
end $$;
-- a creates private data.
select public.add_item('5e000000-0000-4000-8000-0000000000a1', 'a''s private thing', '');
select public.set_item_completed('5e000000-0000-4000-8000-0000000000a1', true, '2026-10-12');
select public.set_item_completed('5e000000-0000-4000-8000-0000000000a1', true, '2026-10-12');
select public.save_memory(jsonb_build_object(
  'id', '5e000000-0000-4000-8000-0000000000a2', 'itemId', '5e000000-0000-4000-8000-0000000000a1',
  'title', '', 'text', 'a''s private memory', 'date', '2026-10-12', 'location', '',
  'hashtags', '["smoke"]'::jsonb, 'photos', jsonb_build_array(jsonb_build_object(
    'id', '5e000000-0000-4000-8000-0000000000a3',
    'file', 'photos/5e000000-0000-4000-8000-0000000000a3.jpg',
    'thumb', 'thumbs/5e000000-0000-4000-8000-0000000000a3.jpg'))));
insert into public.profiles (user_id, name, bio) values (auth.uid(), 'A', 'a''s secret bio');
insert into storage.objects (bucket_id, name, owner)
  values ('photos', '5e000000-0000-4000-8000-00000000000a/photos/5e000000-0000-4000-8000-0000000000a3.jpg', auth.uid());
do $$ begin
  if (select exp from public.journey_progress) <> 1000 then
    raise exception 'SMOKE FAIL: completing twice did not give exactly 1,000 EXP';
  end if;
  if (select count(*) from public.items) <> 1 or (select count(*) from storage.objects) <> 1 then
    raise exception 'SMOKE FAIL: a cannot see own data';
  end if;
  begin
    insert into storage.objects (bucket_id, name)
      values ('photos', '5e000000-0000-4000-8000-00000000000b/photos/planted.jpg');
    raise exception 'SMOKE FAIL: a wrote into b''s storage folder';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.members set role = 'owner' where user_id = auth.uid();
    raise exception 'SMOKE FAIL: a changed own role';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  if public.redeem_invitation((select v from smoke where k = 'token_b')) <> 'accepted' then
    raise exception 'SMOKE FAIL: b could not redeem';
  end if;
end $$;
reset role;

-- ---- b, the owner and the stranger can't touch a's data ---------------------
create function pg_temp.attack(p_who text) returns void language plpgsql as $$
begin
  if (select count(*) from public.items where id = '5e000000-0000-4000-8000-0000000000a1') > 0
     or (select count(*) from public.memories) > 0 and exists (
          select 1 from public.memories where body like 'a''s private%')
     or exists (select 1 from public.profiles where bio = 'a''s secret bio')
     or exists (select 1 from storage.objects where name like '5e000000-0000-4000-8000-00000000000a/%')
  then
    raise exception 'SMOKE FAIL: % can read a''s data', p_who;
  end if;
  begin
    perform public.update_item('5e000000-0000-4000-8000-0000000000a1', 'pwned', '');
    raise exception 'SMOKE FAIL: % edited a''s item', p_who;
  exception when sqlstate 'PT404' or sqlstate 'PT403' then null;
  end;
  begin
    perform public.set_item_completed('5e000000-0000-4000-8000-0000000000a1', false);
    raise exception 'SMOKE FAIL: % changed a''s completion', p_who;
  exception when sqlstate 'PT404' or sqlstate 'PT403' then null;
  end;
  begin
    if (public.delete_item('5e000000-0000-4000-8000-0000000000a1') ->> 'deleted')::boolean then
      raise exception 'SMOKE FAIL: % deleted a''s item', p_who;
    end if;
  exception when sqlstate 'PT403' then null;
  end;
  begin
    update public.items set title = 'pwned';
    raise exception 'SMOKE FAIL: % wrote items directly', p_who;
  exception when insufficient_privilege then null;
  end;
  update public.profiles set bio = 'pwned' where bio = 'a''s secret bio';
  begin
    perform public.export_archive();
  exception when sqlstate 'PT403' then null;
  end;
  if position('a''s private' in coalesce((select public.export_archive()::text
       where private.is_active_member()), '')) > 0 then
    raise exception 'SMOKE FAIL: % export leaks a''s data', p_who;
  end if;
end $$;
grant execute on function pg_temp.attack(text) to authenticated;

select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.attack('member b');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select v from smoke where k = 'owner'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.attack('the owner');
reset role;

select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.attack('a stranger');
reset role;

-- ---- anonymous ---------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $$ begin
  begin
    perform 1 from public.items;
    raise exception 'SMOKE FAIL: anon can read items';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.redeem_invitation('x');
    raise exception 'SMOKE FAIL: anon can call functions';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ---- owner disables b: b loses access ------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from smoke where k = 'owner'), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.set_member_status('5e000000-0000-4000-8000-00000000000b', 'disabled');
reset role;
select set_config('request.jwt.claims', '{"sub":"5e000000-0000-4000-8000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$ begin
  begin
    perform public.add_item(gen_random_uuid(), 'x', '');
    raise exception 'SMOKE FAIL: disabled member can still write';
  exception when sqlstate 'PT403' then null;
  end;
end $$;
reset role;

-- ---- a's data is unchanged -------------------------------------------------
do $$ begin
  if (select title from public.items where id = '5e000000-0000-4000-8000-0000000000a1') <> 'a''s private thing'
     or (select bio from public.profiles where user_id = '5e000000-0000-4000-8000-00000000000a') <> 'a''s secret bio'
     or not (select is_completed from public.items where id = '5e000000-0000-4000-8000-0000000000a1')
  then
    raise exception 'SMOKE FAIL: a''s data was changed';
  end if;
end $$;

select 'SMOKE OK' as result;
rollback;
