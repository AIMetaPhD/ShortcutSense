# Acceptance Status (23 core AC)

**As of:** 2026-11-08 · **Version:** v0.1.0 · **Repository:** `AIMetaPhD/ShortcutSense` (private)

**Legend**

- **PASS** — executed and observed, with the evidence named in the row.
- **PARTIAL** — the main path was executed; the row names the sub-check that was not.
- **NOT-RUN** — executable but not executed.
- **BLOCKED** — cannot be executed in the current environment.
- **FAIL** — executed and failed.

Real-Mac rows were observed by the owner on the target MacBook Air (macOS 26.6.2,
arm64, Swift 6.3.3, Command Line Tools only) or by tools running under the app's own
TCC identity. Muse has no macOS desktop, so every GUI row it could not execute is
marked as such rather than being reported as PASS.

| ID | Requirement | Status | Evidence / reason |
|---|---|---|---|
| AC-01 | macOS-only build | **PASS** | Built and launched on the owner's Mac; process alive, database created. Also builds on the macOS 15 and macOS 26 CI runners. No Windows/Linux product code in `Sources/`. |
| AC-02 | Legal compliance | **PASS** | Root MIT `LICENSE`. `THIRD_PARTY_NOTICES.md` lists upstream commits and states no code was copied. HotkeyClash was never cloned. |
| AC-03 | Fully local | **PASS** | No package dependencies. The only network path is `OptionalAI`, off by default, restricted to literal loopback (`127.0.0.1`, `::1`), no redirects, no cookies. Tests prove no call is made while disabled. |
| AC-04 | Authorisation boundary | **PASS** | Both grants exist in TCC for the app itself: `kTCCServiceListenEvent=2`, `kTCCServiceAccessibility=2`, requested from the GUI session. Collection started (`first_collection_started_at` written). Grants survive rebuilds because signing uses a fixed certificate. *Not exercised:* revoke-while-running, sleep/wake, lock screen. |
| AC-05 | No keystroke leakage | **PASS** | A canary string typed on the real Mac is absent from the `.sqlite`, `-wal` and `-shm` files. Every text column holds only bundle identifiers and normalised combo ids. Secure Input, lock and foreground app are re-evaluated before **every** key event (D-006), so a password field gaining focus between polls cannot be counted. |
| AC-06 | Verifiable aggregation | **PASS** | Live on the Mac: `daily_combo_stats` gained ⌘V ×3, ⌘C ×2, ⌘Tab ×1 across two applications; `events_seen=19`, `command_shortcut=6`, `text_input=13`, `dropped=0`. Every stored `combo_id` matches `kc[0-9]*-m[0-9]*`. |
| AC-07 | Pause / exclude / delete | **PASS (logic) / NOT-RUN (GUI)** | Tests prove zero writes while paused or excluded, and that delete clears every table, checkpoints the WAL and leaves no canary behind. The Settings controls exist but the delete button has not been pressed on the real Mac. |
| AC-08 | 7/14 + activeDays | **PASS** | Fixtures at 6/7/13/14, seven-on-one-day, plus DST and time-zone bucket tests. |
| AC-09 | No meaningless single-key suggestions | **PASS** | Classification tests cover 10,000 spaces and lone letters; text keys can never become combo rows. Option-only combinations classify as text input. |
| AC-10 | Semantic honesty | **PASS (logic) / PARTIAL (AX)** | `unknown_origin` is never rendered as a click; manual marks carry no count. Menu hit-testing measured **18/18** with synthetic clicks through the AX API. A **human** mouse click has not been measured; the gap is stated in the UI copy and in `docs/release/G-A-B-C-status.md`. |
| AC-11 | Four conflict states | **PASS** | 14 resolver tests; ⌘Tab/Spotlight/screenshot combinations resolve as global, ⌘Q/W/H/M as app-scope high risk, unreadable sources resolve to `unknown`, never to "free". `com.apple.symbolichotkeys` was read successfully on the real Mac. |
| AC-12 | Real one-click apply | **PASS (logic) / NOT-RUN (physical)** | A fake backend proves a failure (`-9878`) is surfaced and nothing is stored; the conflict gate blocks non-clear states. `RegisterEventHotKey` returns `noErr` on the real Mac. A physical key press reaching a target application has not been recorded. |
| AC-13 | Restore and undo | **PASS (logic)** | Restore re-registers, marks failures with the `OSStatus`, is idempotent and skips missing targets; undo releases and starts the cool-down. Workspace restore uses the full member list (a real defect was fixed here). |
| AC-14 | Weekly report | **PASS (logic) / NOT-RUN (data)** | `<7 days` → preview, `≥7 days` → final, one row per period, real generation time recorded. No seven consecutive days of real data exist yet, so the app correctly shows Preview. |
| AC-15 | No AI dependency | **PASS** | Core paths make no AI call; the template fallback is deterministic and tested. |
| AC-16 | Local AI minimal grant | **PASS** | End-to-end against a real Ollama: discovery found `qwen3.5:9b` and `qwen3:14b`; one `/api/generate` returned in 9.4 s with `used_fallback=false`. The owner confirmed the UI state (`已连接，检测到 2 个本地模型`, `qwen3:14b (9.28 GB)`, 20,260 ms). Only the 9 fixed aggregate fields are sent. |
| AC-17 | README reproducible | **PASS** | `README.md` documents build, signing, permissions, install and data deletion in English and Chinese. |
| AC-18 | CI & tests | **PASS** | **250 tests, 0 failures** on the real Mac and in CI. CI runs Linux core plus macOS 15 and macOS 26 build/test/bundle/signature jobs. `Scripts/check-test-registry.sh` fails CI if a test file is not registered, after two suites were silently skipped once. |
| AC-19 | Installable release | **PARTIAL** | `Scripts/package-dmg.sh` produces a DMG; `codesign --verify --deep --strict` passes. A clean-machine install through Gatekeeper's "Open Anyway" flow has **not** been performed. |
| AC-20 | Public GitHub completion | **PASS** | `AIMetaPhD/ShortcutSense` is public, with a description and topics. History was rewritten before publication to remove account names, machine names and LAN addresses. |
| AC-21 | User privacy autonomy | **PASS (logic) / PARTIAL (GUI)** | Pause, exclusions, deletion, offline and AI-off are implemented and unit-tested; the owner exercised the AI switch and the main screens. Destructive controls were not pressed on the real Mac. |
| AC-22 | Adoption tracking | **PASS** | A real double-count defect was found by tests (handler and activation both incremented) and fixed; 5 presses → `trigger_count=5`, activations counted only from notifications. |
| AC-23 | Release safety | **PARTIAL** | Signed with a **self-signed certificate**; on the real Mac `valid on disk` and `satisfies its Designated Requirement`, and the requirement is `identifier "com.aimetaphd.shortcutsense" and certificate root = H"340125…"` — stable across rebuilds, unlike ad-hoc. Not notarized (no Apple identity on the machine). *Remaining:* Gatekeeper "Open Anyway" from a fresh copy. |

