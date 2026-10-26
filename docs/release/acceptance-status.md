# Acceptance Status (23 core AC)

**As of:** 2026-10-27 (after two independent reviews and live capture on the real Mac)
**Legend:** PASS = executed and observed · BLOCKED = cannot execute in the current
environment · NOT-RUN = executable but not yet executed · FAIL = executed and failed

The project rule is that a real-Mac GUI check may only be PASS when Muse has
executed it on a real desktop session. Nothing below claims that.

| ID | Requirement | Status | Evidence / reason |
|---|---|---|---|
| AC-01 | macOS-only build | **PASS** | Built on the owner's MacBook Air (macOS 26.6.2, arm64, Swift 6.3.3, Command Line Tools only) and **launched**: process alive, database created. Also builds on macOS 14 and macOS 15 CI runners. No Windows/Linux product code in `Sources/`. |
| AC-02 | Legal compliance | **PASS** | Root MIT `LICENSE`. `THIRD_PARTY_NOTICES.md` lists upstream commits and states no code was copied. HotkeyClash was never cloned. |
| AC-03 | Fully local | **PASS (static)** | No package dependencies; no Sparkle/sync code. Network surface is one loopback-only HTTP POST in `OptionalAI`, off by default and unit-tested to make no call when disabled. *Not yet:* packet capture on a real machine. |
| AC-04 | Authorisation boundary | **PASS (partly)** | On the real Mac both grants now exist in TCC: `kTCCServiceListenEvent=2`, `kTCCServiceAccessibility=2`, requested via the app's own `CGRequestListenEventAccess`/`AXIsProcessTrustedWithOptions` from the GUI session. Collection started (`first_collection_started_at` written). *Not yet:* revoke-while-running, sleep/wake, lock screen. |
| AC-04-old | (superseded) | **BLOCKED** | Logic tested (fail-closed gate, tap timeout/wake handling in code). The actual TCC prompts, tap creation, and permission revocation need a logged-in Mac desktop. See `docs/verification/macOS-spikes.md` S2/S3. |
| AC-05 | No keystroke leakage | **PASS (logic + live)** | Tests scan the raw SQLite/WAL/SHM bytes and the export JSON for typed text. Live capture on the Mac recorded only counts (`com.google.Chrome` 4 anonymous keystrokes, 2 activations) with no text. Two defects found by that capture are fixed: the consent dialog was counted as an app (D-023) and AI coding tools were not excluded (D-024). Live check: a canary string is absent from `.sqlite`, `-wal` and `-shm`, and every text column holds only bundle ids and combo ids. *Not yet:* typing in a real password field. |
| AC-06 | Verifiable aggregation | **PASS** | Live on the Mac, with the owner typing: `events_seen=19`, `command_shortcut=6`, `text_input=13`, `dropped=0`, and `daily_combo_stats` gained `kc9-m256` (⌘V) ×3, `kc8-m256` (⌘C) ×2, `kc48-m256` (⌘Tab) ×1 across two applications. Every stored `combo_id` matches `kc[0-9]*-m[0-9]*`; the text columns contain only bundle identifiers and normalized combo ids. |
| AC-07 | Pause / exclude / delete | **PASS (logic)** | Tests prove zero writes while paused/excluded and that delete clears every table, truncates WAL and leaves no canary string in any file. *Not yet:* GUI confirmation. |
| AC-08 | 7/14 + activeDays | **PASS** | Fixtures 6/7/13/14, 7-on-one-day, plus DST and time-zone bucket tests. |
| AC-09 | No meaningless single-key suggestions | **PASS** | 10,000-space/letter case covered by classification tests; text keys can never become combo rows. |
| AC-10 | Semantic honesty | **PASS (logic) / BLOCKED (AX)** | `unknown_origin` is never rendered as a click (test asserts the AI template and card copy); manual marks carry no count. AX click capture itself is BLOCKED pending S1 and is disabled by default. |
| AC-11 | Four conflict states | **PASS (logic)** | 14 resolver tests including Cmd+Tab/Spotlight/screenshots as global, Cmd+Q/W/H/M as app-scope high risk, and unreadable sources → `unknown`. *Not yet:* live `symbolichotkeys` and menu reads on a Mac. |
| AC-12 | Real one-click apply | **PASS (contract) / BLOCKED (hardware)** | Fake backend proves failure (-9878) is surfaced and nothing is stored; conflict gate blocks non-clear states. A physical press reaching Finder/Chrome is BLOCKED. |
| AC-13 | Restore and undo | **PASS (logic)** | Restore re-registers, marks failures with OSStatus, is idempotent, and skips missing targets; undo releases and starts the cool-down. *Not yet:* real relaunch. |
| AC-14 | Weekly report | **PASS (logic)** | `<7 days` → preview; ≥7 days → final; repeated generation creates one row per period; catch-up records the real generation time. |
| AC-15 | No AI dependency | **PASS** | Core paths have no AI call; template fallback is deterministic and tested. |
| AC-16 | Local AI minimal grant | **PASS (logic) / NOT-RUN (live)** | Loopback-only (non-loopback refused before any socket is opened), field whitelist, extra-field/oversize/unsafe-text rejection, Ollama envelope handling, endpoint normalisation. A real `URLSession` transport now exists (no redirects, no cookies, hard timeout). *Not yet:* an actual call to a running Ollama. |
| AC-17 | README reproducible | **NOT-RUN** | README not written yet. |
| AC-18 | CI & tests | **PASS (staging) / PENDING-G6** | Green CI on Linux + macOS 14 + macOS 15. Additionally **154 tests pass on the owner's real Mac** (macOS 26.6.2, arm64, Swift 6.3.3) via `Scripts/test-without-xcode.sh`, which runs the same test sources with an XCTest shim because Command Line Tools does not ship XCTest. The *public* repository CI link can only exist after G6 authorisation. |
| AC-19 | Installable release | **BLOCKED** | Ad-hoc `.app` is produced and `codesign --verify` passes in CI, but no DMG/ZIP clean install on a user machine has been performed. |
| AC-20 | Public GitHub completion | **BLOCKED** | Requires owner approval (G6). Staging repo is private. |
| AC-21 | User privacy autonomy | **PASS (logic) / NOT-RUN (GUI)** | Pause, exclusions, deletion, offline and AI-off are implemented and unit-tested; the GUI has not been exercised. |
| AC-22 | Adoption tracking | **PASS (logic)** | A real double-count defect was found by tests (handler + activation both incremented) and fixed; 5 presses → `trigger_count=5`, activations counted only from notifications. |
| AC-23 | Release safety | **BLOCKED (one step left)** | Signed with a **self-signed certificate**, verified on the real Mac: `valid on disk`, `satisfies its Designated Requirement`, and the requirement is `identifier "com.aimetaphd.shortcutsense" and certificate root = H"340125…"` — stable across rebuilds, unlike ad-hoc. Not notarized: `security find-identity -v -p codesigning` reports 0 Apple identities on this machine. *Remaining:* the Gatekeeper "Open Anyway" install from a fresh copy. |

