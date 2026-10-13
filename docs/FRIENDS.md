# Friends and privacy

Friends lets members of the same Project: 1000 (people with an account)
find each other, become friends, and see what each other chooses to
share. It needs an account: the phone's own archive (no account) has no
Friends and never connects anywhere.

Database: `supabase/migrations/20261013000100_friends.sql`. App:
`lib/services/cloud/friends.dart` and the screens `friends_screen.dart`,
`friend_profile_screen.dart`, `friend_list_screen.dart`,
`sharing_screen.dart` and `main_tabs.dart`.

## How it works

1. **Choose a username** (Friends tab, or Settings → Privacy and
   sharing). Until then nobody can find you. That is how existing
   accounts start, so everyone is invisible until they opt in. The
   username (3–20 lowercase letters, digits or `_`, unique) and the
   name shown to others are chosen here. Your profile's real name is
   never used for search.
2. **Find people** by username (prefix) or display name (part), at least
   two characters, at most 20 results. A result shows only the profile
   photo (if its owner shows it), display name and username, plus
   whether you're already friends or a request is waiting.
3. **Send a request.** The recipient sees it under Requests (with a
   badge on the Friends tab) and accepts or declines it. The sender can
   cancel it while it is waiting.
4. **Friends** appear in each other's list. Either of you can remove the
   friendship at any time, and the other isn't told.

## What friends can see

Everything is **off by default** and chosen by the owner:

| Setting | Who sees it |
|---|---|
| Profile photo | People who find you in search, and friends |
| Bio | Friends |
| Start date | Friends |
| Progress (things done and listed, finished journeys) | Friends |
| Level and EXP | Friends |
| Bucket list: **Private** (default) or **Friends only** | Friends, read-only |
| Memories (needs a shared list) | Friends, read-only |
| Where memories happened (needs shared memories) | Friends |

A shared list shows each entry's number, title, description and whether
(and when) it was done, in your order. With **Memories** on, friends can
also open an entry's memories: title, text, date, hashtags and photos,
plus the location if **Where memories happened** is on. Only memories of
your current journey are shown.

Never shared: your real name, nickname, age, finished journeys and their
Life Albums, settings and the account email.

Saving your settings with the list set to Private also turns memories
off, so they never come back by themselves when you share the list again.

## Rules enforced by the database

The app only displays what the server returns. Every rule lives in the
database, so the website, the phone and any direct API call follow the
same permissions.

- **Tables:** `social_profiles`, `friend_requests` and `friendships`
  accept no direct writes from users. Row-level security lets a user
  read only their own settings and the requests and friendships they
  are part of.
- **Functions:** all changes go through security-definer functions that
  check every transition:
  - You can't befriend yourself.
  - Only the recipient can answer a request, and only the sender can
    cancel it.
  - A request that isn't waiting can't be answered (repeating the same
    answer is harmless).
  - There is never more than one waiting request between two people, in
    either direction (a unique index plus a per-pair lock against
    races).
  - A friendship is stored once per pair (primary key with
    `user_low < user_high`).
  - After a decline, the sender must wait 7 days before asking again.
  - Anyone can send at most 50 requests a day.
- **Other people's data** is only reachable through `friend_profile`,
  `friend_list` and `friend_memories`. They check the friendship and the owner's current
  settings on every call. Turning the list or the memories to Private,
  or removing the friend, ends access on the very next request, with no sign-out or
  restart needed. "Private" and "not a friend" give the same refusal, so
  nothing is revealed. Memories are shared only on top of a shared list
  (`private.can_view_memories` requires `can_view_list`).
- **Read-only:** friends can never change each other's lists. Every
  archive function still only touches the caller's own rows. The tests
  call `update_item`, `set_item_completed`, `delete_item`,
  `save_memory`, `delete_memory` and `save_order` on a friend's entry
  and check that nothing changes.
- **Disabled members** disappear from search, friends and requests, and
  their shared data is unreachable.
- **Stop using Friends** (Privacy and sharing) deletes the username,
  every friendship and every request. It never touches the list.
- **Profile photos:** a storage policy lets members who have a username
  read exactly the current profile picture of someone who shows it, and
  nothing else in their folder.
  - **Known limit:** Supabase's CDN keeps serving a file to a viewer who
    already downloaded it, for the same URL and session, for a while
    after it is hidden or deleted.
  - Any new request is checked, and the app stops asking for a hidden
    photo at once, because the server no longer lists it. Only someone
    who already saw the picture can see it again, briefly.
- **Memory photos:** a second storage policy lets a friend read the
  full-size photo and thumbnail of exactly the memories they may see
  right now (current journey, list and memories shared, still friends,
  both active). Nothing else in the folder, and never writes or deletes.
  The same CDN limit applies to a photo someone already opened.

### Ready for per-entry visibility

Every read of a shared list goes through `private.visible_items(owner,
viewer)`. To share or hide single entries later:

1. Add a column to `items`.
2. Filter on it there.

Memories go through `friend_memories`, which looks the entry up in
`visible_items` too, so hiding an entry would hide its memories and their
photos with it.

## Notifications

The badge counts waiting requests. It refreshes when the app opens, when
it returns to the foreground, every minute while open, and after every
Friends action. There are no push notifications.

## Tests

- `supabase/tests/run_tests.py`: 15 Friends tests (on real Postgres roles
  and RLS):
  - Search shows identity only.
  - Usernames are validated and unique.
  - Invalid, duplicate and self requests are refused.
  - Direct table writes and reads are blocked.
  - Profile fields follow the settings.
  - The list is shared only with friends, and access ends at once.
  - Friends can't change each other's entries.
  - The photo policy works as described above.
  - Being disabled or leaving Friends ends sharing.
  - Archives and progress are untouched.
  - Memories are shared only when chosen, only with friends, only with
    a shared list, without the location unless chosen, and access ends
    at once.
  - Only memories (and photo files) of the current journey are shared.
  - Memory photos are readable only while their memory is shared.
  - Saving settings from an older app keeps the memory choices.
- Mutation checks: making each rule deliberately leaky (ignoring the
  list setting, ignoring the friendship, a looser photo policy, an
  ungated bio, a bio in search results) makes the suite fail. The same
  for memories: ignoring the memory setting, skipping the list and
  friendship check, always showing the location, an open photo policy,
  photos of finished journeys, and an older app resetting the choice.
- `test/friends_live_test.dart`: the whole flow against the real project
  with three throwaway accounts, including direct API attempts and
  revocation without signing out.
- `test/friends_screen_test.dart`: the screens with a fake server.
