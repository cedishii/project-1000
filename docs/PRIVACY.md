# Privacy

Project: 1000 is a personal journal. Privacy is a core feature.

## What the app does not have

- No advertising
- No analytics, crash reporting or telemetry
- No public profiles or feeds. With an account you can use Friends
  (below); without one, nobody else can see anything
- No network access unless you sign in to a Project: 1000 account
  (optional, see below). Without an account the app makes no network
  requests at all.

## The optional account

You can sign in to a Project: 1000 account to use your list on the
website and on several devices. Then:

- Your list, memories, hashtags, photos and profile are stored in the
  project's database and private photo storage (Supabase, region
  ap-south-1).
- Only you can open them. The project's owner manages who has an
  account but cannot see anyone's list, memories or photos, and
  members cannot see each other's. This is enforced by the database
  itself, not just hidden in the app.
- Nothing is copied from your phone until you choose "Connect this
  phone to my account" and confirm what it shows. A backup of the
  phone's list is saved on the phone first. Your phone's own archive stays on the phone,
  unchanged, and you can switch back to it at any time.
- Signing out on a phone returns it to its own archive.

## Friends (optional, with an account)

- Nobody can find you until you choose a username.
- Everything else is off until you turn it on in Privacy and sharing:
  your photo, bio, start date, progress, level, and your list
  ("Friends only", read-only).
- Memories, their photos, your real name, age and journey history are
  never shared.
- Removing a friend or making your list private takes effect
  immediately.
- These rules are enforced by the database. Details:
  [FRIENDS.md](FRIENDS.md).

## Where your data is (without an account)

Your list, memories, hashtags, photos, profile (name, nickname, age,
bio, profile picture) and journey history are stored only in the app's
private storage on your phone. Other apps cannot read it. Life Album
PDFs are created on the phone and only leave it if you save or share
them.

When you add a photo, the app makes its own copy (resized to at most
2560 px). The original in your gallery is not changed or deleted, and
deleting a photo in the app does not touch your gallery.

**Permissions**

- *Android:* photos are chosen with the system photo picker, so the app
  needs no photo or storage permission. Taking a photo uses your camera
  app.
- *iOS:* the app asks for access to your photo library and camera when
  you first add a photo.

## When data leaves your phone

Only when you export a backup and choose where to save or share the
file. The backup is not encrypted, so keep it somewhere you trust.

**System backups**

- *Android:* the system's automatic cloud app-backup is disabled for
  this app. Device-to-device transfer when setting up a new phone may
  still copy the app's data. Use Export/Import to move your archive
  reliably.
- *iOS:* app data is included in your iPhone's iCloud or computer
  backup if you have device backups turned on. This is controlled by
  iOS and encrypted by Apple, not by this app.

## Independence

Every installation has its own separate archive. Nothing is shared
between installations, and the source code repository never contains
anyone's personal data.
