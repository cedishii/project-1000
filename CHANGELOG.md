# Changelog

## Unreleased: accounts and the website

- **Optional Project: 1000 account:** sign in, create an account (for
  approved emails), reset or change your password
- **Website:** the same app in any browser, with the same look, kept at
  a readable width on large screens
- **Copy this phone's list to my account:** every journey, memory,
  hashtag and photo, checked record by record afterwards. Nothing on
  the phone changes, and it can be repeated without duplicates
- **Use my account on this phone:** the same list as the website,
  refreshed when you return to the app. Switch back to the phone's own
  archive at any time
- **Owner page:** approve friends' emails, withdraw approvals, disable
  or re-enable accounts. It never shows anyone's list
- Privacy enforced by the database: nobody else (including the owner)
  can read your list, memories or photos
- Android asks for internet access, used only by the optional account

## 1.1.0 — Profile, levels, journeys and the Life Album

- **Profile:** name, nickname, age, started date, bio and a profile
  picture (chosen and cropped on the phone, never uploaded)
- **EXP and levels:** every completed thing is worth exactly 1,000 EXP;
  every 10 things is a level, up to Level 100 at 1,000 / 1,000. Always
  derived from the list itself, so it can't drift or be farmed
- Level progress and journey progress on the Profile, a compact level
  row on Home, milestone markers, and a brief level-up note
- **Journeys:** reaching 1,000 / 1,000 shows a completion screen; you
  choose if and when to archive the journey and begin the next, reusing
  your list or starting a new one. Archived journeys are kept in full,
  read-only, in Journey History, with lifetime totals
- **Life Album:** a book-like album of each journey's completed things
  and memories, in the list's own order, with photos first
- **Life Album PDF** that opens anywhere without the app
- Backups now include every journey and the profile (format version 2);
  1.0 backups still import
- Updating from 1.0 keeps all data: the list becomes Journey 1

## 1.0.0 — first release

- Empty personal list of up to 1,000 things, each with a permanent
  number (#001–#1000)
- Your order is never changed automatically; manual reordering by drag,
  arrows or "move to place"
- Completion with chosen dates (kept on record if un-completed)
- Memories with title, text, date, location, hashtags and photos
- Search and Completed / Not completed filters that never change order
- Progress: completed, remaining, percentage
- Full backup to a single .zip file and verified restore on any phone
- Light, dark and system themes
- Fully offline: no account, no network, no tracking
