# Cloud accounts and sync (foundation)

Status: **backend foundation only.** The phone app released today is
still fully offline and does not contain any network code. This document
describes the shared backend that the phone and the future web app will
both use, and what is left to connect them.

The migrations were applied to the project's Supabase database on
2026-10-12 (`supabase db push`). Anonymous access to every table,
view and API function was checked against the live API and is refused.

```text
Phone app (Flutter) ─┐                         ┌─ Postgres: journeys, items, memories,
                     ├── Supabase (Auth, API) ─┤   photos, profiles, settings, members
Web app (later) ─────┘                         └─ Storage: private "photos" bucket
```

## What lives where

| Piece | Location |
|---|---|
| Accounts, roles, invitations | `supabase/migrations/20261012000100_accounts.sql` |
| Archive tables, ownership, row-level security, change tracking | `…000200_archive.sql` |
| The app's rules as API functions (add/edit/complete/delete/reorder, memories, regress, import/export, sync) | `…000300_archive_api.sql` |
| Photo bucket and storage policies | `…000400_storage.sql` |
| Security and behaviour tests | `supabase/tests/run_tests.py` |
| Phone → cloud migration (resumable, verified) | `lib/services/cloud/cloud_migration.dart` |
| Shared design tokens | `design/tokens.json` |

## Data model

The cloud tables match the phone's SQLite tables one to one
(`lib/data/database.dart`). Every row also has a `user_id` (the Supabase
Auth user) and a `revision`.

- **Ids are the phone's UUIDs.** They never change, so a record is the
  same record on every device.
- **Ownership is structural.** Children reference their parent by
  `(id, user_id)`, so an item can't be attached to someone else's
  journey, even by a buggy function.
- **Kept from the phone:** numbers 1–1000 unique per journey, one active
  journey per account, completion dates kept when un-completing,
  hashtags as a lowercase list (`text[]`), and photo paths
  (`photos/<id>.jpg`, `thumbs/<id>.jpg`, `profile/<id>.jpg`).
- **EXP, levels and percentages are never stored.** The
  `journey_progress` view derives them from the completed count using the
  formula in `lib/data/progression.dart` (a test pins both together).
  Completing the same item twice, from two devices or by retrying, can't
  award EXP twice.

## Shared business logic

The phone and the web app don't write journeys, items, memories or photos
directly. They call these functions (`supabase.rpc(name, params)`), which
apply the same rules as `ArchiveRepository`:

| Function | Does |
|---|---|
| `add_item(p_id, p_title, p_description)` | Lowest free number, added at the end. The client generates `p_id`, so a retry returns the same item. |
| `update_item(p_id, p_title, p_description, p_expected_revision)` | Edits the text. Returns 409 `stale_revision` if the item changed since the client last saw it. |
| `set_item_completed(p_id, p_completed, p_on)` | Sets a state (idempotent). Pass the user's **local** date. |
| `delete_item(p_id)` | Deletes the item with its memories and photos. Returns the storage paths to remove. |
| `save_order(p_ids)` | Must contain exactly the current list. |
| `save_memory(p_memory)` / `delete_memory(p_id)` | Same rules as on the phone. Photos must be uploaded first. |
| `set_journey_start(p_date)` | For Journey 1 this is the profile's start date. |
| `start_new_journey(p_new_started_on, p_reuse_list, p_snapshot_photo, p_finishing_journey)` | Regress: only at 1,000 / 1,000. Archives the journey and snapshots the profile, deleting nothing. Retry-safe. |
| `export_archive()` | The whole account in the backup `data.json` v2 format. |
| `import_archive(p_data)` | Migration (below). |
| `pull_changes(p_since)` | Rows changed and ids deleted since a revision. Used for caches and refresh. |
| `archive_files()` / `orphan_files()` | Expected files and their storage status / files nothing refers to. |

Profile (`profiles`) and settings (`settings`) are plain per-user rows
that clients upsert directly. RLS restricts them to the owner.

Errors arrive as HTTP statuses: 403 `not_a_member`, 404 `not_found`,
409 `stale_revision` / `list_full` / `journey_not_complete` /
`invalid_order` / `id_conflict` / `cloud_has_other_data`, and 422 for
invalid input.

## Sync strategy

The server is the source of truth. The design is deliberately simple:
**online writes, cached reads**.

