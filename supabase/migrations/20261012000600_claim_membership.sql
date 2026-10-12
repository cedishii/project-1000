-- Self sign-up for approved emails: the owner approves an email address
-- (create_invitation; the token isn't needed for this path), the friend
-- signs up on the website with their own password, confirms their email,
-- and the app calls claim_membership() after sign-in.
--
-- Proof of identity is the confirmed email address (Supabase sends the
-- confirmation link), so only the person who controls that inbox can
-- claim it. The same pending/expiry/revocation rules apply.
-- Returns 'accepted', 'already_member', 'not_invited' or 'not_signed_in'.
create function public.claim_membership() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_confirmed timestamptz;
  v_invitation uuid;
begin
  if v_user is null then
    return 'not_signed_in';
  end if;
  if exists (select 1 from public.members where user_id = v_user) then
    return 'already_member';
  end if;
  select lower(email), email_confirmed_at into v_email, v_confirmed
    from auth.users where id = v_user;
  if v_confirmed is null then
    return 'not_invited';
  end if;
  update private.invitations
    set status = 'accepted', accepted_by = v_user, accepted_at = now()
    where email = v_email and status = 'pending' and expires_at > now()
    returning id into v_invitation;
  if v_invitation is null then
    return 'not_invited';
  end if;
  insert into public.members (user_id, role, status, invitation_id)
    values (v_user, 'member', 'active', v_invitation);
  return 'accepted';
end $$;

revoke execute on function public.claim_membership() from public, anon;
grant execute on function public.claim_membership() to authenticated;
