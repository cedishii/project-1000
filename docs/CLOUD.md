# Cloud accounts and sync (foundation)

Status: **built, tested and released (v1.4.0, website live).** The backend runs on the
project's Supabase database. The app (same code for Android, iOS and
the web) can sign in, keep a list in the account, and copy a phone's
list there with verification. On the phone the account is optional,
and without signing in nothing changes and nothing connects. The phone app with these
features is v1.2.0, and the website is at https://1000-things.vercel.app.

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
| Friends, sharing choices and what friends may read (see [FRIENDS.md](FRIENDS.md)) | `20261013000100_friends.sql` |
| Merging a backup or a phone's list into an account; live change signals | `20261013000200_merge_and_live.sql` |
| Backups in memory (website), export and merge of an account | `lib/services/backup/backup_bytes.dart`, `lib/services/cloud/cloud_backup.dart` |
| Live updates (Supabase Realtime) | `lib/services/cloud/live_updates.dart` |
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

The server is the source of truth.

- **Website:** online. It calls the functions above directly
  (`CloudArchive`).
- **Phone signed in (`SyncedArchive`):** the phone keeps a full copy of
  the account in its own SQLite database (same format as its own
  archive, in `cloud_cache/<user id>/`), so the list opens and can be
  changed offline:
  - Every change is made in the copy first and appended to an outbox
    (`outbox.json`, on disk, survives restarts).
  - When the account can be reached (after each change, when the app
    returns to the foreground, every minute while waiting), the outbox
    is sent in order with the same retry-safe functions, keeping every
    id. Then the copy catches up through `pull_changes` (rows and
    tombstones since the last revision).
  - The server's changes are applied only while nothing is waiting to
    be sent, so a change made on the phone is never overwritten before
    it has reached the account.
  - A change is skipped only when the account definitely refuses it
    (e.g. the thing was deleted on the website meanwhile). The copy is
    then rebuilt from the account so both sides match. Temporary
    problems (offline, a storage error) keep the change waiting.
  - If the account numbered an offline-added thing differently (the
    website took that number), the copy is rebuilt with the account's
    numbers.
  - The same thing edited on two devices while one was offline: the
    last edit to reach the account wins.
  - Starting a new journey needs a connection.
  - Signing out deletes the copy, with a warning first if changes are
    still waiting.
