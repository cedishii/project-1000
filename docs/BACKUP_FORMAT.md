# Backup format

A Project: 1000 backup is a standard `.zip` file that any computer can
open. It is designed to stay readable for decades, by this app or by
anyone writing their own tool.

```text
1000-things-backup-2026-10-05-1617.zip
├── manifest.json      what this backup is, versions, checksums
├── data.json          every journey, memories, profile and settings
├── photos/<id>.jpg    full-size photos
├── thumbs/<id>.jpg    thumbnails
└── profile/<id>.jpg   profile pictures (current, and one kept with each
                       archived journey)
```

Photos are stored without extra compression (they are already JPEG), so
they can be copied straight out of the zip.

## manifest.json

```json
{
  "format": "project-1000-backup",
  "backupFormatVersion": 1,
  "dataFormatVersion": 2,
  "appVersion": "1.1.0+2",
  "exportedAt": "2026-10-05T16:17:12.552637Z",
  "counts": { "journeys": 1, "items": 5, "memories": 1, "photos": 2 },
  "data": { "file": "data.json", "sha256": "…", "size": 2723 },
  "files": {
    "photos/433e5a9d-….jpg": { "sha256": "…", "size": 54462 },
    "thumbs/433e5a9d-….jpg": { "sha256": "…", "size": 7922 }
  },
  "missingAtExport": []
}
```

| Field | Meaning |
|---|---|
| `format` | Always `project-1000-backup`. |
| `backupFormatVersion` | Version of the zip layout and manifest. |
| `dataFormatVersion` | Version of `data.json`'s structure. |
| `appVersion` | App version that made the backup (information only). |
| `exportedAt` | UTC time of export. |
| `data` | SHA-256 and size of `data.json`. |
| `files` | SHA-256 and size of every photo and thumbnail. |
| `missingAtExport` | Photo files the database referred to but that were not on the device at export time. |

## data.json

Version 2 (app 1.1 and later). Each journey holds its own list:

```json
{
  "dataFormatVersion": 2,
  "settings": { "theme_mode": "dark" },
  "profile": {
    "name": "…", "nickname": "…", "age": 25,
    "startedOn": "2026-10-06", "bio": "…",
    "photo": "profile/2f1c….jpg", "updatedAt": "…"
  },
  "journeys": [
    {
      "id": "…", "number": 1, "status": "archived",
      "startedOn": "2026-10-06", "completedOn": "2031-06-14",
      "snapshot": { "name": "…", "bio": "…", "photo": "profile/9a0b….jpg" },
      "createdAt": "…", "archivedAt": "…",
      "items": [ /* as below */ ]
    },
    {
      "id": "…", "number": 2, "status": "active",
      "startedOn": "2031-06-15", "completedOn": null, "snapshot": null,
      "createdAt": "…", "archivedAt": null,
      "items": []
    }
  ]
}
```

- `profile` may be `null`. `snapshot` is the profile as it was when the
  journey was archived (shown in its Life Album).
- Exactly one journey is `active`. Journey numbers are unique.
- EXP, levels and percentages are not stored; they are calculated from
  `isCompleted`.

Each item in a journey's `items` (this was the top-level `items` list in
version 1):

```json
{
  "items": [
    {
      "id": "b4fea9fa-344c-4be8-b7b4-4abca453bf16",
      "number": 27,
      "position": 0,
      "title": "Watch the Northern Lights",
      "description": "Someday I want to see them with my own eyes.",
      "isCompleted": true,
      "completedOn": "2032-09-18",
      "createdAt": "2026-10-05T16:03:54.113790Z",
      "updatedAt": "2032-09-19T08:00:00.000Z",
      "memories": [
        {
          "id": "…",
          "position": 0,
          "title": "Finally saw them",
          "text": "I finally saw them after years of wanting to.",
          "date": "2032-09-18",
          "location": "Iceland",
          "hashtags": ["travel", "iceland", "dream"],
          "createdAt": "…",
          "updatedAt": "…",
          "photos": [
            {
              "id": "433e5a9d-…",
              "position": 0,
              "file": "photos/433e5a9d-….jpg",
              "thumb": "thumbs/433e5a9d-….jpg",
              "width": 2560,
              "height": 1707,
              "createdAt": "…"
            }
          ]
        }
      ]
    }
  ]
}
```

### Rules

- **Order.** `items` are written in the user's list order, and each
  item's `position` is stored too. Import restores positions exactly.
  Memories and photos also carry their `position`.
- **Identity.** `id`s are UUIDs and never change. IDs are unique across
  items, memories and photos.
- **Numbers.** `number` is 1–1000 and unique within its journey. It
  belongs to the item and is not its place in the list.
- **Dates.** `completedOn` and memory `date` are calendar dates
  (`YYYY-MM-DD`, no time zone), so they never shift when you travel.
  `createdAt`/`updatedAt` are UTC ISO-8601 timestamps.
- **Completion history.** `completedOn` may be set while `isCompleted`
  is `false`. That means the item was completed once and later
  un-marked; the date is kept on purpose.
- **Hashtags** are stored lowercase, without `#`.
- **Paths** are always `photos/<name>`, `thumbs/<name>` or (profile
  pictures) `profile/<name>`. Anything else is rejected.
- **Version 1** backups (one list, no profile) are imported as Journey 1,
  in progress.

## How import validates a backup

Nothing in the current archive is touched until every step passes:

1. The file opens as a zip and contains `manifest.json` with
   `format = project-1000-backup`.
2. `backupFormatVersion` and `dataFormatVersion` are not newer than the
   app supports. Newer backups are refused with "please update the app".
3. `data.json`'s SHA-256 matches the manifest, and the JSON parses.
4. Structure and consistency: exactly one active journey, at most 1,000
   items per journey, unique IDs and numbers, valid dates and
   timestamps, safe photo paths.
5. Every photo and thumbnail is extracted into a separate
   `archive_incoming/` folder and its size and SHA-256 are checked.
6. If photos are missing or damaged, the user is told how many and may
   still import everything else. A missing full photo with a good
   thumbnail is kept at thumbnail quality; a photo with neither file is
   left out.
7. The user confirms (with the option to back up the current list
   first).
8. A new database is built inside `archive_incoming/`.
9. The live `archive/` folder is swapped with `archive_incoming/` by
   directory renames, recorded by a `swap.json` marker. If the app is
   killed mid-swap, the next launch puts the previous archive back.

## Versioning

- Old backups must always remain importable. When the format changes,
  bump the relevant version and add a conversion step in
  `lib/services/backup/import_service.dart` (`_migrateData`).
- The database schema has its own version (`lib/data/database.dart`)
  with step-by-step migrations; backups are independent of it.