- **Web:** always online. It calls the functions above and reads tables
  or `export_archive`.
- **Phone in cloud mode (next phase):** each change is sent to the
  function first, then the local SQLite database is updated from the
  result. Local SQLite becomes a cache refreshed by `pull_changes`, which
  provides rows plus tombstones, ordered by a per-account revision that
  never skips a commit. Offline, the phone can still read everything.
  Editing while offline needs either a queue (an outbox of the calls
  above, which are all retry-safe) or a "you're offline" message. That
  is a product decision for the next phase.
- **No silent overwrites:** edits carry the revision the client last saw.
  An outdated edit is refused, and the client reloads.
- **No duplicates:** new records use client-generated UUIDs, and repeated
  calls return the existing record.

## Accounts and roles (semi-RBAC)

| | Owner | Invited member | Signed in, not a member | Anonymous |
|---|---|---|---|---|
| Own archive, profile, photos | ✔ | ✔ | ✘ | ✘ |
| Other accounts' archives | ✘ | ✘ | ✘ | ✘ |
| Create / revoke invitations | ✔ | ✘ | ✘ | ✘ |
| List members, disable / re-enable a member | ✔ | ✘ | ✘ | ✘ |

- Roles live in `public.members`. Users can read **only their own** row
  and can never write it. Only `redeem_invitation` (and the one-time
  owner bootstrap from the SQL editor) creates members.
- **Being Owner gives no access to anyone's memories or photos.** It only
  allows account management.
- **Invitations** are single-use, expire (1 hour to 30 days, default 7),
  can be revoked, and are bound to one email address. The invitee must
  sign in with that email, and it must be confirmed. Only the SHA-256 of
  the token is stored. The token is shown once, to the owner, and the
  owner passes it on privately.
- **Rate limiting:** 5 failed redemptions per hour per account. Supabase
  Auth applies its own limits to sign-up, sign-in and password reset
  (Dashboard → Authentication → Rate Limits).
- **Revocation:** `set_member_status(user, 'disabled')` blocks the member
  on their next request, because every RLS check reads `members`. Their
  data is kept and can be restored by re-enabling them. Their existing
  JWT stays valid until it expires (1 hour by default), but it no longer
  opens any data.
- **Optional sign-up gate:** `hook_before_user_created` refuses sign-ups
  from emails without an open invitation. Even without it, a stranger
  who signs up gets nothing.

## Security report

Enforcement is server-side only: RLS on every table, explicit `revoke`s,
and `security definer` functions that check membership and scope every
statement to `auth.uid()`. Hiding buttons on the client is never relied
on. The privileged service-role key is never needed by any client.

`supabase/tests/run_tests.py` runs every check as the real `anon` /
`authenticated` roles, with JWT claims set the same way PostgREST sets
them. Results on 2026-10-12 (PostgreSQL 17.2 with the Supabase stub):
**35 passed, 0 failed**. They cover:

- Member → owner, member → member (both directions), owner → member and
  stranger → member, each **knowing every id**. No reads through tables,
  views, export, pull or file lists. No updates, completions, deletes or
  memory edits. No photo-id theft, no planting rows in another account,
  no moving rows between accounts, no storage reads or writes outside
  one's own folder, and no path traversal. The victim's export is
  byte-identical afterwards.
- Anonymous users can't read any table or call any function. Signed-in
  non-members get nothing. The private schema (invitations, attempts,
  revisions) is unreachable.
- Roles can't be self-assigned or escalated. The owner bootstrap is not
  callable through the API. A disabled member loses access immediately
  while their data is kept.
- Invitations: wrong, expired, revoked, other-email, unconfirmed-email
  and reused tokens are all refused. Repeated acceptance creates one
  membership. Rate limiting works. Tokens are stored hashed.
- App rules: numbering, the 1,000 limit, idempotent completion and EXP,
  stale-edit refusal, reordering, memories and photos, regress (with
  retry), read-only archived journeys, import round trip, repeatable
  import, all-or-nothing import, and pull with tombstones.

I also checked the suite against deliberately broken copies of the
schema (an items read policy of `true`, and an API function without its
ownership check). The isolation tests failed on both, as they should.