- **Live updates:** an open app (phone or website) subscribes through
  Supabase Realtime to its own account's row in `sync_heads`, which the
  server bumps on every change to the archive (row-level security: no
  other account's signal is delivered, and the signal carries no data).
  On a signal the phone syncs and the website reloads, usually within a
  few seconds. When the subscription reconnects after the phone was
  offline, the phone syncs at once, sending its waiting changes. Nothing
  depends on a signal arriving: apps still catch up on start, when they
  return to the foreground, after each change and every minute while
  changes wait.
- **No duplicates:** new records use client-generated UUIDs, and
  repeated calls return the existing record.

Tested live (`test/cloud_sync_live_test.dart`): offline changes,
restart while offline, a numbering conflict with the website, an edit
to something deleted elsewhere, photo upload after reconnecting, EXP
counted once; and on the Android emulator in airplane mode.

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

**On the live project (2026-10-12):** `supabase/tests/live_smoke.sql`
runs in one transaction that is rolled back, so it leaves nothing behind.
It uses throwaway accounts, the real owner, Supabase's own roles, RLS and
storage policies. Run it with
`supabase db query --linked -f supabase/tests/live_smoke.sql`. Result:
**SMOKE OK** (invitations, single use, cross-account isolation for a
member, the owner and a stranger, storage folders, role escalation,
anonymous access, disabling, and EXP awarded once). A deliberately wrong
variant fails, as it should. Supabase's advisor (`supabase db advisors
--linked`) reports no errors. Its warning that signed-in users can
execute the SECURITY DEFINER functions is intentional (they are the API
and check membership themselves). Also consider enabling leaked-password
protection (Authentication → Policies, if your plan offers it).

Real Supabase blocks deleting `storage.objects` rows with SQL
(`protect_objects_delete`), so clients delete files through the Storage
API, as designed.

**Not yet tested:** the sign-up hook as configured in the dashboard. The
stub reproduces `auth.uid()`, roles, default grants and `storage.objects`
policies, but it is not Supabase itself. Run the suite against
`supabase start` (below) before relying on it.

## Connecting a phone to an account

Settings → Account → **Connect this phone to my account**. It also opens
by itself right after signing in on a phone that has its own list.
`ConnectScreen` first compares both sides, without changing anything,
and offers only what is safe:

| The account | What it offers |
|---|---|
| is empty | **Copy to my account**: the exact copy below, checked record by record |
| already has everything on the phone | Use the account |
| has other things too | A preview of the **merge** (below), or use the account without copying |
| has a different history of finished journeys | Use the account without copying, or keep the phone's list |

Before anything is sent, a backup of the phone's list is saved on the
phone (`safety_backup/`, and it can be shared from the result screen).
The phone's own archive is never changed. Signing out brings it back.
Afterwards the phone switches to the account, and changes then sync
both ways, including offline changes (see Sync strategy).

## Merging (import into an account that has its own list)

`merge_archive(data, apply, match_titles)` handles both a backup
imported on the website or a signed-in phone, and a phone connecting to
an account that already has things. It only adds; it never removes or
rewrites what the account holds.

- **Same id, same record:** importing or connecting the same list again
  adds nothing. No duplicates, and EXP is never counted twice because it
  is derived from the completed count.
- **Things** of the source's current journey join the account's current
  list, after its own, in the source's order.
  - A thing whose id is already there, or (optional, on by default) with
    the same title, counts as the same thing.
  - Its missing memories and photos are added.
  - If the source has it done and the account doesn't, it becomes done
    with the source's date.
  - Its text stays as the account has it.
- **Numbers** are kept unless the account already uses one; then the
  thing gets the lowest free number.
- **Finished journeys** are added when the account has none of its own
  (the current journey's number moves after them). Two different
  histories are refused (`history_conflict`).
- **Profile** only fills an empty one. **Settings** are only added for
  keys the account doesn't have.
- **Preview:** `apply = false` does exactly the same work in a
  sub-transaction and rolls it back, so the preview can't differ from
  what applying does.
- **Afterwards:** the client uploads the photo files the account is
  missing, then verifies with a second dry run that reports "nothing to
  add", and by checking every file.

Tests: 7 database tests (empty account, twice, own list, histories, bad
files and other accounts' ids, the 1,000 limit, live signal) and
`test/cloud_backup_live_test.dart`.

## Import and export on the website

Settings → Data, on the website and on a phone signed in to an account:

- **Export backup:** the account as the same `.zip` the phone app makes
  (`data.json` version 2, manifest with SHA-256 checksums, photos), so
  it imports on any phone. Built in memory (`encodeBackupBytes`).
- **Import backup:** a backup from a phone or the website.
  - The file is checked exactly like on the phone: format, version,
    checksums and data consistency (`readBackupBytes`, using the same
    validator).
  - A preview shows what will be added.
  - Nothing happens until confirmed, and then it merges as described
    above. There is no "replace" on the website: an account's data is
    never wiped by an import.
  - Files larger than 1 GB are refused.
- The phone app's own Export/Import (no account) is unchanged. It still
  replaces the phone's archive after confirmation, as before.

## Copying into an empty account (exact copy)

The phone's archive is personal data, so the copy is explicit and
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
- **Only into an empty account:** if the account already holds a
  *different* archive, `import_archive` stops with
  `cloud_has_other_data`; the connect screen then offers the merge above
  instead. A brand-new account's empty Journey 1 doesn't count.
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

### 3a. Recommended: friends sign up themselves on the website

1. You approve their email: `select * from create_invitation('friend@example.com');`
   (from the web admin page later; the token isn't needed for this path).
2. They open the website, choose **Sign up**, and pick their own
   password. You never learn it.
3. They click the confirmation link Supabase emails them, sign in, and
   the app calls `claim_membership()`, which admits them because their
   confirmed email was approved.

Unapproved, unconfirmed, expired or revoked emails get nothing. With the
optional sign-up hook enabled, unapproved emails can't even create a
login.

### 3b. Or add a friend directly (no token)

1. Authentication → Users → **Add user** → *Create new user*: their
   email and a temporary password, with **Auto Confirm User** ticked.
2. SQL editor: `select private.add_member('friend@example.com');`
3. Give them the temporary password privately and ask them to change it
   at first sign-in (the apps need a "change password" screen for this).
   Until they change it, you know their password and could read their
   memories, which the role rules otherwise prevent.

Re-running `add_member` re-enables a disabled member. The function is
not callable through the API.

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

### Live end-to-end tests

`test/cloud_live_test.dart` runs the app's real cloud code
(`CloudArchive`, `CloudMedia`, `SupabaseMigrationApi`) against a real
project with three throwaway member accounts. It is skipped unless the
`P1000_*` variables listed at the top of the file are set. It covers two
devices on one account (list, order, numbers, EXP, memories, hashtags,
photos, profile and theme), refused stale edits, cross-account isolation,
deletes that leave no orphaned files, and a verified, repeatable phone
migration. It passed against the project on 2026-10-12.

Never use real accounts for it. Create test users with emails like
`p1000-e2e-a@example.test` (the dashboard's *Add user*, auto-confirmed,
then `private.add_member`). Delete them afterwards (Authentication →
Users), which also deletes their rows.

## What's left

Done on 2026-10-12: Supabase project and migrations, owner account,
live security and end-to-end tests, phone sign-in, migration and
account mode (tested on the Android emulator), and the web version
(tested in Chrome).

1. ~~Host the website.~~ Done: https://1000-things.vercel.app (Vercel,
   `web-dist` branch), with Supabase Auth's Site URL and redirect URLs
   set to it and a minimum password length of 8.
2. ~~Release the phone app with the account features.~~ v1.2.0.
3. **Approve your friends' emails** on the Owner page (or with
   `create_invitation`) once the website is up.
4. Optional: enable the sign-up hook, leaked-password protection and a
   custom SMTP sender (Supabase's built-in email is rate-limited and
   meant for testing).
5. Done in 1.3.0: offline editing while signed in (phone), Life Album
   PDF on the website, list and details side by side on wide screens.
6. Done in 1.4.0: Friends ([FRIENDS.md](FRIENDS.md)), connecting a phone
   with a merge preview, import/export on the website, live updates.
7. Later, if wanted: a checksum (not just size) check for migrated
   photos; Life Album PDF fonts for CJK scripts and emoji.
