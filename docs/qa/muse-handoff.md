# QA Handoff — Muse

**Prepared by:** Claude Code (development)
**Date:** 2026-10-26
**Build under test:** staging CI run [40324242517](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40324242517), commit `19aee37`
**Artifact:** `ShortcutSense-macos-14` / `ShortcutSense-macos-15` from that run's artifacts (`build/ShortcutSense.app`)

## Rules for this handoff

1. You are the independent tester. Development does not close a defect you have not
   re-tested.
2. Test through the real GUI on a real Mac. Source reading and unit tests are not
   evidence for a GUI or TCC requirement.
3. If a test cannot be performed, record **BLOCKED** with the reason. Never PASS it.
4. Record every defect in `docs/qa/defects.md` with: steps, expected, actual,
   severity, evidence (screenshot/log path).
5. Write results into `docs/qa/`.

## What is already proven (do not re-test, but do not trust beyond its scope)

130 unit tests pass on Linux, macOS 14 and macOS 15. They prove: privacy
classification, the fail-closed gate, attribution arithmetic, thresholds, conflict
states, registration rollback/restore/undo via a fake backend, weekly preview and
idempotency, and the AI safety envelope. They prove **nothing** about macOS runtime
behaviour.

## Setup

1. Copy `ShortcutSense.app` to `/Applications`.
2. Because the build is **ad-hoc signed and not notarized**, Gatekeeper will block
   the first launch. Use Apple's own flow: try to open it, then System Settings →
   Privacy & Security → **Open Anyway**, then confirm. Do **not** disable Gatekeeper
   or SIP, and do not run `xattr -dr com.apple.quarantine` — record what actually
   happened instead.
3. Launch it. There is no Dock icon; look for a ⌘ item in the menu bar.
4. Record the exact macOS version and whether the app launched.

## Test cases

### QA-01 — First run and permissions (AC-04)

1. With no prior grant, launch the app and open Settings.
2. Note what the Permissions box says before granting anything.
3. Click *Request Input Monitoring*.
4. **Expected:** macOS shows its own prompt or the app appears in System Settings →
   Privacy & Security → **Input Monitoring**, listed separately from Accessibility.
5. Grant it, relaunch, reopen Settings.
6. **Expected:** the app reports Input Monitoring granted; Accessibility still
   reported separately.

Record: whether a prompt appeared, where the app appeared, whether a relaunch was
needed before the status changed.

### QA-02 — Keystroke aggregation (AC-06, AC-09)

1. Open TextEdit, type a paragraph of ordinary text for ~30 seconds.
2. Open the app → Today.
3. **Expected:** an anonymous keystroke total for TextEdit; **no** per-letter rows
   anywhere; Shortcuts tab shows nothing for plain typing.
4. Press ⌘C, ⌘V a few times.
5. **Expected:** `Command+C` / `Command+V` appear with counts.

### QA-03 — Secure input and excluded apps (AC-05, AC-07)

1. Open a password field (e.g. a login page in Safari, or Keychain Access).
2. Type a distinctive string.
3. Check Today and Shortcuts, then inspect the database with
   `sqlite3 ~/Library/Application\ Support/ShortcutSense/ShortcutSense.sqlite
   "select * from daily_combo_stats;"` and `grep -a` the `.sqlite*` files for the
   string you typed.
4. **Expected:** zero occurrences of the string; no combo rows from that typing.
5. Open Terminal. Type commands. **Expected:** Terminal is excluded by default and
   nothing is recorded.
6. In Settings, re-include Terminal knowingly, type, confirm it records; then
   exclude it again.

### QA-04 — Pause and delete (AC-07, AC-21)

1. Pause collection, type for 20 seconds, check Today → no new data.
2. Resume, type, confirm data resumes.
3. Settings → *Delete all local data* → confirm.
4. **Expected:** every tab empty; `~/Library/Application Support/ShortcutSense/`
   contains no residual history (check the `.sqlite-wal` / `.sqlite-shm` too).