## What is still unverified

1. **Human mouse clicks on menu items.** The 18/18 result came from synthetic clicks
   delivered through the AX API. It proves the API can identify an item at its own
   coordinates at click time; it does not prove a person's hand behaves identically.
2. **Gatekeeper clean install.** The DMG is produced and signed, but it has not been
   opened from a quarantined copy on a machine that has never seen the app.
3. **Seven consecutive days of real data.** Until then Weekly Review correctly shows
   Preview, and final-report behaviour is covered only by fixtures.

None of these three is claimed as PASS anywhere in this repository.

## Defects found and fixed during this work

| # | Defect | Found by | Fix |
|---|---|---|---|
| 1 | Managed-hotkey presses were counted twice (handler *and* activation notification) | `testManagedHotkeyIsCountedOncePerPressAndOncePerActivation` | `handleTrigger` increments only `trigger_count`; successful activation comes solely from the activation observer |
| 2 | A user exclusion could overwrite a built-in sensitive-app exclusion, silently un-excluding a password manager | `testExclusionSourcesAreDistinct` | Upsert only refreshes rows whose source is `user` |
| 3 | `restoreOnLaunch` re-registered an already-live hotkey when called twice | `testRepeatedRestoreIsIdempotent` | Skip rows the backend already holds |
| 4 | Rollback path on persistence failure was unreachable in tests | `testPersistenceFailureRollsBackTheRegistration` | Fault-injection hook plus assertion that the registration is released |
| 5 | CI-only: script exec bit, SQLite headers, Swift 5.10 actor isolation | GitHub Actions | See `docs/release/verification.md` |
| 6 | **Secure Input / lock state were polled only every 2 s**, so a password field gaining focus between polls could still count keystrokes | Design review while writing the test matrix | `CapturePipeline.refreshVolatileState` re-evaluates secure input, lock and foreground app before every key event |
| 7 | The AI layer had **no real HTTP transport** — only the test double — so "enable AI and get an explanation" could not work at all | Self-review before packaging | Real `URLSession` transport: ephemeral session, no redirects, no cookies, hard timeout |
| 8–18 | Eleven further defects from an independent review, including three S1 issues: the CG/Carbon modifier-bit confusion that made all shortcut capture dead, OS hotkeys surviving data deletion, and a failed unregister orphaning a grab | Independent review agent | See `docs/qa/defects.md` D-007 … D-017 |
| 19–40 | Later rounds: launch window never appearing, TCC never requested, Ollama switch never calling the model, hard-coded model name, 12 s timeout vs 12.6 s cold load, thinking-model empty response, 16 KiB cap applied to the wrong payload, and a title allowlist that let `Claude Code`/`Untitled` through | Real-Mac sessions and measured menu inventories | See `docs/qa/defects.md` |
