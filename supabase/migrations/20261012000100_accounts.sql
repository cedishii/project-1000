-- Project: 1000 cloud accounts: one Owner and invited Members.
--
-- * Anyone may hold a Supabase Auth login, but only a row in
--   public.members (status 'active') gives access to any data. Members
--   can only be created by redeeming an invitation (or, once, by the
--   owner bootstrap run from the SQL editor).
-- * Roles are never writable by users: public.members has no write
--   policies and API roles have no write privileges on it.
-- * Being the Owner does NOT give access to other people's archives. It
--   only allows managing invitations and members.
--
-- See docs/CLOUD.md.

create schema if not exists private;
revoke all on schema private from public;
-- Row-level security policies call private.is_active_member(), which runs
-- as the requesting role, so that role needs to see the schema.
grant usage on schema private to authenticated;

-- ------------------------------------------------------------------ members

create table public.members (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  role              text not null check (role in ('owner', 'member')),
  status            text not null default 'active'
                    check (status in ('active', 'disabled')),
  invitation_id     uuid,
  created_at        timestamptz not null default now(),
  status_changed_at timestamptz
);

-- There is exactly zero or one owner.
create unique index members_one_owner on public.members (role)
  where role = 'owner';

alter table public.members enable row level security;

-- A signed-in user may see their own membership (to know their role).
create policy members_select_own on public.members
  for select to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.members from anon;
revoke insert, update, delete, truncate on public.members from authenticated;

-- -------------------------------------------------------------- invitations

-- Not exposed through the API at all (private schema). Only the raw
-- token's SHA-256 is stored; the token itself is shown to the owner once.
create table private.invitations (
  id          uuid primary key default gen_random_uuid(),
  email       text not null
              check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+$'),
  token_hash  text not null unique,
  status      text not null default 'pending'
              check (status in ('pending', 'accepted', 'revoked')),
  invited_by  uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  accepted_by uuid references auth.users (id) on delete set null,
  accepted_at timestamptz,
  revoked_at  timestamptz
);

-- One open invitation per email address.
create unique index invitations_one_pending on private.invitations (email)
  where status = 'pending';

-- Failed redemption attempts, for rate limiting.
create table private.redeem_attempts (
  user_id      uuid not null,
  attempted_at timestamptz not null default now()
);
create index redeem_attempts_user on private.redeem_attempts (user_id, attempted_at);

alter table private.invitations enable row level security;
alter table private.redeem_attempts enable row level security;

-- ------------------------------------------------------------------ helpers

create function private.is_active_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m
    where m.user_id = (select auth.uid()) and m.status = 'active'
  )
$$;

create function private.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m
    where m.user_id = (select auth.uid())
      and m.role = 'owner' and m.status = 'active'
  )
$$;

-- The caller's user id if they are an active member; otherwise the
-- request fails with HTTP 403.
create function private.require_member() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_active_member() then
    raise exception using errcode = 'PT403', message = 'not_a_member';
  end if;
  return auth.uid();
end $$;

create function private.require_owner() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_owner() then
    raise exception using errcode = 'PT403', message = 'owner_only';
  end if;
  return auth.uid();
end $$;

create function private.token_hash(token text) returns text
language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(coalesce(token, ''), 'UTF8')), 'hex')
$$;

revoke execute on all functions in schema private from public;
grant execute on function private.is_active_member() to authenticated;

-- ---------------------------------------------------------- owner bootstrap

