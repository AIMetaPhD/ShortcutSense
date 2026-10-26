# Muse — QA Dispatch

**From:** Claude Code (development)
**Date:** 2026-10-26
**Build under test:** `/Applications/ShortcutSense.app` on the owner's MacBook Air
**Binary SHA256:** `2cea9a6edf20dc5127472dee00db74950a83c1d9bd7c67f0e73dba6502aa1f10`
**Tests:** 154 (not 149; the earlier build was older)
**Signature:** ad-hoc, `TeamIdentifier=not set` (no Developer ID exists on this machine)

You are the independent tester. Development does not close a defect you have not
re-tested. If you cannot perform a test, record **BLOCKED** with the reason — never
PASS it.

Write results to `docs/qa/run-<date>.md` and defects to `docs/qa/defects.md`.

---

## What development has already verified (do not re-test)

These are build and logic checks, not product behaviour:

- `swift build` succeeds on this Mac (macOS 26.6.2, arm64, Swift 6.3.3, Command Line Tools only)
- **154 unit tests pass** via `bash Scripts/test-without-xcode.sh` (XCTest is absent
  without Xcode, so the same test sources run against a shim). `Scripts/check-test-registry.sh`
  now fails CI if a test class is missing from the shim's suite list.
- `.app` assembles; `codesign --verify --deep --strict` passes; thin arm64
- App launches; `~/Library/Application Support/ShortcutSense/` is created with 9 tables,
  `journal_mode=wal`, 13 default exclusions
- `InstallEventHandler` / `RegisterEventHotKey` / `UnregisterEventHotKey` all return
  `noErr` — this is **acceptance only**, not proof a key press arrives

## The blocking fact, established by measurement

TCC attributes a process to its *responsible* process. Every launch so far was made
over SSH, where that responsible process is `/usr/libexec/sshd-keygen-wrapper`
(confirmed in the tccd log). Consequences:

- macOS recorded **no `kTCCServiceListenEvent` row** for `com.aimetaphd.shortcutsense`
  (the system `TCC.db` has only `kTCCServiceAccessibility … |0`), so the Input
  Monitoring pane has nothing to switch on.
- `--diagnose` run over SSH reports the **SSH session's** grants, not the app's. It
  now prints `launched_from_ssh_session` and a note saying so.
- No GUI automation is reachable over SSH either: `osascript` to System Events times
  out (-1712), `screencapture` reports "could not create image from display", AX
  returns -25204, and `launchctl asuser` is denied without root.

**So the app has never run in the Mac's GUI session.** The first step of QA is a human
one: launch ShortcutSense from Finder or the Dock (or from a Terminal window in the
GUI session, not over SSH), and answer the two permission prompts.

## Current state you will start from

```
app          : installed at /Applications, runs, database created (9 tables, WAL)
collection   : nothing — Input Monitoring has never been granted in the GUI session
permissions  : app-context values unknown; the SSH-context probe is not evidence
```

---

## Test cases

Full detail: `docs/qa/onmac-checklist.md`. Summary of what each case decides:

| Case | AC | What would make it FAIL |
|---|---|---|
| QA-01 Grant Input Monitoring, relaunch, re-probe | AC-04 | Grant succeeds but `tap_creation` still `failed` after a real relaunch |
| QA-02 Accessibility + `menu_readable` | AC-04, AC-11 | Granted but menus still unreadable; or readable without permission |
| QA-03 Type in TextEdit, check `daily_app_activity` / `daily_combo_stats` | AC-06 | No rows, or rows that contain typed characters |
| QA-04 Type `ZebraQuokka7731` in a password field, grep the DB/WAL/SHM | AC-05 | **Any** occurrence of that string ⇒ S1, stop and report |
| QA-05 Terminal typing records nothing | AC-07 | Any row with a Terminal bundle id |
| QA-06 Pause / resume / delete-all, then check hotkeys are released | AC-07, AC-21 | Data reappears after deletion, or a deleted hotkey still fires |
| QA-07 Mouse-switch apps 7× over 2 days, apply the card, press the real key 5× | AC-08, AC-10, AC-12, AC-22 | `trigger_count ≠ 5`; or `successful_target_activation_count > trigger_count`; or the card claims "Dock clicks" |
| QA-08 Quit, relaunch, hotkey still works with no duplicate row | AC-13 | Duplicate `registered_shortcuts` rows, or the key stops working |
| QA-09 Undo the hotkey, confirm the key no longer fires | AC-13 | Key still fires |
| QA-10 AX menu hit-test on Finder and Chrome (7 real clicks) | AC-10 | Auto Learn must stay off if no `AXMenuItem` is reliably obtained — record that, do not force it |
| QA-11 Lock screen, sleep/wake, revoke permission while running | AC-04 | Records appear for the locked period |
| QA-12 Gatekeeper "Open Anyway" from `/Applications` | AC-19, AC-23 | macOS refuses even via Open Anyway ⇒ release BLOCKED |
| QA-13 Weekly Review on a fresh install shows **Preview** | AC-14 | It claims a real weekly result with no data |
| QA-14 AI off + network off: everything still works; non-loopback URL rejected | AC-15, AC-16 | Any outbound call with AI off |

## Specific traps to watch for

These are the defects development already found and fixed. Confirm they are really
fixed, because each one failed *silently*:

1. **Shortcut capture.** If ⌘C / ⌘V produce **no** `daily_combo_stats` rows while
   `total_anonymous_keystrokes` rises, the CG↔Carbon modifier conversion is broken
   again (defect D-007).
2. **Deletion.** After *Delete all local data*, press a previously applied hotkey. If
   the app still launches the target, an OS grab outlived the data (D-008).
3. **Undo.** If undo says it succeeded but the key still fires, the unregister path
   dropped its reference (D-009).
4. **Apply failure.** If Apply ever reports an error but a row with `is_active=1`
   exists, the apply is not atomic (D-010).

## Reporting format

```
QA-xx | PASS / FAIL / BLOCKED
macOS: 26.6.2
steps: <what you did>
expected: <...>
actual: <...>
evidence: docs/qa/evidence/qa-xx-*.png | <command output>
```

For anything FAIL or BLOCKED, add an entry to `docs/qa/defects.md` with severity
S1–S4. Do not edit `docs/release/acceptance-status.md` — that is development's file,
and it must only ever reflect evidence you have produced.

## Useful commands

```bash
# capability probe (no user data printed)
/Applications/ShortcutSense.app/Contents/MacOS/ShortcutSense --diagnose

# database
DB="$HOME/Library/Application Support/ShortcutSense/ShortcutSense.sqlite"
sqlite3 "$DB" "select * from daily_app_activity;"
sqlite3 "$DB" "select * from daily_combo_stats;"
sqlite3 "$DB" "select * from applied_shortcut_usage_daily;"
sqlite3 "$DB" "select * from registered_shortcuts;"

# leak check: type a unique string first, then
for f in "$DB" "$DB-wal" "$DB-shm"; do grep -a -c "ZebraQuokka" "$f"; done

# rebuild after a fix
cd ~/ShortcutSense && bash Scripts/build-app.sh && cp -R build/ShortcutSense.app /Applications/
```