**Not yet tested:** a real Supabase project (Auth, PostgREST and Storage
together), and the sign-up hook as configured in the dashboard. The
stub reproduces `auth.uid()`, roles, default grants and `storage.objects`
policies, but it is not Supabase itself. Run the suite against
`supabase start` (below) before relying on it.

## Migrating a phone's archive

The phone's archive is personal data, so the migration is explicit and
conservative (`CloudMigration`):

1. It reads the archive as the backup `data.json` (the same, already
   documented and validated format) and sends it to `import_archive`.
   That is one database transaction: everything is stored or nothing is.
2. It asks `archive_files` which files the cloud expects and whether they
   are stored, then uploads only the missing (or wrong-sized) ones to
   `<user id>/<same relative path>`.
3. It verifies by reading the cloud copy back (`export_archive`) and
   comparing it record by record: every id, number, position, text, date,
   hashtag and timestamp. It then checks every file again. Only then is
   the migration marked `verified` in `archive/cloud_migration.json`.

- **The phone's data is never modified or deleted.** It stays the
  working copy until the user chooses to switch.
- **Repeatable and resumable:** an interrupted run is finished by running
  it again. Records already stored are skipped (never overwritten), and
  files already uploaded are not uploaded again.
- **Refuses to merge:** if the account already holds a *different*
  archive, it stops with `cloud_has_other_data`. This is the same rule as
  backup import. A brand-new account's empty Journey 1 doesn't count.
- **Photos already missing on the phone** are listed, not fatal, as they
  are in backups.
- **Limitation:** files are verified by size, not checksum.
- **Fallback:** the backup `.zip` keeps working as before. The cloud's
  `export_archive` produces the same `data.json` format.

Tests: `test/cloud_migration_test.dart` (9 tests). It covers the full
migration, interruption and retry without duplicates, uploads that
silently fail, a cloud copy that differs, a damaged cloud file, photos
missing on the phone, timestamp normalisation, and a check that the
phone's snapshot has exactly the fixture's shape (the same fixture the
SQL tests import and export).

## Setup

You need: a Supabase project (the free tier is enough), and for running
the tests locally either the Supabase CLI with Docker, or any PostgreSQL
15+ with Python 3 and `pip install pg8000`.

### 1. Create and link the project (manual, in your Supabase account)

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                 # applies supabase/migrations in order
```

Or paste the four migration files, in order, into the SQL editor.

### 2. Configure Auth (Dashboard → Authentication)

- Keep **Confirm email** on (invitations require a confirmed email).
- Set **Site URL** / redirect URLs to the web app's address when it
  exists.
- Sign up with your own email, then in the SQL editor run:
  `select private.bootstrap_owner('you@example.com');`
- Optional, after that: Authentication → Hooks → *Before User Created* →
  Postgres function `public.hook_before_user_created`.

### 3. Invite a friend (later from the web admin page; for now SQL)

Signed in as the owner, the web app will call:
`select * from create_invitation('friend@example.com');`. Send the
returned token privately. After signing up with that email, the friend
calls `redeem_invitation(token)`.

### 4. Environment

Copy `.env.example` to `.env`. Clients only ever need `SUPABASE_URL` and
the **publishable (anon) key**. RLS is what protects data, so this key
is safe to ship. The service-role key must never go into the phone app,
the web bundle, or git.

### Running the database tests

```bash
pip install pg8000
# plain PostgreSQL (creates and drops its own test databases):
python supabase/tests/run_tests.py --stub --dsn postgresql://postgres@127.0.0.1:5432/postgres
# or against a local Supabase stack:
supabase start && supabase db reset
python supabase/tests/run_tests.py --dsn postgresql://postgres:postgres@127.0.0.1:54322/postgres
```

Never point the tests at the production database.

## What's left (next phase)

1. ~~Create the Supabase project and apply the migrations.~~ Done
   2026-10-12, owner account set up the same day.
2. Run the tests against `supabase start` or a staging project.
3. Phone: add `supabase_flutter`, a sign-in screen, an implementation of
   `CloudArchiveApi`, the migration screen, and cloud mode for
   `AppStore`. This also means adding the INTERNET permission to the
   release build and updating `docs/PRIVACY.md` and the README, because
   the "no network" promise changes. Cloud mode must stay opt-in.
4. Web app (see `docs/WEB_PLAN.md`).