-- Makes an existing account the owner. Run it once from the Supabase SQL
-- editor (as `postgres`) after signing up:
--   select private.bootstrap_owner('you@example.com');
-- Not callable through the API.
create function private.bootstrap_owner(p_email text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid;
begin
  if exists (select 1 from public.members where role = 'owner') then
    raise exception 'An owner already exists.';
  end if;
  select id into v_user from auth.users
    where lower(email) = lower(btrim(p_email));
  if v_user is null then
    raise exception 'No account uses that email. Sign up first, then run this again.';
  end if;
  insert into public.members (user_id, role, status)
    values (v_user, 'owner', 'active')
    on conflict (user_id) do update
      set role = 'owner', status = 'active', status_changed_at = now();
  return v_user;
end $$;
revoke execute on function private.bootstrap_owner(text) from public;

-- ------------------------------------------------------------- owner API

-- Creates an invitation for one email address and returns the token. The
-- token is returned only here, once; share it with the invitee privately.
-- An earlier open invitation for the same email is revoked.
create function public.create_invitation(
  p_email text,
  p_valid_for interval default interval '7 days'
) returns table (invitation_id uuid, token text, expires_at timestamptz)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_owner uuid := private.require_owner();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_token text;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+$' or length(v_email) > 254 then
    raise exception using errcode = 'PT422', message = 'invalid_email';
  end if;
  if p_valid_for is null or p_valid_for < interval '1 hour'
     or p_valid_for > interval '30 days' then
    raise exception using errcode = 'PT422', message = 'invalid_validity';
  end if;
  if exists (
    select 1 from public.members m join auth.users u on u.id = m.user_id
    where lower(u.email) = v_email
  ) then
    raise exception using errcode = 'PT409', message = 'already_member';
  end if;

  update private.invitations i
    set status = 'revoked', revoked_at = now()
    where i.email = v_email and i.status = 'pending';

  -- 244 random bits from two v4 UUIDs (gen_random_uuid uses a CSPRNG).
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  return query
    insert into private.invitations as i (email, token_hash, invited_by, expires_at)
    values (v_email, private.token_hash(v_token), v_owner, now() + p_valid_for)
    returning i.id, v_token, i.expires_at;
end $$;

create function public.revoke_invitation(p_invitation_id uuid) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  n int;
begin
  perform private.require_owner();
  update private.invitations
    set status = 'revoked', revoked_at = now()
    where id = p_invitation_id and status = 'pending';
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- Invitations without their token hashes. 'expired' is derived.
create function public.list_invitations()
returns table (
  invitation_id uuid, email text, status text,
  created_at timestamptz, expires_at timestamptz, accepted_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return query
    select i.id, i.email,
      case when i.status = 'pending' and i.expires_at <= now()
           then 'expired' else i.status end,
      i.created_at, i.expires_at, i.accepted_at
    from private.invitations i
    order by i.created_at desc;
end $$;

-- Accounts and their status. Never any of their archive data.
create function public.list_members()
returns table (
  user_id uuid, email text, role text, status text,
  created_at timestamptz, status_changed_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_owner();
  return query
    select m.user_id, u.email, m.role, m.status, m.created_at, m.status_changed_at
    from public.members m join auth.users u on u.id = m.user_id
    order by m.created_at;
end $$;

-- Disables (revokes) or re-enables a member. A disabled member keeps
-- their data but every request for it is refused from the next request
-- on. The owner can't be disabled.
create function public.set_member_status(p_user_id uuid, p_status text)
returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  n int;
begin
  perform private.require_owner();
  if p_status not in ('active', 'disabled') then
    raise exception using errcode = 'PT422', message = 'invalid_status';
  end if;
  update public.members
    set status = p_status, status_changed_at = now()
    where user_id = p_user_id and role = 'member' and status <> p_status;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ------------------------------------------------------------ invitee API

-- Called by a signed-in invitee (whose email is confirmed and matches the
-- invitation) to become a member. Returns one of:
--   'accepted', 'already_member', 'invalid', 'rate_limited',
--   'not_signed_in'.
-- 'invalid' covers wrong, expired, revoked, used and other-email tokens
-- alike, so nothing can be learned by guessing.
create function public.redeem_invitation(p_token text) returns text
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
  if (select count(*) from private.redeem_attempts
      where user_id = v_user and attempted_at > now() - interval '1 hour') >= 5 then
    return 'rate_limited';
  end if;

  select lower(email), email_confirmed_at into v_email, v_confirmed
    from auth.users where id = v_user;

  -- The row lock taken by UPDATE makes acceptance single-use even when
  -- two requests race.
  update private.invitations
    set status = 'accepted', accepted_by = v_user, accepted_at = now()
    where token_hash = private.token_hash(p_token)
      and status = 'pending'
      and expires_at > now()
      and email = v_email
      and v_confirmed is not null
    returning id into v_invitation;

  if v_invitation is null then
    insert into private.redeem_attempts (user_id) values (v_user);
    return 'invalid';
  end if;

  insert into public.members (user_id, role, status, invitation_id)
    values (v_user, 'member', 'active', v_invitation);
  return 'accepted';
end $$;

-- ------------------------------------------------- optional sign-up gate

-- Supabase Auth "Before User Created" hook: refuses sign-ups for email
-- addresses without an open invitation. Enable it in the dashboard
-- (Authentication → Hooks) AFTER the owner account exists. Without it,
-- strangers can create a login but still can't reach any data.
create function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_email text := lower(btrim(coalesce(event -> 'user' ->> 'email', '')));
begin
  if exists (
    select 1 from private.invitations
    where email = v_email and status = 'pending' and expires_at > now()
  ) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Project: 1000 is invite-only. Ask the owner for an invitation.'
  ));
end $$;

-- ------------------------------------------------------------ privileges

revoke execute on function
  public.create_invitation(text, interval),
  public.revoke_invitation(uuid),
  public.list_invitations(),
  public.list_members(),
  public.set_member_status(uuid, text),
  public.redeem_invitation(text),
  public.hook_before_user_created(jsonb)
from public, anon;

grant execute on function
  public.create_invitation(text, interval),
  public.revoke_invitation(uuid),
  public.list_invitations(),
  public.list_members(),
  public.set_member_status(uuid, text),
  public.redeem_invitation(text)
to authenticated;

revoke execute on function public.hook_before_user_created(jsonb) from authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
