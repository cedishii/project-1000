"""Security and behaviour tests for the Project: 1000 Supabase schema.

Every test runs SQL exactly as the API would: as the `authenticated` (or
`anon`) role with the JWT claims PostgREST sets, so row-level security,
grants and the API functions are exercised for real.

Two ways to run:

  # Plain PostgreSQL (no Supabase, no Docker). Applies a small stub of
  # Supabase's auth/storage schemas first (tests/supabase_stub.sql).
  python supabase/tests/run_tests.py --stub --dsn postgresql://postgres@127.0.0.1:5432/postgres

  # A local Supabase stack (`supabase start`, default port 54322); the
  # migrations are applied by `supabase db reset` beforehand.
  python supabase/tests/run_tests.py --dsn postgresql://postgres:postgres@127.0.0.1:54322/postgres

Requires: pip install pg8000. With --stub each test gets a fresh
database; without it, tests use fresh random users in the existing one and
clean up after themselves. Never point this at a production database.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import sys
import traceback
import uuid
from urllib.parse import urlparse

import pg8000.native as pg

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURE = os.path.join(HERE, "fixtures", "archive_v2.json")


# ----------------------------------------------------------------- plumbing

class DbError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class Db:
    """One database connection with helpers to act as a user or as admin."""

    def __init__(self, dsn: str, database: str | None = None):
        u = urlparse(dsn)
        self.conn = pg.Connection(
            u.username or "postgres",
            password=u.password,
            host=u.hostname or "127.0.0.1",
            port=u.port or 5432,
            database=database or (u.path.lstrip("/") or "postgres"),
        )

    def admin(self, sql: str, **params):
        """Runs as the database owner (like the Supabase SQL editor)."""
        try:
            return self.conn.run(sql, **params)
        except pg.DatabaseError as e:
            raise _err(e) from None

    def as_user(self, user_id: str | None, sql: str, **params):
        """Runs one statement as `authenticated` user_id (or `anon` if None)
        in its own transaction, like one API request."""
        self.conn.run("begin")
        try:
            if user_id is None:
                self.conn.run("set local role anon")
                self.conn.run("select set_config('request.jwt.claims', :c, true)",
                              c=json.dumps({"role": "anon"}))
            else:
                self.conn.run("set local role authenticated")
                self.conn.run("select set_config('request.jwt.claims', :c, true)",
                              c=json.dumps({"sub": user_id, "role": "authenticated"}))
            rows = self.conn.run(sql, **params)
            self.conn.run("commit")
            return rows
        except pg.DatabaseError as e:
            self.conn.run("rollback")
            raise _err(e) from None

    def close(self):
        self.conn.close()


def _err(e: pg.DatabaseError) -> DbError:
    info = e.args[0] if e.args and isinstance(e.args[0], dict) else {}
    return DbError(info.get("C", "?"), info.get("M", str(e)))


def expect_error(fn, code: str | None = None, message: str | None = None):
    try:
        fn()
    except DbError as e:
        if code and e.code != code:
            raise AssertionError(f"expected error {code}, got {e.code}: {e.message}")
        if message and e.message != message:
            raise AssertionError(f"expected message {message!r}, got {e.message!r}")
        return e
    raise AssertionError(f"expected an error ({code} {message}), but it succeeded")


def eq(actual, expected, what=""):
    if actual != expected:
        raise AssertionError(f"{what}: expected {expected!r}, got {actual!r}")


class World:
    """Accounts for one test: an owner and helpers to add members."""

    def __init__(self, db: Db):
        self.db = db
        self.users: list[str] = []
        self.owner = self.new_user("owner")
        db.admin("select private.bootstrap_owner(:e)", e=self.email_of[self.owner])

    @property
    def email_of(self):
        if not hasattr(self, "_emails"):
            self._emails = {}
        return self._emails

    def new_user(self, name: str, confirmed: bool = True) -> str:
        uid = str(uuid.uuid4())
        email = f"{name}-{uid[:8]}@example.test"
        self.db.admin(
            "insert into auth.users (id, email, email_confirmed_at) values (:i, :e, "
            + ("now()" if confirmed else "null") + ")",
            i=uid, e=email)
        self.users.append(uid)
        self.email_of[uid] = email
        return uid

    def invite(self, email: str, valid: str = "7 days") -> str:
        rows = self.db.as_user(
            self.owner,
            "select token from public.create_invitation(:e, cast(:v as interval))",
            e=email, v=valid)
        return rows[0][0]

    def new_member(self, name: str) -> str:
        uid = self.new_user(name)
        token = self.invite(self.email_of[uid])
        eq(self.db.as_user(uid, "select public.redeem_invitation(:t)", t=token)[0][0],
           "accepted", "redeem")
        return uid

    def rpc(self, uid, sql, **params):
        return self.db.as_user(uid, sql, **params)

    def cleanup(self):
        # Only used without --stub: remove this test's users and their data.
        for uid in self.users:
            self.db.admin("delete from public.members where user_id = :u", u=uid)
            self.db.admin("delete from auth.users where id = :u", u=uid)


def add_item(w: World, uid: str, title: str, item_id: str | None = None) -> dict:
    item_id = item_id or str(uuid.uuid4())
    row = w.rpc(uid, "select to_jsonb(public.add_item(cast(:i as uuid), :t, ''))",
                i=item_id, t=title)[0][0]
    return row


def save_memory(w: World, uid: str, item_id: str, photos=(), memory_id=None, **fields) -> dict:
    memory = {
        "id": memory_id or str(uuid.uuid4()),
        "itemId": item_id,
        "title": fields.get("title", ""),
        "text": fields.get("text", "a memory"),
        "date": fields.get("date", "2026-10-12"),
        "location": fields.get("location", ""),
        "hashtags": fields.get("hashtags", []),
        "photos": list(photos),
    }
    if "expectedRevision" in fields:
        memory["expectedRevision"] = fields["expectedRevision"]
    return w.rpc(uid, "select public.save_memory(cast(:m as jsonb))", m=json.dumps(memory))[0][0]


def photo(pid: str | None = None) -> dict:
    pid = pid or str(uuid.uuid4())
    return {"id": pid, "file": f"photos/{pid}.jpg", "thumb": f"thumbs/{pid}.jpg",
            "width": 100, "height": 80, "createdAt": "2026-10-12T00:00:00Z"}


def count(w: World, uid, table: str) -> int:
    return w.rpc(uid, f"select count(*) from public.{table}")[0][0]


# -------------------------------------------------------------------- tests

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


# --- accounts ------------------------------------------------------------

@test
def owner_bootstrap_only_once_and_not_through_api(w: World):
    other = w.new_user("other")
    expect_error(lambda: w.db.admin("select private.bootstrap_owner(:e)", e=w.email_of[other]))
    # The API roles can't call it at all.
    expect_error(lambda: w.rpc(other, "select private.bootstrap_owner(:e)", e=w.email_of[other]),
                 "42501")
    eq(w.rpc(w.owner, "select role from public.members where user_id = auth.uid()"),
       [["owner"]], "owner role")


@test
def signed_in_non_member_gets_nothing(w: World):
    add_item(w, w.owner, "owner secret")
    stranger = w.new_user("stranger")
    for t in ["journeys", "items", "memories", "photos", "profiles", "settings", "members",
              "journey_progress"]:
        eq(count(w, stranger, t), 0, f"stranger sees {t}")
    expect_error(lambda: add_item(w, stranger, "x"), "PT403", "not_a_member")
    expect_error(lambda: w.rpc(stranger, "select public.export_archive()"), "PT403")
    expect_error(lambda: w.rpc(stranger, "select public.pull_changes(0)"), "PT403")
    expect_error(lambda: w.rpc(stranger, "insert into public.profiles (user_id, name) "
                                          "values (auth.uid(), 'x')"), "42501")
    expect_error(lambda: w.rpc(stranger, "select * from public.list_members()"), "PT403")


@test
def anonymous_requests_are_refused(w: World):
    add_item(w, w.owner, "owner secret")
    for t in ["journeys", "items", "memories", "photos", "profiles", "settings", "members",
              "journey_progress"]:
        expect_error(lambda: w.rpc(None, f"select * from public.{t}"), "42501")
    expect_error(lambda: w.rpc(None, "select public.add_item(gen_random_uuid(), 'x', '')"), "42501")
    expect_error(lambda: w.rpc(None, "select public.redeem_invitation('x')"), "42501")
    expect_error(lambda: w.rpc(None, "select * from public.create_invitation('a@b.c')"), "42501")
    expect_error(lambda: w.rpc(None, "select public.hook_before_user_created('{}')"), "42501")


@test
def private_schema_tables_are_not_reachable(w: World):
    m = w.new_member("m")
    w.invite("someone@example.test")
    for uid in [w.owner, m]:
        for t in ["invitations", "redeem_attempts", "revisions", "deletions"]:
            expect_error(lambda: w.rpc(uid, f"select * from private.{t}"), "42501")


@test
def invitation_token_is_stored_only_as_a_hash(w: World):
    token = w.invite("friend@example.test")
    eq(len(token), 64, "token length")
    rows = w.db.admin("select token_hash, email from private.invitations")
    eq(len(rows), 1, "one invitation")
    assert rows[0][0] != token and token not in json.dumps(rows), "raw token stored"
    eq(rows[0][0], w.db.admin("select private.token_hash(:t)", t=token)[0][0], "hash")
    listed = w.rpc(w.owner, "select to_jsonb(l) from public.list_invitations() l")
    assert "token" not in json.dumps(listed) or token not in json.dumps(listed)
    eq(listed[0][0]["status"], "pending", "listed status")


@test
def only_the_owner_manages_invitations_and_members(w: World):
    m = w.new_member("m")
    expect_error(lambda: w.rpc(m, "select * from public.create_invitation('x@example.test')"),
                 "PT403", "owner_only")
    expect_error(lambda: w.rpc(m, "select * from public.list_invitations()"), "PT403")
    expect_error(lambda: w.rpc(m, "select * from public.list_members()"), "PT403")
    expect_error(lambda: w.rpc(m, "select public.set_member_status(:u, 'disabled')", u=w.owner),
                 "PT403")
    inv = w.rpc(w.owner, "select invitation_id from public.create_invitation('y@example.test')")[0][0]
    expect_error(lambda: w.rpc(m, "select public.revoke_invitation(:i)", i=str(inv)), "PT403")
    members = w.rpc(w.owner, "select email, role, status from public.list_members()")
    eq(sorted(r[1] for r in members), ["member", "owner"], "member list roles")


@test
def redeem_valid_invitation_once(w: World):
    friend = w.new_user("friend")
    token = w.invite(w.email_of[friend])
    eq(w.rpc(friend, "select public.redeem_invitation(:t)", t=token)[0][0], "accepted", "first")
    eq(w.rpc(friend, "select public.redeem_invitation(:t)", t=token)[0][0], "already_member",
       "again")
    eq(w.db.admin("select count(*) from public.members where user_id = :u", u=friend)[0][0], 1,
       "one membership")
    eq(w.rpc(friend, "select role, status from public.members"), [["member", "active"]], "role")
    # The used token can't admit anyone else.
    other = w.new_user("other")
    eq(w.rpc(other, "select public.redeem_invitation(:t)", t=token)[0][0], "invalid", "reuse")
    eq(w.rpc(w.owner, "select status from public.list_invitations()"), [["accepted"]], "status")


@test
def invalid_expired_revoked_and_wrong_email_invitations_are_rejected(w: World):
    a = w.new_user("a")
    eq(w.rpc(a, "select public.redeem_invitation('nonsense')")[0][0], "invalid", "garbage")

    # Expired.
    token = w.invite(w.email_of[a], "1 hour")
    w.db.admin("update private.invitations set expires_at = now() - interval '1 minute'")
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=token)[0][0], "invalid", "expired")
    eq(w.rpc(w.owner, "select status from public.list_invitations() limit 1")[0][0], "expired",
       "listed as expired")

    # Revoked.
    token = w.invite(w.email_of[a])
    inv = w.db.admin("select id from private.invitations where status = 'pending'")[0][0]
    eq(w.rpc(w.owner, "select public.revoke_invitation(:i)", i=str(inv))[0][0], True, "revoke")
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=token)[0][0], "invalid", "revoked")

    # Someone else's invitation (email bound).
    b = w.new_user("b")
    token = w.invite(w.email_of[b])
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=token)[0][0], "invalid", "other email")

    # Unconfirmed email.
    c = w.new_user("c", confirmed=False)
    token = w.invite(w.email_of[c])
    eq(w.rpc(c, "select public.redeem_invitation(:t)", t=token)[0][0], "invalid", "unconfirmed")

    eq(w.db.admin("select count(*) from public.members where role = 'member'")[0][0], 0,
       "nobody admitted")


@test
def new_invitation_replaces_the_open_one(w: World):
    a = w.new_user("a")
    old = w.invite(w.email_of[a])
    new = w.invite(w.email_of[a])
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=old)[0][0], "invalid", "old")
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=new)[0][0], "accepted", "new")
    expect_error(lambda: w.invite(w.email_of[a]), "PT409", "already_member")
    expect_error(lambda: w.invite("not-an-email"), "PT422", "invalid_email")
    expect_error(lambda: w.invite("x@example.test", "90 days"), "PT422", "invalid_validity")


@test
def redeeming_is_rate_limited(w: World):
    a = w.new_user("a")
    token = w.invite(w.email_of[a])
    for _ in range(5):
        eq(w.rpc(a, "select public.redeem_invitation('guess')")[0][0], "invalid", "guess")
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=token)[0][0], "rate_limited", "limited")
    w.db.admin("update private.redeem_attempts set attempted_at = now() - interval '2 hours'")
    eq(w.rpc(a, "select public.redeem_invitation(:t)", t=token)[0][0], "accepted", "after an hour")


@test
def members_cannot_escalate_their_role(w: World):
    m = w.new_member("m")
    expect_error(lambda: w.rpc(m, "update public.members set role = 'owner' where user_id = auth.uid()"),
                 "42501")
    expect_error(lambda: w.rpc(m, "insert into public.members (user_id, role) values (auth.uid(), 'owner')"),
                 "42501")
    expect_error(lambda: w.rpc(m, "delete from public.members"), "42501")
    stranger = w.new_user("s")
    expect_error(lambda: w.rpc(stranger, "insert into public.members (user_id, role) "
                                          "values (auth.uid(), 'member')"), "42501")
    eq(w.rpc(m, "select role from public.members"), [["member"]], "still member")
    # A member can only ever see their own membership row.
    eq(count(w, m, "members"), 1, "member rows visible")


@test
def disabled_member_loses_access_immediately_and_keeps_data(w: World):
    m = w.new_member("m")
    add_item(w, m, "mine")
    eq(w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=m)[0][0], True, "disable")
    eq(count(w, m, "items"), 0, "disabled member reads")
    expect_error(lambda: add_item(w, m, "more"), "PT403", "not_a_member")
    expect_error(lambda: w.rpc(m, "insert into storage.objects (bucket_id, name) values "
                                  "('photos', auth.uid()::text || '/photos/a.jpg')"), "42501")
    eq(w.db.admin("select count(*) from public.items where user_id = :u", u=m)[0][0], 1, "data kept")
    eq(w.rpc(w.owner, "select public.set_member_status(:u, 'active')", u=m)[0][0], True, "enable")
    eq(count(w, m, "items"), 1, "re-enabled member reads")
    # The owner can't be disabled.
    eq(w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=w.owner)[0][0], False,
       "owner")
    eq(count(w, w.owner, "members"), 1, "owner still active")


@test
def sign_up_hook_allows_only_invited_emails(w: World):
    w.invite("invited@example.test")
    allow = w.db.admin("select public.hook_before_user_created(cast(:e as jsonb))",
                       e=json.dumps({"user": {"email": "Invited@Example.test"}}))[0][0]
    eq(allow, {}, "invited")
    deny = w.db.admin("select public.hook_before_user_created(cast(:e as jsonb))",
                      e=json.dumps({"user": {"email": "random@example.test"}}))[0][0]
    eq(deny["error"]["http_code"], 403, "not invited")
    expect_error(lambda: w.rpc(w.owner, "select public.hook_before_user_created('{}')"), "42501")


@test
def owner_can_add_a_member_directly_from_the_sql_editor(w: World):
    friend = w.new_user("friend")
    eq(str(w.db.admin("select private.add_member(:e)", e=w.email_of[friend].upper())[0][0]), friend,
       "added")
    eq(w.rpc(friend, "select role, status from public.members"), [["member", "active"]], "member")
    add_item(w, friend, "works")
    expect_error(lambda: w.db.admin("select private.add_member(:e)", e=w.email_of[w.owner]))
    expect_error(lambda: w.db.admin("select private.add_member('nobody@example.test')"))
    # Not reachable through the API, not even for the owner.
    expect_error(lambda: w.rpc(w.owner, "select private.add_member(:e)", e="x@example.test"), "42501")
    # Re-running re-enables a disabled member.
    w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=friend)
    w.db.admin("select private.add_member(:e)", e=w.email_of[friend])
    eq(w.rpc(friend, "select status from public.members"), [["active"]], "re-enabled")


@test
def approved_email_can_claim_membership_after_signing_up(w: World):
    w.invite("friend@example.test")  # owner approves the email
    friend = w.new_user("x")
    w.db.admin("update auth.users set email = 'friend@example.test' where id = :u", u=friend)
    eq(w.rpc(friend, "select public.claim_membership()")[0][0], "accepted", "claim")
    eq(w.rpc(friend, "select public.claim_membership()")[0][0], "already_member", "again")
    eq(w.rpc(friend, "select role from public.members"), [["member"]], "member")
    # Not approved, unconfirmed, expired or revoked emails get nothing.
    stranger = w.new_user("stranger")
    eq(w.rpc(stranger, "select public.claim_membership()")[0][0], "not_invited", "stranger")
    unconfirmed = w.new_user("u", confirmed=False)
    w.invite(w.email_of[unconfirmed])
    eq(w.rpc(unconfirmed, "select public.claim_membership()")[0][0], "not_invited", "unconfirmed")
    late = w.new_user("late")
    w.invite(w.email_of[late])
    w.db.admin("update private.invitations set expires_at = now() - interval '1 minute' "
               "where email = :e", e=w.email_of[late])
    eq(w.rpc(late, "select public.claim_membership()")[0][0], "not_invited", "expired")
    expect_error(lambda: w.rpc(None, "select public.claim_membership()"), "42501")


# --- isolation -------------------------------------------------------------

def own_or_forbidden(fn):
    """Result of fn, or None if the caller is refused as a non-member."""
    try:
        return fn()
    except DbError as e:
        if e.code == "PT403":
            return None
        raise


def refused(fn, code, message=None):
    """fn must fail with code — or with 403 if the caller isn't a member."""
    try:
        fn()
    except DbError as e:
        if e.code == "PT403" or (e.code == code and (not message or e.message == message)):
            return
        raise AssertionError(f"expected {code}/PT403, got {e.code}: {e.message}")
    raise AssertionError(f"expected {code}, but it succeeded")


