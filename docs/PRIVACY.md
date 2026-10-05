# Privacy

Project: 1000 is a personal journal. Privacy is a core feature.

## What the app does not have

- No account or login
- No cloud sync or server; the developer never receives your data
- No advertising
- No analytics, crash reporting or telemetry
- No social features
- No network access at all: the Android release build does not request
  the `INTERNET` permission, so the system would block any connection

## Where your data is

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