## Real-Mac evidence collected 2026-10-26

| Check | Result |
|---|---|
| Build with `swift build` | **success** (56.9 s), macOS 26.6.2 arm64, Swift 6.3.3 |
| Test suite | **169 tests, 0 failures** on the real Mac and in CI |
| `.app` assembly + ad-hoc signature | `codesign --verify --deep --strict` passes |
| App launch | process alive; `~/Library/Application Support/ShortcutSense/` created |
| Database | 9 tables, `journal_mode=wal`, 13 default exclusions seeded |
| Carbon probe | `InstallEventHandler` = 0, `RegisterEventHotKey` = 0 (noErr), `Unregister` = 0 |
| `com.apple.symbolichotkeys` readable | **yes** (8 enabled entries in the plist) |
| Input Monitoring | **unknown for the app** — the probe ran over SSH, where TCC attributes the process to `sshd-keygen-wrapper`; the "denied" reading is the SSH session's, not the app's |
| Accessibility | **unknown for the app**, same attribution caveat |
| `CGEvent.tapCreate` | **unknown for the app**, same caveat |
| TCC registration | system `TCC.db` has one row: `kTCCServiceAccessibility / com.aimetaphd.shortcutsense / 0`. **No `kTCCServiceListenEvent` row existed**, so the Input Monitoring pane likely did not list the app at all |

Note: `RegisterEventHotKey` returning `noErr` is recorded as *acceptance only*. It does
not yet prove a physical key press reaches a target application.

## Summary

- **PASS:** AC-02, AC-03 (static), AC-08, AC-09, AC-15, AC-16, plus the logic halves of AC-01, AC-05, AC-06, AC-07, AC-10, AC-11, AC-12, AC-13, AC-14, AC-21, AC-22.
- **BLOCKED (need a real Mac desktop):** AC-04, AC-19, AC-20, AC-23, and the hardware half of AC-10/AC-12.
- **NOT-RUN:** AC-17 (README).
- **FAIL:** none open.

No AC is marked PASS because of CI alone where the requirement is a real desktop
interaction.

## Defects found and fixed during this work

| # | Defect | Found by | Fix |
|---|---|---|---|
| 1 | Managed-hotkey presses were counted twice (handler *and* activation notification) | `testManagedHotkeyIsCountedOncePerPressAndOncePerActivation` | `handleTrigger` now increments only `trigger_count`; successful activation comes solely from the activation observer |
| 2 | A user exclusion could overwrite a built-in sensitive-app exclusion, so removing the user exclusion silently un-excluded a password manager | `testExclusionSourcesAreDistinct` | Upsert only refreshes rows whose source is `user` |
| 3 | `restoreOnLaunch` re-registered an already-live hotkey when called twice | `testRepeatedRestoreIsIdempotent` | Skip rows the backend already holds |
| 4 | Rollback path on persistence failure was unreachable in tests | `testPersistenceFailureRollsBackTheRegistration` | Added a fault-injection hook and asserted the registration is released |
| 5 | CI-only: script exec bit, SQLite headers, Swift 5.10 actor isolation | GitHub Actions | See `docs/release/verification.md` |
| 8–18 | Eleven further defects found by an independent code review, including three S1 issues: the CG/Carbon modifier-bit confusion that made all shortcut capture dead, OS hotkeys surviving data deletion, and a failed unregister orphaning a grab | Independent review agent | See `docs/qa/defects.md` D-007 … D-017 |
| 7 | The AI layer had **no real HTTP transport** — only the test double — so "enable AI and get an explanation" could not work at all | Supply-chain self-review before packaging | Added `OllamaTransport` (ephemeral session, no redirects, no cookies, hard timeout) and `OptionalAI.generateEndpoint`, with 5 normalisation tests |
| 6 | **Secure Input / lock state were only polled every 2 s**, so a password field gaining focus between polls could still have counted keystrokes | Design review while writing the test matrix | `CapturePipeline.refreshVolatileState` re-evaluates secure input, lock and foreground app before every key event |