def assert_cannot_touch(w: World, attacker: str, victim: str):
    """attacker must not be able to read or change any of victim's data,
    even knowing every id."""
    tag = uuid.uuid4().hex[:8]  # unique markers, so the attacker's own data never matches
    item = add_item(w, victim, f"victim's private thing {tag}")
    item_id = item["id"]
    ph = photo()
    mem = save_memory(w, victim, item_id, photos=[ph], text=f"private memory {tag}")
    mem_id = mem["memory"]["id"]
    w.rpc(victim, "insert into public.profiles (user_id, name, bio) values (auth.uid(), 'V', :b)",
          b=f"secret {tag}")
    w.rpc(victim, "insert into public.settings (user_id, key, value) values (auth.uid(), 'theme_mode', 'dark')")
    journey = w.rpc(victim, "select id from public.journeys")[0][0]
    w.db.admin("insert into storage.objects (bucket_id, name, metadata) values "
               "('photos', :n, '{\"size\": 3}')", n=f"{victim}/{ph['file']}")

    before = w.rpc(victim, "select public.export_archive()")[0][0]

    # Reads.
    for t in ["journeys", "items", "memories", "photos", "profiles", "settings", "journey_progress"]:
        eq(w.rpc(attacker, f"select count(*) from public.{t} where user_id = :v", v=victim)[0][0], 0,
           f"attacker reads victim {t}")
    eq(w.rpc(attacker, "select count(*) from public.items where id = :i", i=item_id)[0][0], 0, "by id")
    # The whole-archive functions return only the caller's own data (or
    # refuse a non-member outright).
    for sql in ["select public.export_archive()", "select public.pull_changes(0)",
                "select to_jsonb(f) from public.archive_files() f"]:
        out = json.dumps(own_or_forbidden(lambda: w.rpc(attacker, sql)))
        for secret in [item_id, mem_id, ph["id"], tag]:
            assert secret not in out, f"{sql} leaks {secret}"
    eq(w.rpc(attacker, "select count(*) from storage.objects where name like :p", p=f"{victim}/%")[0][0],
       0, "storage read")

    # Writes through the API, by id.
    refused(lambda: w.rpc(attacker, "select public.update_item(:i, 'pwned', '')", i=item_id),
            "PT404")
    refused(lambda: w.rpc(attacker, "select public.set_item_completed(:i, true)", i=item_id),
            "PT404")
    refused(lambda: add_item(w, attacker, "dup", item_id=item_id), "PT409", "id_conflict")
    refused(lambda: save_memory(w, attacker, item_id, text="x"), "PT404")
    refused(lambda: save_memory(w, attacker, item_id, memory_id=mem_id, text="x"), "PT404")
    refused(lambda: w.rpc(attacker, "select public.save_order(array[cast(:i as uuid)])", i=item_id),
            "PT409")
    # Deleting someone else's records reports "nothing deleted".
    for fn_name, rid in [("delete_item", item_id), ("delete_memory", mem_id)]:
        out = own_or_forbidden(lambda: w.rpc(attacker, f"select public.{fn_name}(:i)", i=rid))
        if out is not None:
            eq(out[0][0]["deleted"], False, fn_name)
    # Stealing a photo id into one's own memory.
    if own_or_forbidden(lambda: w.rpc(attacker, "select 1 where private.is_active_member()")):
        own = add_item(w, attacker, "attacker's")
        expect_error(lambda: save_memory(w, attacker, own["id"], photos=[ph]), "PT409", "id_conflict")

    # Direct table writes.
    for sql in [
        "update public.items set title = 'pwned' where id = :i",
        "delete from public.items where id = :i",
        "insert into public.items (id, user_id, journey_id, number, position, title) "
        "values (gen_random_uuid(), :v, :j, 999, 0, 'planted')",
    ]:
        params = {"i": item_id} if ":i" in sql else {"v": victim, "j": str(journey)}
        expect_error(lambda: w.rpc(attacker, sql, **params), "42501")
    w.rpc(attacker, "update public.profiles set bio = 'pwned' where user_id = :v", v=victim)
    expect_error(lambda: w.rpc(attacker, "insert into public.profiles (user_id, name) values (:v, 'x')",
                               v=victim), "42501")
    w.rpc(attacker, "update public.settings set value = 'light' where user_id = :v", v=victim)
    w.rpc(attacker, "delete from public.settings where user_id = :v", v=victim)
    expect_error(lambda: w.rpc(attacker, "insert into public.settings (user_id, key, value) "
                                         "values (:v, 'theme_mode', 'light')", v=victim), "42501")
    # Moving one's own row into the victim's account.
    # (Refused by RLS or, first, by the trigger that forbids changing owners.)
    if own_or_forbidden(lambda: w.rpc(attacker, "select 1 where private.is_active_member()")):
        w.rpc(attacker, "insert into public.settings (user_id, key, value) "
                        "values (auth.uid(), 'k', 'v') on conflict do nothing")
        e = expect_error(lambda: w.rpc(attacker, "update public.settings set user_id = :v "
                                                 "where key = 'k'", v=victim))
        assert e.code in ("42501", "PT403"), e

    # Storage.
    for name in [f"{victim}/photos/planted.jpg", f"{attacker}/../{victim}/photos/x.jpg",
                 f"{attacker}/other/x.jpg", f"{attacker}/photos/sub/x.jpg"]:
        expect_error(lambda: w.rpc(attacker, "insert into storage.objects (bucket_id, name) "
                                             "values ('photos', :n)", n=name), "42501")
    eq(w.rpc(attacker, "delete from storage.objects where name like :p returning name",
             p=f"{victim}/%") or [], [], "storage delete")

    after = w.rpc(victim, "select public.export_archive()")[0][0]
    eq(after, before, "victim's archive unchanged")
    eq(w.db.admin("select count(*) from storage.objects where name like :p", p=f"{victim}/%")[0][0],
       1, "victim's file kept")