### QA-05 — AX menu hit-testing spike (AC-10) — the decisive one

This determines whether automatic Learn ships at all.

1. In Finder, open the *File* menu and click *New Finder Window* with the mouse.
   Repeat 7 times across at least 2 days.
2. Repeat in Chrome with a static menu item (e.g. *File → New Tab*).
3. Also open *File → Open Recent* and click an entry (this must be ignored).
4. Open a Finder window's *Window* menu (dynamic window titles) and click one.
5. **Expected (if supported):** Opportunities shows a Learn card with a *verified*
   count for the static items only; nothing at all for recent items or window titles.
6. If nothing is captured, that is a legitimate outcome — record **BLOCKED/FAIL for
   automatic Learn** with the exact steps. The product then relies on ManualMark and
   the UI must say so.

Record for each app: whether a menu item was captured at all, and the count.

### QA-06 — Launch/Focus recommendation (AC-08, AC-10)

1. Switch to Chrome (or any non-excluded app) at least 7 times across 2+ days,
   using the mouse/Dock only.
2. Open Opportunities.
3. **Expected:** a card that says the origin is **unknown**, with wording that does
   not claim Dock clicks; a proposed `Control+Option+Shift+<letter>`; a conflict line
   that says *no known conflict* and explicitly does not promise the key is free.
4. Dismiss it. **Expected:** it does not reappear for 28 days.

### QA-07 — Apply, physical trigger, undo (AC-12, AC-13, AC-22) — decisive

1. On a card, click *Apply*.
2. **Expected:** the shortcut appears under *Active shortcuts*; no error.
3. Switch to another app so the target is not frontmost.
4. Press the physical key combination.
5. **Expected:** the target app comes to the front.
6. Do this exactly 5 times. Then check Weekly Review / the usage numbers.
7. **Expected:** 5 presses counted; successful activations ≤ 5 and consistent with
   what actually happened.
8. Quit and relaunch the app.
9. **Expected:** the shortcut still works (restored), with no duplicate registration.
10. Click *Undo*. **Expected:** the physical combination no longer activates the app,
    and the row is gone.
11. Try to apply a combination the system owns (e.g. ⌘Space) — the UI must refuse
    before registering.

### QA-08 — Weekly review (AC-14)

1. On a fresh install (no history), open Weekly Review.
2. **Expected:** it is labelled **Preview** and says fewer than 7 days of real data.
3. Do not fabricate seven days. A real seven-day result is a follow-up observation,
   not a release blocker for the algorithm.

### QA-09 — AI off (AC-15, AC-16)

1. Leave local AI off. Disconnect the network. Use statistics, recommendations,
   apply, undo and weekly review.
2. **Expected:** everything works; no error about AI.
3. Enable AI with a non-loopback URL (e.g. `http://192.168.1.10:11434`).
   **Expected:** rejected.
4. With Ollama running on `127.0.0.1`, enable it and request an explanation.
   **Expected:** an explanation, or a deterministic fallback — never a settings change.

### QA-10 — Sleep, lock, permission revocation (AC-04)

1. Lock the screen, type nothing useful, unlock. **Expected:** no records from the
   locked period.
2. Sleep the Mac, wake it. **Expected:** collection resumes; no crash.
3. Revoke Input Monitoring in System Settings while running.
   **Expected:** capture stops, history still visible, status shows the problem.
4. Regrant and relaunch. **Expected:** collection resumes.

### QA-11 — Gatekeeper install (AC-19, AC-23)

1. From a fresh copy in `/Applications`, launch and complete the Open Anyway flow.
2. Record the exact dialogs seen, in order, and whether the app then ran.
3. Run `codesign --verify --deep --strict --verbose=2` and `spctl -a -vv` on the
   installed copy; paste both outputs.

## Reporting format

For each case: `QA-xx | PASS/FAIL/BLOCKED | macOS version | steps | expected |
actual | evidence path`. Put defects in `docs/qa/defects.md` and the run log in
`docs/qa/run-<date>.md`.
