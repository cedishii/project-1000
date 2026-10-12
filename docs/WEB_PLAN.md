# Web version

Status (2026-10-12): **built** with Flutter web from this codebase, as
recommended below, and tested in Chrome against the real project
(sign-in, sign-out, adding and showing items, account isolation, phone
and desktop widths). Not hosted yet. The order of work at the end
records what was done and what is left.

## Recommendation: Flutter web, from this same codebase

| Option | For | Against |
|---|---|---|
| **Flutter web (recommended)** | Reuses the real screens, widgets, theme, models, hashtag parsing and progression code. Looks identical by construction. One codebase. No new framework. | Larger first load (~2–3 MB); web apps built this way feel less "native web" (text selection, browser find). Neither matters much for a private app with four users. |
| React / Svelte / etc. | Lighter, most web-native. | A second UI codebase that has to copy every screen and rule. Introduces a framework the project doesn't use. |

Flutter web needs the same change the phone's cloud mode needs anyway:
`AppStore` must talk to an **archive interface** with two implementations.

```text
AppStore ──▶ ArchiveBackend (interface: the methods AppStore calls today)
               ├─ LocalArchive   = today's ArchiveRepository + PhotoStorage (sqflite, files)
               └─ CloudArchive   = supabase_flutter: rpc(...) + Storage
```

- The phone keeps `LocalArchive` (offline mode), or uses `CloudArchive`
  with SQLite as its cache (cloud mode).
- The web always uses `CloudArchive` (sqflite and `dart:io` files don't
  exist in browsers).
- Code that uses `dart:io` must go behind the interface or conditional
  imports: photo storage, backup export/import, PDF export and avatar
  cropping. On the web the Life Album PDF is built in memory and
  downloaded.

## Feature map (web)

| Feature | Backend |
|---|---|
| Sign in / out, password reset | Supabase Auth (email + password, or magic link) |
| Accept invitation | Sign up with the invited email → confirm → `redeem_invitation(token)` (link: `/invite#<token>`; keep the token in the fragment so it never reaches server logs) |
| List, add, edit, complete / un-complete, delete, reorder | `items` table (read), `add_item`, `update_item`, `set_item_completed`, `delete_item`, `save_order` |
| Memories, hashtags, photos | `save_memory`, `delete_memory`; upload to Storage first; thumbnails in lists, full image only in the viewer, via `createSignedUrl` (e.g. 1 hour) |
| Profile, picture, theme | `profiles`, `settings` (upsert); picture at `profile/<new id>.jpg` |
| EXP, level, % | `journey_progress` view |
| Journeys, regress, Life Album | `journeys`, `start_new_journey` (copy the profile picture in Storage first), `export_archive` for the album |
| Owner admin page | `list_members`, `set_member_status`, `create_invitation`, `revoke_invitation`, `list_invitations`. Show the page only if `members.role = 'owner'` (the server enforces this anyway) |
| Refresh / second device | `pull_changes(last_revision)` on focus, or Supabase Realtime later |

Rules the client must follow: generate UUIDs for new records, pass the
user's **local** date when completing, and send `p_expected_revision`
when editing. On a 409 `stale_revision`, reload and tell the user. On
retry, call the same function again with the same id.

## Design system

The current identity (keep it):

- **Colours:** `design/tokens.json` (`test/design_tokens_test.dart`
  keeps it equal to `lib/ui/theme.dart`). The seed is brand green
  `#6DBE5A`; primary is deep green (light) or `#8FD67C` (dark); secondary
  is plum; blush is the accent. Surfaces are warm "paper" `#FBF8F1` in
  light mode and green-black `#1C2120` in dark mode.
- **Type:** Fredoka (bundled variable font) for numbers, headings and
  buttons, at weight 600 and line height 1.1. App-bar titles are 22,
  buttons 16. The platform font is used for body text.
- **Shapes:** cards have an 18 radius with a hairline outline and no
  shadow; inputs and buttons 14 (filled inputs, no border); chips 10;
  FAB 18. Buttons are padded 22×14 and inputs 16×14.
- **Material 3**, light / dark / system themes (stored in
  `settings.theme_mode`).
- The item number (`#001`) is a key visual element. The list order is
  never changed by the app.

With Flutter web all of this comes from `buildTheme()` automatically.
Another framework would read `design/tokens.json`.

## Responsive layout

Use Material 3 window-size classes. The breakpoints follow what the
content needs, not device names:

| Width | Class | Navigation | Layout |
|---|---|---|---|
| < 600 | compact (phones) | as the phone app today | single column, full-width cards, FAB |
| 600–839 | medium (portrait tablets) | navigation rail | single column, centred, max ~640 px |
| 840–1199 | expanded (landscape tablets, laptops) | rail | **list + detail side by side** (list ~400 px, detail fills the rest); editors in dialogs/side sheets |
| ≥ 1200 | large / extra-large (desktops, wide screens) | extended rail with labels | list + detail, detail capped at ~840 px, extra space as margin; profile shows level and history side by side; photo grids get more columns |

- Never stretch text lines beyond ~75 characters. Cap content widths
  rather than scaling the phone layout up.
- Touch targets at least 48×48. Keyboard: tab order follows reading
  order, visible focus rings (Material default), Enter/Space activate,
  Esc closes dialogs. Keep shortcuts optional (e.g. `/` for search,
  `n` for a new item).
- Contrast: Material 3 roles from the seed meet WCAG AA. Check any custom
  pairs (blush on paper) before using them for text.
- The photo viewer supports arrow keys and fills the viewport. Image
  previews use the thumbnails.
- Test at 360, 412, 768, 1024, 1280, 1440 and 1920 px widths, in both
  themes.

## Configuration and deployment

- Build: `flutter build web --release --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=… --dart-define=P1000_SITE_URL=https://<your site>`
  (publishable values only; see `.env.example`). The output is
  `build/web`. The same defines on `flutter build apk` enable the
  optional account on Android.
- Host the static `build/web` output anywhere static (Vercel, Netlify,
  Cloudflare Pages, GitHub Pages). Add its URL to Supabase Auth → URL
  configuration (Site URL and redirect URLs) and to the Storage CORS
  settings if needed.
- Sessions: supabase_flutter keeps the session in browser storage and
  refreshes tokens. Access tokens expire after 1 hour (default), and
  sign-out revokes the refresh token.
- Hosting must serve `index.html` for unknown paths (SPA routing), or use
  hash URLs.

## Order of work

1. ✔ `ArchiveBackend` with `LocalArchive` (no behaviour change).
2. ✔ `CloudArchive`, `CloudMedia`, `SupabaseMigrationApi`, tested live.
3. ✔ Phone: optional sign-in, verified copy, account mode, refresh on
   return.
4. ✔ Web: platform, branding, centred readable layout on wide screens,
   sign-in/sign-up/reset/change password, Owner page.
5. ☐ Host the website and set its URL in Supabase Auth.
6. ☐ Approve the three friends' emails (owner action).
7. ☐ Later: list-and-detail side by side on wide screens, Life Album
   PDF in the browser, keyboard shortcuts.