@test
def member_cannot_touch_owner_data(w: World):
    assert_cannot_touch(w, w.new_member("m"), w.owner)


@test
def member_cannot_touch_another_member(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    assert_cannot_touch(w, a, b)
    assert_cannot_touch(w, b, a)


@test
def owner_cannot_touch_member_data(w: World):
    assert_cannot_touch(w, w.owner, w.new_member("m"))


@test
def stranger_cannot_touch_member_data(w: World):
    assert_cannot_touch(w, w.new_user("stranger"), w.new_member("m"))


@test
def own_storage_folder_works(w: World):
    m = w.new_member("m")
    for folder in ["photos", "thumbs", "profile"]:
        w.rpc(m, "insert into storage.objects (bucket_id, name) values ('photos', :n)",
              n=f"{m}/{folder}/a.jpg")
    eq(w.rpc(m, "select count(*) from storage.objects")[0][0], 3, "own files visible")
    eq(len(w.rpc(m, "delete from storage.objects where name = :n returning 1",
                 n=f"{m}/photos/a.jpg")), 1, "delete own")
    bucket = w.db.admin("select public, file_size_limit from storage.buckets where id = 'photos'")
    eq(bucket, [[False, 52428800]], "private bucket with size limit")


# --- behaviour -------------------------------------------------------------

@test
def numbering_follows_the_phone(w: World):
    u = w.new_member("m")
    a, b, c = (add_item(w, u, t) for t in ["a", "b", "c"])
    eq([a["number"], b["number"], c["number"]], [1, 2, 3], "numbers")
    eq([a["position"], b["position"], c["position"]], [0, 1, 2], "positions")
    w.rpc(u, "select public.delete_item(:i)", i=b["id"])
    d = add_item(w, u, "d")
    eq((d["number"], d["position"]), (2, 3), "lowest free number, at the end")
    # Titles are trimmed like Dart's trim(); empty titles are refused.
    eq(add_item(w, u, "  \n spaced \t ")["title"], "spaced", "trim")
    expect_error(lambda: add_item(w, u, "   "), "PT422", "title_required")


@test
def retrying_add_item_does_not_duplicate(w: World):
    u = w.new_member("m")
    item_id = str(uuid.uuid4())
    first = add_item(w, u, "once", item_id)
    again = add_item(w, u, "once", item_id)
    eq(again, first, "same item returned")
    eq(count(w, u, "items"), 1, "one item")


@test
def list_is_limited_to_1000(w: World):
    u = w.new_member("m")
    w.rpc(u, "select count(public.add_item(gen_random_uuid(), 'thing ' || n, '')) "
             "from generate_series(1, 1000) n")
    eq(w.rpc(u, "select count(*), min(number), max(number) from public.items")[0], [1000, 1, 1000],
       "1000 items")
    expect_error(lambda: add_item(w, u, "one too many"), "PT409", "list_full")


@test
def completion_is_idempotent_and_exp_is_derived(w: World):
    u = w.new_member("m")
    item = add_item(w, u, "a")
    for _ in range(3):  # double taps, retries, a second device
        w.rpc(u, "select public.set_item_completed(:i, true, '2026-10-01')", i=item["id"])
    p = w.rpc(u, "select completed_count, exp, level from public.journey_progress")[0]
    eq(p, [1, 1000, 0], "one completion = 1,000 EXP once")
    rev = w.rpc(u, "select revision from public.items")[0][0]
    w.rpc(u, "select public.set_item_completed(:i, true, '2026-10-01')", i=item["id"])
    eq(w.rpc(u, "select revision from public.items")[0][0], rev, "no-op does not bump revision")
    # Un-completing keeps the date on record.
    row = w.rpc(u, "select to_jsonb(public.set_item_completed(:i, false))", i=item["id"])[0][0]
    eq((row["is_completed"], row["completed_on"]), (False, "2026-10-01"), "history kept")
    eq(w.rpc(u, "select exp from public.journey_progress")[0][0], 0, "EXP follows the list")


@test
def progression_matches_the_app_formula(w: World):
    u = w.new_member("m")
    rows = w.rpc(u, "select p.* from generate_series(-5, 1005) n, public.progression(n) p")
    for completed, exp, level, into, to_next, remaining, done in rows:
        n = max(0, min(completed, 1000))
        # lib/data/progression.dart
        e = n * 1000
        lv = min(e // 10000, 100)
        exp_into = 10000 if lv >= 100 else e - lv * 10000
        eq((completed, exp, level, into, to_next, remaining, done),
           (n, e, lv, exp_into, 0 if lv >= 100 else 10000 - exp_into, 1000 - n, n >= 1000),
           f"progression({n})")


@test
def stale_updates_are_refused(w: World):
    u = w.new_member("m")
    item = add_item(w, u, "a")
    seen = item["revision"]
    edited = w.rpc(u, "select to_jsonb(public.update_item(:i, 'phone edit', '', :r))",
                   i=item["id"], r=seen)[0][0]
    # A second device still holding the old revision must not overwrite.
    expect_error(lambda: w.rpc(u, "select public.update_item(:i, 'web edit', '', :r)",
                               i=item["id"], r=seen), "PT409", "stale_revision")
    eq(w.rpc(u, "select title from public.items")[0][0], "phone edit", "newer edit kept")
    w.rpc(u, "select public.update_item(:i, 'web edit', '', :r)", i=item["id"], r=edited["revision"])
    eq(w.rpc(u, "select title from public.items")[0][0], "web edit", "fresh edit applies")


@test
def save_order_requires_the_exact_list(w: World):
    u = w.new_member("m")
    ids = [add_item(w, u, t)["id"] for t in "abc"]
    w.rpc(u, "select public.save_order(cast(:a as uuid[]))", a="{" + ",".join(reversed(ids)) + "}")
    eq(w.rpc(u, "select title from public.items order by position"), [["c"], ["b"], ["a"]], "order")
    eq(w.rpc(u, "select number from public.items order by position"), [[3], [2], [1]],
       "numbers unchanged")
    for bad in [ids[:2], ids + [ids[0]], ids[:2] + [str(uuid.uuid4())]]:
        expect_error(lambda: w.rpc(u, "select public.save_order(cast(:a as uuid[]))",
                                   a="{" + ",".join(bad) + "}"), "PT409", "invalid_order")


@test
def memories_and_photos(w: World):
    u = w.new_member("m")
    item = add_item(w, u, "a")
    p1, p2 = photo(), photo()
    mid = str(uuid.uuid4())
    r = save_memory(w, u, item["id"], photos=[p1, p2], memory_id=mid, hashtags=["travel", "日本"])
    eq(r["removedFiles"], [], "nothing removed")
    # Retrying the same save is harmless.
    save_memory(w, u, item["id"], photos=[p1, p2], memory_id=mid, hashtags=["travel", "日本"])
    eq(count(w, u, "memories"), 1, "one memory")
    eq(count(w, u, "photos"), 2, "two photos")
    # Reorder and remove a photo.
    r = save_memory(w, u, item["id"], photos=[p2], memory_id=mid)
    eq(sorted(r["removedFiles"]), sorted([p1["file"], p1["thumb"]]), "removed files")
    eq(w.rpc(u, "select id::text, position from public.photos"), [[p2["id"], 0]], "positions")
    expect_error(lambda: save_memory(w, u, item["id"], hashtags=["has space"]), "23514")
    expect_error(lambda: save_memory(w, u, item["id"], photos=[{**photo(), "file": "../etc/passwd"}]),
                 "23514")
    r = w.rpc(u, "select public.delete_item(:i)", i=item["id"])[0][0]
    eq(r["files"], [p2["file"], p2["thumb"]], "delete returns files")
    eq((count(w, u, "memories"), count(w, u, "photos")), (0, 0), "cascade")


def complete_journey(w: World, u: str):
    w.rpc(u, "select count(public.add_item(gen_random_uuid(), 'thing ' || n, 'd')) "
             "from generate_series(1, 1000) n")
    w.rpc(u, "select count(public.set_item_completed(id, true, date '2030-01-01' + (number % 30))) "
             "from public.items")


@test
def regress_archives_and_starts_the_next_journey(w: World):
    u = w.new_member("m")
    first = add_item(w, u, "first")
    save_memory(w, u, first["id"], photos=[photo()], text="kept forever")
    expect_error(lambda: w.rpc(u, "select public.start_new_journey('2031-01-01', true)"),
                 "PT409", "journey_not_complete")
    w.rpc(u, "select public.set_item_completed(:i, true, '2029-12-31')", i=first["id"])
    w.rpc(u, "select count(public.add_item(gen_random_uuid(), 'thing ' || n, 'd')) "
             "from generate_series(2, 1000) n")
    w.rpc(u, "select count(public.set_item_completed(id, true, '2030-06-01')) from public.items "
             "where not is_completed")
    w.rpc(u, "select public.set_journey_start('2026-01-01')")  # Journey 1: profile date
    w.rpc(u, "update public.profiles set name = 'Me', bio = 'then'")
    old = w.rpc(u, "select id from public.journeys")[0][0]

    new = w.rpc(u, "select to_jsonb(public.start_new_journey('2031-01-01', true, "
                   "'profile/copy.jpg', :j))", j=str(old))[0][0]
    eq((new["number"], new["status"], new["started_on"]), (2, "active", "2031-01-01"), "new journey")
    # A retry of the same request returns the new journey, not a third one.
    again = w.rpc(u, "select to_jsonb(public.start_new_journey('2031-01-01', true, "
                     "'profile/copy.jpg', :j))", j=str(old))[0][0]
    eq(again["id"], new["id"], "idempotent retry")
    eq(count(w, u, "journeys"), 2, "two journeys")

    archived = w.rpc(u, "select to_jsonb(j) from public.journeys j where number = 1")[0][0]
    eq((archived["status"], archived["started_on"], archived["completed_on"]),
       ("archived", "2026-01-01", "2030-06-01"), "archived journey")
    eq(archived["snapshot"]["name"], "Me", "snapshot")
    eq(archived["snapshot"]["photo"], "profile/copy.jpg", "snapshot photo")
    prog = w.rpc(u, "select number, completed_count, memory_count, level from public.journey_progress "
                    "order by number")
    eq(prog, [[1, 1000, 1, 100], [2, 0, 0, 0]], "history kept, new journey from zero")
    eq(w.rpc(u, "select count(*), bool_or(is_completed) from public.items i "
                "where journey_id = :j", j=new["id"])[0], [1000, False], "reused list, not completed")
    # The archived journey is read-only.
    expect_error(lambda: w.rpc(u, "select public.update_item(:i, 'x', '')", i=first["id"]), "PT404")
    expect_error(lambda: save_memory(w, u, first["id"]), "PT404")
    expect_error(lambda: w.rpc(u, "select public.delete_item(:i)", i=first["id"]), "PT404")


@test
def new_member_starts_with_journey_one(w: World):
    u = w.new_member("m")
    item = add_item(w, u, "first ever")
    eq(w.rpc(u, "select number, status from public.journeys"), [[1, "active"]], "journey 1")
    eq(item["number"], 1, "item #1")


@test
def read_helpers_match_the_phone(w: World):
    u = w.new_member("m")
    eq(w.rpc(u, "select (public.ensure_active_journey()).number")[0][0], 1, "journey 1 created")
    eq(w.rpc(u, "select count(*) from public.journeys")[0][0], 1, "only once")
    w.rpc(u, "select public.ensure_active_journey()")
    eq(w.rpc(u, "select count(*) from public.journeys")[0][0], 1, "idempotent")
    a = add_item(w, u, "Travel to Japan")
    b = add_item(w, u, "100% honest_day")
    c = add_item(w, u, "Something else")
    save_memory(w, u, c["id"], text="Tokyo at night", hashtags=["travel", "夢"], location="Iceland")
    save_memory(w, u, c["id"], text="second", photos=[photo(), photo()])
    def search(q, j=None):
        rows = w.rpc(u, "select x::text from public.search_item_ids(:q, cast(:j as uuid)) x", q=q, j=j)
        return sorted(r[0] for r in rows or [])
    eq(search("japan"), [a["id"]], "case-insensitive title")
    eq(search("#TRAVEL"), sorted([a["id"], c["id"]]), "hashtag with #")
    eq(search("夢"), [c["id"]], "unicode hashtag")
    eq(search("iceland"), [c["id"]], "location")
    eq(search("2"), [b["id"]], "number")
    eq(search("100%"), [b["id"]], "percent is literal")
    eq(search("_"), [b["id"]], "underscore is literal")
    eq(search("   "), [], "empty")
    counts = dict((str(r[0]), r[1]) for r in w.rpc(u, "select * from public.memory_counts()"))
    eq(counts, {c["id"]: 2}, "memory counts")
    w.rpc(u, "select public.set_item_completed(:i, true, '2026-10-01')", i=c["id"])
    j = w.rpc(u, "select id::text from public.journeys")[0][0]
    outline = w.rpc(u, "select public.album_outline(:j)", j=j)[0][0]
    eq([e["item"]["id"] for e in outline], [c["id"]], "only completed items")
    eq([(m["textLength"], m["photoCount"]) for m in outline[0]["memories"]],
       [(len("Tokyo at night"), 0), (len("second"), 2)], "memory sizes")
    # Another member sees none of it.
    v = w.new_member("v")
    eq(w.rpc(v, "select count(*) from public.search_item_ids('travel', cast(:j as uuid))", j=j)[0][0],
       0, "search isolation")
    eq(w.rpc(v, "select public.album_outline(:j)", j=j)[0][0], [], "album isolation")
    eq(w.rpc(v, "select count(*) from public.memory_counts(cast(:j as uuid))", j=j)[0][0], 0,
       "count isolation")


# --- migration -------------------------------------------------------------

def fixture() -> dict:
    with open(FIXTURE, encoding="utf-8") as f:
        return json.load(f)


def normalise(data):
    """Timestamps → aware datetimes, so formatting differences don't count."""
    if isinstance(data, dict):
        return {k: (_ts(v) if k in ("createdAt", "updatedAt", "archivedAt") else normalise(v))
                for k, v in data.items()}
    if isinstance(data, list):
        return [normalise(v) for v in data]
    return data


def _ts(v):
    if v is None:
        return None
    return dt.datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def with_fresh_ids(data: dict) -> dict:
    """The same archive with new UUIDs (another phone's archive)."""
    text = json.dumps(data)
    for old in set(re.findall(
            r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", text)):
        text = text.replace(old, str(uuid.uuid4()))
    return json.loads(text)


def import_archive(w, u, data):
    return w.rpc(u, "select public.import_archive(cast(:d as jsonb))", d=json.dumps(data))[0][0]


@test
def import_then_export_round_trips_exactly(w: World):
    u = w.new_member("m")
    data = fixture()
    r = import_archive(w, u, data)
    eq((r["status"], r["journeys"], r["items"], r["memories"], r["photos"]),
       ("imported", 2, 3, 2, 2), "import summary")
    exported = w.rpc(u, "select public.export_archive()")[0][0]
    eq(normalise(exported), normalise(data), "export equals the phone's data.json")
    prog = w.rpc(u, "select number, completed_count, exp from public.journey_progress order by number")
    eq(prog, [[1, 1, 1000], [2, 1, 1000]], "progress derived per journey")


@test
def import_is_safe_to_repeat(w: World):
    u = w.new_member("m")
    data = fixture()
    import_archive(w, u, data)
    for _ in range(2):
        r = import_archive(w, u, data)
        eq(r["status"], "resumed", "second run")
    eq((count(w, u, "journeys"), count(w, u, "items"), count(w, u, "memories"), count(w, u, "photos")),
       (2, 3, 2, 2), "no duplicates")
    # Edits made in the cloud since are not overwritten by a re-run.
    w.rpc(u, "select public.update_item(:i, 'edited on the web', '')",
          i="aaaaaaaa-0000-4000-8000-000000000002")
    import_archive(w, u, data)
    eq(w.rpc(u, "select title from public.items where id = 'aaaaaaaa-0000-4000-8000-000000000002'"),
       [["edited on the web"]], "cloud edit kept")


@test
def import_replaces_only_an_untouched_new_account(w: World):
    u = w.new_member("m")
    w.rpc(u, "select public.pull_changes(0)")
    w.rpc(u, "select public.set_journey_start('2026-01-01')")  # creates the empty Journey 1
    eq(import_archive(w, u, fixture())["status"], "imported", "empty placeholder replaced")

    v = w.new_member("v")
    add_item(w, v, "started on the web")
    expect_error(lambda: import_archive(w, v, with_fresh_ids(fixture())), "PT409",
                 "cloud_has_other_data")
    eq(count(w, v, "items"), 1, "existing cloud data untouched")


@test
def import_is_all_or_nothing(w: World):
    u = w.new_member("m")
    data = fixture()
    data["journeys"][1]["items"][1]["number"] = 1001  # invalid
    expect_error(lambda: import_archive(w, u, data), "23514")
    eq((count(w, u, "journeys"), count(w, u, "items")), (0, 0), "nothing stored")
    bad = fixture()
    bad["journeys"][0]["status"] = "active"
    expect_error(lambda: import_archive(w, u, bad), "PT422", "invalid_data")
    expect_error(lambda: import_archive(w, u, {"dataFormatVersion": 3, "journeys": []}),
                 "PT422", "unsupported_format")


@test
def import_cannot_claim_another_accounts_ids(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    import_archive(w, a, fixture())
    expect_error(lambda: import_archive(w, b, fixture()), "PT409", "id_conflict")
    eq(count(w, b, "items"), 0, "nothing imported")
    eq(count(w, a, "items"), 3, "owner of the ids unaffected")


@test
def migration_file_check_reports_missing_and_present_files(w: World):
    u = w.new_member("m")
    import_archive(w, u, fixture())
    files = {r[0]: (r[1], r[2]) for r in w.rpc(u, "select path, kind, present from public.archive_files()")}
    eq(len(files), 6, "4 photo files + current and archived profile pictures")
    assert all(not present for _, present in files.values()), "nothing uploaded yet"
    path = "photos/cccccccc-0000-4000-8000-000000000001.jpg"
    w.rpc(u, "insert into storage.objects (bucket_id, name, metadata) values ('photos', :n, :m)",
          n=f"{u}/{path}", m=json.dumps({"size": 1234}))
    w.rpc(u, "insert into storage.objects (bucket_id, name, metadata) values ('photos', :n, :m)",
          n=f"{u}/photos/stray.jpg", m=json.dumps({"size": 1}))
    rows = {r[0]: (r[1], r[2]) for r in w.rpc(u, "select path, present, size from public.archive_files()")}
    eq(rows[path], (True, 1234), "uploaded file found with its size")
    eq(w.rpc(u, "select path from public.orphan_files()"), [["photos/stray.jpg"]], "orphans")


# --- sync ------------------------------------------------------------------

@test
def pull_changes_returns_changes_and_deletions_since_a_revision(w: World):
    u = w.new_member("m")
    a = add_item(w, u, "a")
    b = add_item(w, u, "b")
    mem = save_memory(w, u, b["id"], photos=[photo()])
    full = w.rpc(u, "select public.pull_changes(0)")[0][0]
    eq((len(full["items"]), len(full["memories"]), len(full["photos"])), (2, 1, 1), "full pull")
    since = full["revision"]
    eq(w.rpc(u, "select public.pull_changes(:s)", s=since)[0][0]["items"], [], "nothing new")

    w.rpc(u, "select public.update_item(:i, 'a2', '')", i=a["id"])
    w.rpc(u, "select public.delete_item(:i)", i=b["id"])
    delta = w.rpc(u, "select public.pull_changes(:s)", s=since)[0][0]
    eq([i["title"] for i in delta["items"]], ["a2"], "changed item")
    deleted = {(d["table"], d["id"]) for d in delta["deletions"]}
    assert ("items", b["id"]) in deleted, "deleted item"
    assert ("memories", mem["memory"]["id"]) in deleted, "cascaded memory tombstone"
    eq(len([d for d in deleted if d[0] == "photos"]), 1, "cascaded photo tombstone")
    assert delta["revision"] > since, "revision advanced"

    # Clients can't choose revisions.
    w.rpc(u, "insert into public.profiles (user_id, name, revision) values (auth.uid(), 'x', 999999)")
    rev = w.rpc(u, "select revision from public.profiles")[0][0]
    assert rev < 999999, "revision assigned by the server"


# --- merging ---------------------------------------------------------------

def merge(w, u, data, apply=True, titles=True):
    return w.rpc(u, "select public.merge_archive(cast(:d as jsonb), :a, :t)",
                 d=json.dumps(data), a=apply, t=titles)[0][0]


def export(w, u):
    return w.rpc(u, "select public.export_archive()")[0][0]


def active_items(data):
    return [i for j in data["journeys"] if j["status"] == "active" for i in j["items"]]


@test
def merge_into_an_empty_account_keeps_everything_as_it_was(w: World):
    u = w.new_member("m")
    w.rpc(u, "select public.ensure_active_journey()")  # the empty Journey 1 a new member has
    data = fixture()
    preview = merge(w, u, data, apply=False)
    eq(preview["applied"], False, "dry run")
    eq(count(w, u, "items"), 0, "dry run stored nothing")
    eq(w.rpc(u, "select count(*) from public.journeys")[0][0], 1, "empty journey still there")
    r = merge(w, u, data)
    eq(r["changes"], preview["changes"], "preview said exactly what happened")
    eq(r["after"], preview["after"], "same totals")
    eq((r["changes"]["replacedEmptyJourney"], r["changes"]["journeysAdded"],
        r["changes"]["itemsAdded"], r["changes"]["memoriesAdded"], r["changes"]["photosAdded"],
        r["changes"]["profile"]), (True, 2, 3, 2, 2, "added"), "everything added")
    out = export(w, u)
    # Same ids, numbers, dates, texts, hashtags, photos and profile as the file.
    def strip(d):
        d = normalise(d)
        for j in d["journeys"]:
            for i in j["items"]:
                i.pop("position")
        return d
    eq(strip(out), strip(data), "account equals the file (positions renumbered compactly)")
    eq([i["title"] for i in active_items(out)], [i["title"] for i in active_items(data)], "order kept")


@test
def merging_twice_adds_nothing_and_never_doubles_exp(w: World):
    u = w.new_member("m")
    data = fixture()
    merge(w, u, data)
    first = export(w, u)
    exp = w.rpc(u, "select exp from public.journey_progress where status = 'active'")[0][0]
    again = merge(w, u, data)
    eq(again["nothingToAdd"], True, "nothing left to add")
    eq(again["before"], again["after"], "totals unchanged")
    eq(export(w, u), first, "account unchanged")
    eq(w.rpc(u, "select exp from public.journey_progress where status = 'active'")[0][0], exp,
       "EXP unchanged")
    # Also after a plain import of the same file.
    expect_ok = import_archive(w, u, data)
    eq(expect_ok["status"], "resumed", "import sees the same journeys")
    eq(export(w, u), first, "still unchanged")


@test
def merge_adds_to_an_account_with_its_own_list_without_changing_it(w: World):
    u = w.new_member("m")
    own = add_item(w, u, "Learn to sail")        # same title as a file thing
    other = add_item(w, u, "Bake bread")
    w.rpc(u, "insert into public.profiles (user_id, name) values (auth.uid(), 'Web Me')")
    w.rpc(u, "insert into public.settings (user_id, key, value) values (auth.uid(), 'theme_mode', 'light')")
    before = export(w, u)
    data = fixture()
    data["journeys"] = [j for j in data["journeys"] if j["status"] == "active"]  # no history
    data["journeys"][0]["number"] = 1
    for i in data["journeys"][0]["items"]:
        if i["title"] == "Learn to sail":
            i["isCompleted"], i["completedOn"] = True, "2026-09-09"
            i["description"] = "From the phone"
            i["memories"] = [{"id": str(uuid.uuid4()), "position": 0, "title": "On the lake",
                              "text": "phone memory", "date": "2026-09-09", "location": "",
                              "hashtags": ["sailing"], "createdAt": "2026-09-09T10:00:00Z",
                              "updatedAt": "2026-09-09T10:00:00Z", "photos": []}]

    preview = merge(w, u, data, apply=False)
    c = preview["changes"]
    eq((c["itemsAdded"], c["matchedByTitle"], c["completionsAdded"], c["textKept"],
        c["memoriesAdded"], c["profile"], c["settingsAdded"]),
       (1, 1, 1, 1, 2, "kept", 0), "preview")
    eq(export(w, u), before, "preview changed nothing")
    eq((preview["before"]["completed"], preview["after"]["completed"]), (0, 2), "EXP preview")

    merge(w, u, data)
    after = export(w, u)
    items = {i["title"]: i for i in active_items(after)}
    eq(sorted(items), ["Bake bread", "Learn to sail", "Run a marathon"], "no duplicate by title")
    sail = items["Learn to sail"]
    eq(sail["id"], own["id"], "the account's own record is kept")
    eq((sail["description"], sail["isCompleted"], sail["completedOn"]), ("", True, "2026-09-09"),
       "text kept, completion added")
    eq([m["title"] for m in sail["memories"]], ["On the lake"], "memory attached")
    eq([i["title"] for i in active_items(after)], ["Learn to sail", "Bake bread", "Run a marathon"],
       "account's order first, new things after")
    eq(items["Run a marathon"]["number"], 3, "number 1 was taken: lowest free number")
    eq(items["Bake bread"]["number"], other["number"], "own numbers untouched")
    eq(after["profile"]["name"], "Web Me", "profile kept")
    eq(after["settings"], {"theme_mode": "light"}, "setting kept")
    eq(merge(w, u, data)["nothingToAdd"], True, "second merge adds nothing")
    eq(w.rpc(u, "select completed_count, exp from public.journey_progress where status = 'active'"),
       [[2, 2000]], "EXP counted once per completed thing")

    # Without title matching the same-titled thing is added separately.
    u2 = w.new_member("m2")
    add_item(w, u2, "Learn to sail")
    r = merge(w, u2, with_fresh_ids(data), titles=False)
    eq((r["changes"]["itemsAdded"], r["changes"]["matchedByTitle"]), (2, 0), "titles not matched")


@test
def merge_brings_finished_journeys_and_refuses_two_histories(w: World):
    u = w.new_member("m")
    add_item(w, u, "Web thing")
    data = fixture()   # Journey 1 finished, Journey 2 current
    r = merge(w, u, data)
    eq(r["changes"]["journeysAdded"], 1, "finished journey added")
    eq(w.rpc(u, "select number, status from public.journeys order by number"),
       [[1, "archived"], [2, "active"]], "current journey renumbered after the history")
    eq(w.rpc(u, "select count(*) from public.items i join public.journeys j on j.id = i.journey_id "
                "where j.status = 'archived'")[0][0], 1, "history's things kept")
    eq(merge(w, u, data)["nothingToAdd"], True, "repeatable")
    # A different history can't be combined.
    expect_error(lambda: merge(w, u, with_fresh_ids(data)), "PT409", "history_conflict")
    expect_error(lambda: merge(w, u, with_fresh_ids(data), apply=False), "PT409", "history_conflict")


@test
def merge_rejects_bad_files_and_other_accounts_ids(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    expect_error(lambda: merge(w, a, {"dataFormatVersion": 3, "journeys": []}), "PT422",
                 "unsupported_format")
    expect_error(lambda: merge(w, a, {"dataFormatVersion": 2, "journeys": []}), "PT422", "invalid_data")
    bad = fixture()
    active_items(bad)[0]["title"] = "   "
    expect_error(lambda: merge(w, a, bad), "PT422", "title_required")
    eq(count(w, a, "items"), 0, "nothing stored from a bad file")
    merge(w, a, fixture())
    expect_error(lambda: merge(w, b, fixture()), "PT409", "id_conflict")
    eq(count(w, b, "items"), 0, "nothing taken from another account")
    stranger = w.new_user("s")
    expect_error(lambda: merge(w, stranger, fixture()), "PT403")
    expect_error(lambda: w.rpc(None, "select public.merge_archive('{}'::jsonb)"), "42501")
    expect_error(lambda: w.rpc(a, "select private.merge_into(auth.uid(), '{}'::jsonb, true)"), "42501")


@test
def merge_respects_the_1000_limit(w: World):
    u = w.new_member("m")
    add_item(w, u, "first")
    data = fixture()
    data["journeys"] = [j for j in data["journeys"] if j["status"] == "active"]
    data["journeys"][0]["number"] = 1
    data["journeys"][0]["items"] = [
        {"id": str(uuid.uuid4()), "number": n, "position": n, "title": f"t{n}", "description": "",
         "isCompleted": False, "completedOn": None, "createdAt": "2026-01-01T00:00:00Z",
         "updatedAt": "2026-01-01T00:00:00Z", "memories": []} for n in range(1, 1001)]
    expect_error(lambda: merge(w, u, data, apply=False), "PT409", "list_full")
    eq(count(w, u, "items"), 1, "nothing added")


@test
def every_archive_change_bumps_the_accounts_sync_head_only(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    item = add_item(w, a, "x")
    head = lambda u: w.rpc(u, "select revision from public.sync_heads")
    r1 = head(a)[0][0]
    eq(r1, w.rpc(a, "select public.pull_changes(0)")[0][0]["revision"], "head = latest revision")
    w.rpc(a, "select public.delete_item(:i)", i=item["id"])
    assert head(a)[0][0] > r1, "a delete bumps it too"
    eq(head(b), [], "nobody sees another account's head")
    expect_error(lambda: w.rpc(a, "update public.sync_heads set revision = 0"), "42501")
    expect_error(lambda: w.rpc(None, "select * from public.sync_heads"), "42501")
    merge(w, b, fixture(), apply=False)
    eq(head(b), [], "a dry run leaves no trace")


# --- friends ---------------------------------------------------------------

def social(w: World, uid: str, username: str, name: str | None = None, **share) -> dict:
    """Chooses a username (and sharing choices) for uid."""
    # memories / location left out = None: keep what is saved (as an
    # older app does).
    return w.rpc(uid, "select to_jsonb(public.save_social_profile(:u, :n, :ph, :b, :st, :sx, :lv, :lst, "
                 "cast(:mv as text), cast(:ml as boolean)))",
                 u=username, n=name or username.title(),
                 ph=share.get("photo", False), b=share.get("bio", False),
                 st=share.get("started", False), sx=share.get("stats", False),
                 lv=share.get("level", False), lst=share.get("list", "private"),
                 mv=share.get("memories"), ml=share.get("location"))[0][0]


def search(w, uid, q):
    return w.rpc(uid, "select public.search_people(:q)", q=q)[0][0]


def send(w, uid, other):
    return w.rpc(uid, "select public.send_friend_request(:o)", o=other)[0][0]


def requests(w, uid):
    return w.rpc(uid, "select public.list_friend_requests()")[0][0]


def respond(w, uid, request_id, accept=True):
    return w.rpc(uid, "select public.respond_friend_request(:r, :a)", r=request_id, a=accept)[0][0]


def friends_of(w, uid):
    return [f["username"] for f in w.rpc(uid, "select public.list_friends()")[0][0]]


def befriend(w, a, b):
    rid = send(w, a, b)["requestId"]
    eq(respond(w, b, rid)["status"], "accepted", "accepted")
    return rid


def profile_of(w, viewer, other):
    return w.rpc(viewer, "select public.friend_profile(:o)", o=other)[0][0]


def list_of(w, viewer, other):
    return w.rpc(viewer, "select public.friend_list(:o)", o=other)[0][0]


@test
def friend_request_accepted_makes_both_friends(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    social(w, a, "alice", "Alice A")
    social(w, b, "bob", "Bob B")
    found = search(w, a, "bo")
    eq([(p["username"], p["displayName"], p["relation"]) for p in found],
       [("bob", "Bob B", "none")], "A finds B")
    sent = send(w, a, b)
    eq(sent["status"], "pending", "sent")
    eq(search(w, a, "bob")[0]["relation"], "sent", "shown as sent to A")
    eq(search(w, b, "alice")[0]["relation"], "received", "shown as received to B")
    inbox = requests(w, b)
    eq([(r["username"], r["requestId"]) for r in inbox["received"]],
       [("alice", sent["requestId"])], "B's incoming request")
    eq(inbox["sent"], [], "B sent nothing")
    eq([r["username"] for r in requests(w, a)["sent"]], ["bob"], "A's sent list")
    eq(respond(w, b, sent["requestId"])["status"], "accepted", "B accepts")
    eq(friends_of(w, a), ["bob"], "A's friends")
    eq(friends_of(w, b), ["alice"], "B's friends")
    eq(requests(w, a), {"received": [], "sent": []}, "nothing waiting for A")
    eq(requests(w, b), {"received": [], "sent": []}, "nothing waiting for B")
    eq(search(w, a, "bob")[0]["relation"], "friend", "shown as friend")
    eq(w.rpc(a, "select count(*) from public.friendships")[0][0], 1, "one friendship row")


@test
def search_finds_only_people_with_a_username_and_shows_only_who_they_are(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    hidden = w.new_member("hidden")         # never chose a username
    stranger = w.new_user("stranger")       # not a member
    social(w, a, "alice")
    w.rpc(b, "insert into public.profiles (user_id, name, bio, photo) values "
             "(auth.uid(), 'Real Name', 'secret bio', 'profile/b.jpg')")
    social(w, b, "bob_smith", "Bobby", photo=False, bio=True, stats=True, level=True, list="friends")
    w.rpc(c, "insert into public.profiles (user_id, photo) values (auth.uid(), 'profile/c.jpg')")
    social(w, c, "carol", "Carol", photo=True)
    w.rpc(hidden, "insert into public.profiles (user_id, name) values (auth.uid(), 'Hidden Harry')")

    eq(search(w, a, "harry"), [], "people without a username can't be found")
    eq(search(w, a, "real"), [], "not found by their private profile name")
    eq(search(w, a, "alice"), [], "you don't find yourself")
    eq(search(w, a, "b"), [], "at least two characters")
    eq(search(w, a, "%"), [], "wildcards are literal")
    eq([p["username"] for p in search(w, a, "@BOB")], ["bob_smith"], "@ and case ignored")
    eq([p["username"] for p in search(w, a, "obby")], ["bob_smith"], "part of the display name")
    bob = search(w, a, "bob_")[0]
    eq(set(bob), {"userId", "username", "displayName", "photo", "relation"}, "only identity")
    eq(bob["photo"], None, "photo hidden unless shared")
    assert "secret bio" not in json.dumps(bob) and "Real Name" not in json.dumps(bob)
    eq(search(w, a, "carol")[0]["photo"], "profile/c.jpg", "shared photo")

    # Searching needs a username of your own, and membership.
    expect_error(lambda: search(w, hidden, "alice"), "PT409", "username_required")
    expect_error(lambda: search(w, stranger, "alice"), "PT403", "not_a_member")
    expect_error(lambda: w.rpc(None, "select public.search_people('alice')"), "42501")

    # Disabled members disappear.
    w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=c)
    eq(search(w, a, "carol"), [], "disabled member hidden")


@test
def usernames_are_validated_and_unique(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    for bad in ["ab", "has space", "Ümlaut", "x" * 21, "dot.ted", ""]:
        expect_error(lambda: social(w, a, bad, "A"), "PT422", "invalid_username")
    expect_error(lambda: social(w, a, "alice", "   "), "PT422", "invalid_display_name")
    expect_error(lambda: social(w, a, "alice", "A", list="public"), "PT422", "invalid_visibility")
    eq(social(w, a, "  @Alice ", " Alice ")["username"], "alice", "normalised")
    expect_error(lambda: social(w, b, "ALICE", "B"), "PT409", "username_taken")
    eq(social(w, a, "alice2", "Alice")["username"], "alice2", "can rename")
    eq(social(w, b, "alice", "B")["username"], "alice", "freed name reusable")
    p = social(w, a, "alice2", "Alice")
    eq((p["list_visibility"], p["show_photo"], p["show_bio"], p["show_level"], p["memory_visibility"]),
       ("private", False, False, False, "private"), "everything private by default")


@test
def invalid_and_duplicate_requests_are_rejected(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    nobody = w.new_member("nobody")
    for u, n in [(a, "alice"), (b, "bob"), (c, "carol")]:
        social(w, u, n)
    expect_error(lambda: send(w, a, a), "PT422", "cannot_add_yourself")
    expect_error(lambda: send(w, a, nobody), "PT404", "person_not_found")
    expect_error(lambda: send(w, a, str(uuid.uuid4())), "PT404", "person_not_found")
    expect_error(lambda: send(w, nobody, a), "PT409", "username_required")

    first = send(w, a, b)
    eq(send(w, a, b), first, "sending again returns the same request")
    expect_error(lambda: send(w, b, a), "PT409", "they_already_asked_you")
    eq(w.db.admin("select count(*) from public.friend_requests")[0][0], 1, "one request")
    # The database itself refuses a second open request between the two.
    expect_error(lambda: w.db.admin(
        "insert into public.friend_requests (sender_id, recipient_id) values (:b, :a)", a=a, b=b),
        "23505")

    rid = first["requestId"]
    expect_error(lambda: respond(w, a, rid), "PT404", "request_not_found")       # sender
    expect_error(lambda: respond(w, c, rid), "PT404", "request_not_found")       # outsider
    expect_error(lambda: w.rpc(b, "select public.cancel_friend_request(:r)", r=rid),
                 "PT404", "request_not_found")                                    # recipient
    expect_error(lambda: w.rpc(c, "select public.cancel_friend_request(:r)", r=rid),
                 "PT404", "request_not_found")
    eq(w.rpc(a, "select public.cancel_friend_request(:r)", r=rid)[0][0]["status"], "cancelled", "cancel")
    eq(w.rpc(a, "select public.cancel_friend_request(:r)", r=rid)[0][0]["status"], "cancelled",
       "cancel again is harmless")
    expect_error(lambda: respond(w, b, rid), "PT409", "request_not_pending")
    eq(requests(w, b)["received"], [], "cancelled request gone")

    # Declined: stays declined; asking again must wait.
    rid = send(w, a, b)["requestId"]
    eq(respond(w, b, rid, accept=False)["status"], "declined", "decline")
    eq(respond(w, b, rid, accept=False)["status"], "declined", "decline again is harmless")
    expect_error(lambda: respond(w, b, rid), "PT409", "request_not_pending")
    expect_error(lambda: w.rpc(a, "select public.cancel_friend_request(:r)", r=rid),
                 "PT409", "request_not_pending")
    expect_error(lambda: send(w, a, b), "PT409", "recently_declined")
    eq(friends_of(w, b), [], "not friends")
    # The one who declined can still ask later themselves.
    rid = send(w, b, a)["requestId"]
    eq(respond(w, a, rid)["status"], "accepted", "accepted")
    eq(respond(w, a, rid)["status"], "accepted", "accept again is harmless")
    expect_error(lambda: respond(w, a, rid, accept=False), "PT409", "request_not_pending")
    expect_error(lambda: send(w, a, b), "PT409", "already_friends")
    expect_error(lambda: send(w, b, a), "PT409", "already_friends")
    eq(w.db.admin("select count(*) from public.friendships")[0][0], 1, "one friendship")
    expect_error(lambda: w.db.admin(
        "insert into public.friendships (user_low, user_high) values (:h, :l)",
        l=min(a, b), h=max(a, b)), "23514")  # reversed pair refused


@test
def requests_and_friendships_cant_be_written_or_read_directly(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    for u, n in [(a, "alice"), (b, "bob"), (c, "carol")]:
        social(w, u, n)
    rid = send(w, a, b)["requestId"]
    expect_error(lambda: w.rpc(b, "update public.friend_requests set status = 'accepted'"), "42501")
    expect_error(lambda: w.rpc(c, "insert into public.friend_requests (sender_id, recipient_id) "
                                  "values (:b, auth.uid())", b=b), "42501")
    expect_error(lambda: w.rpc(c, "insert into public.friendships (user_low, user_high) "
                                  "values (least(auth.uid(), cast(:a as uuid)), greatest(auth.uid(), cast(:a as uuid)))",
                               a=a), "42501")
    expect_error(lambda: w.rpc(a, "delete from public.friend_requests"), "42501")
    expect_error(lambda: w.rpc(a, "update public.social_profiles set list_visibility = 'friends'"),
                 "42501")
    expect_error(lambda: w.rpc(a, "insert into public.social_profiles (user_id, username, display_name) "
                                  "values (auth.uid(), 'zzz', 'z')"), "42501")
    eq(w.rpc(c, "select count(*) from public.friend_requests")[0][0], 0, "outsider sees no requests")
    eq(w.rpc(a, "select count(*) from public.social_profiles")[0][0], 1, "only own settings")
    respond(w, b, rid)
    eq(w.rpc(c, "select count(*) from public.friendships")[0][0], 0, "outsider sees no friendships")
    for t in ["social_profiles", "friend_requests", "friendships"]:
        expect_error(lambda: w.rpc(None, f"select * from public.{t}"), "42501")


@test
def friend_profile_shows_only_what_the_owner_shares(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    w.rpc(b, "insert into public.profiles (user_id, name, nickname, age, started_on, bio, photo) values "
             "(auth.uid(), 'Bob Real', 'Bobster', 41, '2020-01-02', 'Loves boats', 'profile/b.jpg')")
    for t in ["sail", "climb", "dive"]:
        add_item(w, b, t)
    items = w.rpc(b, "select id from public.items order by position")
    w.rpc(b, "select public.set_item_completed(:i, true, '2026-10-01')", i=items[0][0])
    social(w, a, "alice")
    social(w, c, "carol")
    social(w, b, "bob", "Bob")

    eq(set(profile_of(w, a, b)), {"userId", "username", "displayName", "photo", "relation"},
       "non-friend: identity only")
    befriend(w, a, b)
    p = profile_of(w, a, b)
    eq(set(p), {"userId", "username", "displayName", "photo", "relation", "listShared"},
       "friend, nothing shared yet")
    eq((p["relation"], p["listShared"], p["photo"]), ("friend", False, None), "defaults private")
    for secret in ["Bob Real", "Bobster", "41", "Loves boats", "2020-01-02"]:
        assert secret not in json.dumps(p), f"{secret} leaked"

    social(w, b, "bob", "Bob", photo=True, bio=True, started=True, stats=True, level=True)
    p = profile_of(w, a, b)
    eq((p["photo"], p["bio"], p["startedOn"]), ("profile/b.jpg", "Loves boats", "2020-01-02"), "shared")
    eq(p["stats"], {"completed": 1, "listed": 3, "journeysFinished": 0}, "stats")
    eq(p["progress"], {"level": 0, "exp": 1000}, "level and EXP from the same formula")
    assert "Bob Real" not in json.dumps(p) and "41" not in json.dumps(p), "name/age never shared"
    eq(set(profile_of(w, c, b)), {"userId", "username", "displayName", "photo", "relation"},
       "still identity only for a non-friend")
    # Turning a field off hides it on the next request.
    social(w, b, "bob", "Bob", photo=True, bio=False, stats=True)
    p = profile_of(w, a, b)
    assert "bio" not in p and "progress" not in p and "startedOn" not in p, "hidden again"
    eq(profile_of(w, b, b)["relation"], "self", "own preview")
    expect_error(lambda: profile_of(w, a, str(uuid.uuid4())), "PT404", "person_not_found")


@test
def bucket_list_visibility_is_enforced_and_revoked_at_once(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    for t in ["first", "second", "third"]:
        add_item(w, b, t)
    ids = [str(r[0]) for r in w.rpc(b, "select id from public.items order by position")]
    w.rpc(b, "select public.save_order(cast(:o as uuid[]))", o="{%s}" % ",".join(reversed(ids)))
    w.rpc(b, "select public.set_item_completed(:i, true, '2026-10-01')", i=ids[0])
    save_memory(w, b, ids[0], photos=[photo()], text="private memory text", location="Secret place")
    for u, n in [(a, "alice"), (b, "bob"), (c, "carol")]:
        social(w, u, n)
    befriend(w, a, b)

    # Private (the default): even a friend can't see it.
    expect_error(lambda: list_of(w, a, b), "PT403", "list_not_shared")
    social(w, b, "bob", list="friends")
    shared = list_of(w, a, b)
    eq([i["title"] for i in shared["items"]], ["third", "second", "first"], "owner's order")
    eq(shared["items"][2]["completedOn"], "2026-10-01", "completion shown")
    eq(set(shared["items"][0]), {"number", "title", "description", "isCompleted", "completedOn",
                                 "memories"}, "entries only")
    eq(shared["memoriesShared"], False, "memories not shared")
    eq([i["memories"] for i in shared["items"]], [0, 0, 0], "no memory counts")
    text = json.dumps(shared)
    assert "private memory" not in text and "Secret place" not in text and ids[0] not in text, \
        "no memories, photos or ids"
    # Non-friends get the same refusal as for a private list.
    e1 = expect_error(lambda: list_of(w, c, b), "PT403", "list_not_shared")
    # Making it private ends access on the very next request.
    social(w, b, "bob", list="private")
    e2 = expect_error(lambda: list_of(w, a, b), "PT403", "list_not_shared")
    eq(e1.message, e2.message, "indistinguishable refusals")
    social(w, b, "bob", list="friends")
    eq(len(list_of(w, a, b)["items"]), 3, "shared again")
    # Removing the friend ends it too (either side may remove).
    eq(w.rpc(b, "select public.remove_friend(:a)", a=a)[0][0], True, "removed")
    eq(w.rpc(b, "select public.remove_friend(:a)", a=a)[0][0], False, "already removed")
    expect_error(lambda: list_of(w, a, b), "PT403", "list_not_shared")
    eq(friends_of(w, a), [], "gone from A's friends")
    eq(set(profile_of(w, a, b)), {"userId", "username", "displayName", "photo", "relation"},
       "profile back to identity only")
    # Direct table reads never show someone else's rows.
    for t in ["journeys", "items", "memories", "photos", "profiles", "settings"]:
        eq(w.rpc(a, f"select count(*) from public.{t} where user_id = :b", b=b)[0][0], 0, f"{t} hidden")
    expect_error(lambda: w.rpc(a, "select * from private.visible_items(:b, auth.uid())", b=b), "42501")
    expect_error(lambda: w.rpc(a, "select private.can_view_list(:b, auth.uid())", b=b), "42501")


@test
def friends_can_never_change_each_others_lists(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    item = add_item(w, b, "bob's thing")
    mem = save_memory(w, b, item["id"])
    social(w, a, "alice")
    social(w, b, "bob", list="friends")
    befriend(w, a, b)
    before = w.rpc(b, "select public.export_archive()")[0][0]
    for sql in [
        "select public.update_item(:i, 'hacked', '')",
        "select public.set_item_completed(:i, true, '2026-10-01')",
    ]:
        expect_error(lambda: w.rpc(a, sql, i=item["id"]), "PT404")
    expect_error(lambda: save_memory(w, a, item["id"]), "PT404")
    # Deletes report "nothing deleted" for ids the caller doesn't own.
    eq(w.rpc(a, "select public.delete_item(:i)", i=item["id"])[0][0]["deleted"], False, "delete item")
    eq(w.rpc(a, "select public.delete_memory(:m)", m=mem["memory"]["id"])[0][0]["deleted"], False,
       "delete memory")
    expect_error(lambda: w.rpc(a, "select public.save_order(cast(:o as uuid[]))",
                               o="{%s}" % item["id"]))
    eq(w.rpc(a, "update public.profiles set bio = 'x' where user_id = :b returning 1", b=b), [],
       "no profile update")
    eq(w.rpc(b, "select public.export_archive()")[0][0], before, "Bob's archive unchanged")


@test
def shared_profile_photo_is_the_only_file_friends_can_read(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    w.rpc(b, "insert into public.profiles (user_id, photo) values (auth.uid(), 'profile/now.jpg')")
    for name in ["profile/now.jpg", "profile/old.jpg", "photos/p.jpg", "thumbs/p.jpg"]:
        w.rpc(b, "insert into storage.objects (bucket_id, name) values ('photos', :n)", n=f"{b}/{name}")
    social(w, a, "alice")
    social(w, b, "bob", photo=False, list="friends")
    befriend(w, a, b)

    def visible(viewer):
        return sorted(r[0] for r in w.rpc(viewer, "select name from storage.objects where name like :p",
                                           p=f"{b}/%"))
    eq(visible(a), [], "photo not shared")
    social(w, b, "bob", photo=True, list="friends")
    eq(visible(a), [f"{b}/profile/now.jpg"], "only the current profile photo")
    eq(visible(c), [], "members without a username can't read it")
    social(w, c, "carol")
    eq(visible(c), [f"{b}/profile/now.jpg"], "shown in search, so readable")
    expect_error(lambda: w.rpc(a, "insert into storage.objects (bucket_id, name) values ('photos', :n)",
                               n=f"{b}/profile/evil.jpg"), "42501")
    eq(w.rpc(a, "delete from storage.objects where name like :p returning 1", p=f"{b}/%"), [],
       "can't delete it")
    social(w, b, "bob", photo=False)
    eq(visible(a), [], "hidden again at once")


@test
def leaving_friends_or_being_disabled_ends_sharing(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    add_item(w, b, "thing")
    for u, n in [(a, "alice"), (c, "carol")]:
        social(w, u, n)
    social(w, b, "bob", list="friends")
    befriend(w, a, b)
    send(w, b, c)
    # The owner disabling a member hides them and their list.
    w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=b)
    expect_error(lambda: list_of(w, a, b), "PT403", "list_not_shared")
    eq(friends_of(w, a), [], "disabled friend hidden")
    eq(requests(w, c)["received"], [], "their request hidden")
    w.rpc(w.owner, "select public.set_member_status(:u, 'active')", u=b)
    eq(friends_of(w, a), ["bob"], "back when enabled again")
    # Stopping Friends removes the username, friendships and requests,
    # but not the list.
    eq(w.rpc(b, "select public.delete_social_profile()")[0][0], True, "left")
    eq(friends_of(w, a), [], "friendship gone")
    eq(requests(w, c)["received"], [], "request gone")
    eq(search(w, a, "bob"), [], "can't be found")
    eq(w.db.admin("select count(*) from public.friend_requests where :b in (sender_id, recipient_id)",
                  b=b)[0][0], 0, "requests deleted")
    eq(count(w, b, "items"), 1, "list kept")


@test
def friend_actions_leave_archives_and_progress_untouched(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    import_archive(w, a, fixture())
    add_item(w, b, "x")
    before = {u: w.rpc(u, "select public.export_archive()")[0][0] for u in (a, b)}
    rev = {u: w.rpc(u, "select public.pull_changes(0)")[0][0]["revision"] for u in (a, b)}
    social(w, a, "alice", stats=True, level=True, list="friends")
    social(w, b, "bob", list="friends")
    befriend(w, a, b)
    list_of(w, b, a)
    profile_of(w, b, a)
    w.rpc(a, "select public.remove_friend(:b)", b=b)
    w.rpc(a, "select public.delete_social_profile()")
    for u in (a, b):
        eq(w.rpc(u, "select public.export_archive()")[0][0], before[u], "archive unchanged")
        eq(w.rpc(u, "select public.pull_changes(0)")[0][0]["revision"], rev[u], "no sync changes")


def memories_of(w, viewer, other, number):
    return w.rpc(viewer, "select public.friend_memories(:o, :n)", o=other, n=number)[0][0]


@test
def memories_are_shared_only_when_chosen_and_only_with_friends(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    first = add_item(w, b, "first")
    add_item(w, b, "second")
    p1, p2 = photo(), photo()
    save_memory(w, b, first["id"], photos=[p1, p2], title="Day one", text="what happened",
                location="Secret place", hashtags=["fun"], date="2026-10-02")
    save_memory(w, b, first["id"], text="later", date="2026-10-03")
    for u, n in [(a, "alice"), (b, "bob"), (c, "carol")]:
        social(w, u, n)
    befriend(w, a, b)

    # Off by default, even with the list shared.
    social(w, b, "bob", list="friends")
    shared = list_of(w, a, b)
    eq(shared["memoriesShared"], False, "off by default")
    eq([i["memories"] for i in shared["items"]], [0, 0], "no counts while off")
    e_off = expect_error(lambda: memories_of(w, a, b, 1), "PT403", "memories_not_shared")
    assert "what happened" not in json.dumps(shared), "no memory text in the list"

    # Turned on: counts, then the memories in order, without the location.
    social(w, b, "bob", list="friends", memories="friends")
    shared = list_of(w, a, b)
    eq(shared["memoriesShared"], True, "shared")
    eq([i["memories"] for i in shared["items"]], [2, 0], "counts per entry")
    got = memories_of(w, a, b, 1)["memories"]
    eq([m["body"] for m in got], ["what happened", "later"], "memories in order")
    eq(got[0]["title"], "Day one", "title")
    eq(got[0]["date"], "2026-10-02", "date")
    eq(got[0]["hashtags"], ["fun"], "hashtags")
    eq(got[0]["location"], "", "location hidden by default")
    eq([ph["file"] for ph in got[0]["photos"]], [p1["file"], p2["file"]], "photos in order")
    eq(set(got[0]["photos"][0]), {"file", "thumb", "width", "height"}, "photo paths only")
    eq(set(got[0]), {"title", "body", "date", "location", "hashtags", "photos"}, "fields")
    assert first["id"] not in json.dumps(got), "no ids"
    eq(memories_of(w, a, b, 2)["memories"], [], "entry without memories")
    expect_error(lambda: memories_of(w, a, b, 3), "PT404", "item_not_found")
    social(w, b, "bob", list="friends", memories="friends", location=True)
    eq(memories_of(w, a, b, 1)["memories"][0]["location"], "Secret place", "location when chosen")
    eq(memories_of(w, b, b, 1)["memories"][0]["location"], "Secret place", "own preview")

    # Never to anyone else, and the same refusal every time.
    e_stranger = expect_error(lambda: memories_of(w, c, b, 1), "PT403", "memories_not_shared")
    eq(e_off.message, e_stranger.message, "indistinguishable refusals")
    # A private list hides its memories too, whatever the memory setting.
    social(w, b, "bob", list="private", memories="friends")
    expect_error(lambda: memories_of(w, a, b, 1), "PT403", "memories_not_shared")
    social(w, b, "bob", list="friends", memories="private")
    expect_error(lambda: memories_of(w, a, b, 1), "PT403", "memories_not_shared")
    social(w, b, "bob", list="friends", memories="friends")
    eq(len(memories_of(w, a, b, 1)["memories"]), 2, "shared again")
    # The owner disabling the account, or removing the friend, ends it.
    w.rpc(w.owner, "select public.set_member_status(:u, 'disabled')", u=b)
    expect_error(lambda: memories_of(w, a, b, 1), "PT403", "memories_not_shared")
    w.rpc(w.owner, "select public.set_member_status(:u, 'active')", u=b)
    eq(len(memories_of(w, a, b, 1)["memories"]), 2, "back when enabled")
    w.rpc(a, "select public.remove_friend(:b)", b=b)
    expect_error(lambda: memories_of(w, a, b, 1), "PT403", "memories_not_shared")
    # Direct reads still show nothing; the helper and anonymous calls are refused.
    eq(w.rpc(a, "select count(*) from public.memories where user_id = :b", b=b)[0][0], 0, "table hidden")
    expect_error(lambda: w.rpc(a, "select private.can_view_memories(:b, auth.uid())", b=b), "42501")
    expect_error(lambda: w.db.as_user(None, "select public.friend_memories(:b, 1)", b=b), "42501")


@test
def only_memories_of_the_current_journey_are_shared(w: World):
    a, b = w.new_member("a"), w.new_member("b")
    import_archive(w, b, fixture())
    for u, n in [(a, "alice"), (b, "bob")]:
        social(w, u, n)
    social(w, b, "bob", list="friends", memories="friends", location=True)
    befriend(w, a, b)
    shared = list_of(w, a, b)
    current = w.rpc(b, "select count(*) from public.memories m join public.items i on i.id = m.item_id "
                       "join public.journeys j on j.id = i.journey_id where j.status = 'active'")[0][0]
    seen = sum(len(memories_of(w, a, b, i["number"])["memories"]) for i in shared["items"])
    eq(seen, current, "every memory of the current journey")
    eq(sum(i["memories"] for i in shared["items"]), current, "counts add up")
    assert count(w, b, "memories") > current, "fixture should have memories in an archived journey"
    # Photo files likewise: only those of the current journey's memories.
    current_item = w.rpc(b, "select i.id from public.items i join public.journeys j "
                            "on j.id = i.journey_id where j.status = 'active' limit 1")[0][0]
    save_memory(w, b, str(current_item), photos=[photo()])
    files = w.rpc(b, "select p.file, j.status = 'active' from public.photos p "
                     "join public.memories m on m.id = p.memory_id "
                     "join public.items i on i.id = m.item_id "
                     "join public.journeys j on j.id = i.journey_id")
    assert any(not cur for _, cur in files) and any(cur for _, cur in files), \
        "fixture should have photos in both journeys"
    for f, _ in files:
        w.rpc(b, "insert into storage.objects (bucket_id, name) values ('photos', :n)", n=f"{b}/{f}")
    seen_files = sorted(r[0] for r in w.rpc(a, "select name from storage.objects where name like :p",
                                             p=f"{b}/%"))
    eq(seen_files, sorted(f"{b}/{f}" for f, cur in files if cur), "current journey's photos only")


@test
def memory_photos_are_readable_only_while_their_memory_is_shared(w: World):
    a, b, c = w.new_member("a"), w.new_member("b"), w.new_member("c")
    item = add_item(w, b, "thing")
    p = photo()
    save_memory(w, b, item["id"], photos=[p])
    for n in [p["file"], p["thumb"], "photos/loose.jpg", "profile/me.jpg"]:
        w.rpc(b, "insert into storage.objects (bucket_id, name) values ('photos', :n)", n=f"{b}/{n}")
    for u, n in [(a, "alice"), (c, "carol")]:
        social(w, u, n)
    social(w, b, "bob", list="friends")
    befriend(w, a, b)

    def visible(viewer):
        return sorted(r[0] for r in w.rpc(viewer, "select name from storage.objects where name like :p",
                                           p=f"{b}/%"))
    eq(visible(a), [], "nothing while memories are private")
    social(w, b, "bob", list="friends", memories="friends")
    eq(visible(a), sorted([f"{b}/{p['file']}", f"{b}/{p['thumb']}"]), "the memory's photo and thumbnail")
    eq(visible(c), [], "not to non-friends")
    eq(w.rpc(a, "delete from storage.objects where name like :p returning 1", p=f"{b}/%"), [],
       "can't delete them")
    eq(w.rpc(a, "update storage.objects set name = name || 'x' where name like :p returning 1",
             p=f"{b}/%"), [], "can't rename them")
    social(w, b, "bob", list="private", memories="friends")
    eq(visible(a), [], "hidden with the list")
    social(w, b, "bob", list="friends", memories="friends")
    w.rpc(b, "select public.delete_memory(m.id) from public.memories m")
    eq(visible(a), [], "gone with the memory")


@test
def older_apps_saving_settings_keep_the_memory_choices(w: World):
    b = w.new_member("b")
    social(w, b, "bob", list="friends", memories="friends", location=True)
    # The 1.4 app sends only the first eight arguments.
    w.rpc(b, "select public.save_social_profile('bob', 'Bob', false, false, false, false, false, 'friends')")
    row = w.rpc(b, "select memory_visibility, show_memory_location from public.social_profiles")[0]
    eq(list(row), ["friends", True], "kept")
    social(w, b, "bob", list="friends", memories="private", location=False)
    row = w.rpc(b, "select memory_visibility, show_memory_location from public.social_profiles")[0]
    eq(list(row), ["private", False], "turned off")
    expect_error(lambda: social(w, b, "bob", memories="everyone"), "PT422", "invalid_visibility")
    # A new username starts private.
    c = w.new_member("c")
    row = social(w, c, "carol")
    eq([row["memory_visibility"], row["show_memory_location"]], ["private", False], "private by default")


# -------------------------------------------------------------------- runner

def apply_schema(db: Db):
    for path in [os.path.join(HERE, "supabase_stub.sql")] + sorted(
            glob.glob(os.path.join(ROOT, "migrations", "*.sql"))):
        with open(path, encoding="utf-8") as f:
            db.conn.execute_simple(f.read())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", required=True, help="postgresql://user:pass@host:port/db")
    ap.add_argument("--stub", action="store_true",
                    help="plain PostgreSQL: build a fresh database per test with the stub")
    ap.add_argument("-k", help="only run tests whose name contains this")
    args = ap.parse_args()

    template = "p1000_test_template"
    if args.stub:
        admin = Db(args.dsn)
        admin.admin(f"drop database if exists {template}")
        admin.admin(f"create database {template}")
        t = Db(args.dsn, template)
        apply_schema(t)
        t.close()

    failed = 0
    selected = [t for t in TESTS if not args.k or args.k in t.__name__]
    for i, fn in enumerate(selected):
        if args.stub:
            name = f"p1000_test_{i}"
            admin.admin(f"drop database if exists {name}")
            admin.admin(f"create database {name} template {template}")
            db = Db(args.dsn, name)
        else:
            db = Db(args.dsn)
        w = None
        try:
            w = World(db)
            fn(w)
            print(f"PASS  {fn.__name__}")
        except Exception:
            failed += 1
            print(f"FAIL  {fn.__name__}")
            traceback.print_exc(limit=3)
        finally:
            if w and not args.stub:
                w.cleanup()
            db.close()
            if args.stub:
                admin.admin(f"drop database if exists {name}")
    if args.stub:
        admin.admin(f"drop database if exists {template}")
    print(f"\n{len(selected) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
