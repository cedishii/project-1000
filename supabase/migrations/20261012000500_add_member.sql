-- Lets the owner admit an account directly, without an invitation token:
-- create the user in the dashboard (Authentication → Users → Add user),
-- then run in the SQL editor (as `postgres`):
--   select private.add_member('friend@example.com');
-- Not callable through the API. Re-enables a disabled member; never
-- changes the owner.
create function private.add_member(p_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid;
begin
  select id into v_user from auth.users
    where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'No account uses that email. Create the user first (Authentication → Users → Add user).';
  end if;
  if exists (select 1 from public.members where user_id = v_user and role = 'owner') then
    raise exception 'That account is the owner.';
  end if;
  insert into public.members (user_id, role, status)
    values (v_user, 'member', 'active')
    on conflict (user_id) do update
      set status = 'active', status_changed_at = now();
  return v_user;
end $$;
revoke execute on function private.add_member(text) from public;
