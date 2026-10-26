# Privacy Policy / 隐私说明

ShortcutSense is local-only software. This file states exactly what is stored and
what is never stored.

## What is stored, on your Mac only

| Table | Contents |
|---|---|
| `daily_combo_stats` | date, app bundle id, normalized `Command`/`Control` combination id, count |
| `daily_app_activity` | date, app bundle id, anonymous keystroke total, activations by origin class |
| `menu_action_stats` | date, app bundle id, static menu command id, its existing shortcut, verified-click or manual-mark count |
| `recommendations` | the suggestion shown to you and its status |
| `registered_shortcuts` | the hotkeys you applied, with the Carbon `OSStatus` of the last registration attempt |
| `applied_shortcut_usage_daily` | date, shortcut id, trigger count, confirmed activation count |
| `weekly_reviews` | period, generation time, preview flag |
| `excluded_apps` | bundle ids you or the defaults excluded |
| `app_metadata` | schema version, first-collection time, time zone, pause and AI flags |

## What is never stored

- Text you type, in any form.
- Key codes for ordinary character keys. They contribute only to an anonymous total.
- Sequences of keys, or timestamps per keystroke.
- Window titles, document names, file paths, URLs, page content.
- Clipboard contents.
- `AXValue` of any element, or any accessibility content beyond menu role, static
  menu title and menu shortcut metadata for allow-listed applications.
- Passwords, or anything typed while Secure Input is active.
- Screenshots, audio, or screen recordings.

## When collection stops

Collection stops immediately and nothing is written when any of these is true:

- you pause it from the menu bar or Settings;
- the screen is locked;
- Secure Input is enabled by the frontmost app;
- the frontmost app is excluded (defaults include password managers, the login
  window, System Settings, and terminal-class apps);
- Input Monitoring permission is missing or has been revoked;
- the frontmost application cannot be determined.

The rule is fail-closed: an unknown state is treated as "do not record".

## Network

There is no account, no sync, no analytics, no crash reporting, and no update check.
The only outbound request the app can make is an HTTP POST to a **loopback** address
(`127.0.0.1` or `::1`) when you explicitly enable the optional local AI. That request
contains a fixed aggregate JSON — app display name, 7-day activation count, origin
label, active day count, proposed shortcut, conflict status, confidence. No typed
text, titles or paths are ever included.

## Export

Export is manual and contains only the aggregate tables listed above. It is written
wherever you choose. Deleting your data inside the app does not delete files you
exported yourself.

## Deletion

Settings → *Delete all local data* removes every row, checkpoints the SQLite WAL
(so deleted values are not left in `-wal`/`-shm`), and vacuums the database.

## Contact

Open an issue on the project repository.
