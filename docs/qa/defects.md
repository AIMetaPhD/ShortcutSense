# Defect Log

Severity: **S1** blocks release · **S2** core flow broken · **S3** degraded but usable · **S4** cosmetic

Status: **OPEN** · **FIXED (awaiting Muse re-test)** · **CLOSED (Muse verified)** ·
**BLOCKED** (cannot be tested in the current environment)

Development never marks a defect CLOSED. Only Muse closes a defect after re-testing
on a real Mac.

## Open / awaiting re-test

| ID | Severity | Status | Summary | Found | Evidence |
|---|---|---|---|---|---|
| D-001 | S2 | FIXED (awaiting Muse re-test) | Managed-hotkey presses were counted twice: `handleTrigger` incremented `successful_target_activation_count` when the launcher reported the app already running, and the activation observer incremented it again. A 5-press run produced 9. | Unit test `testManagedHotkeyIsCountedOncePerPressAndOncePerActivation` | `Sources/ShortcutSenseCore/ShortcutActionManager.swift` `handleTrigger`; counter now only moves in the activation observer |
| D-002 | S2 | FIXED (awaiting Muse re-test) | Adding a user exclusion for an app that was already excluded by the built-in sensitive list overwrote its `exclusion_source` to `user`. Removing the user exclusion then silently un-excluded a password manager. | Unit test `testExclusionSourcesAreDistinct` | `Store.addExcludedApp` upsert now only refreshes `user` rows |
| D-003 | S3 | FIXED (awaiting Muse re-test) | `restoreOnLaunch` called twice asked Carbon to register the same hotkey again, producing a spurious `-9878` failure row. | Unit test `testRepeatedRestoreIsIdempotent` | `restoreOnLaunch` skips ids the backend already holds |
| D-004 | S3 | FIXED (awaiting Muse re-test) | The rollback path after a persistence failure was unreachable in tests, so the "registration must not outlive a failed save" rule was unproven. | Unit test `testPersistenceFailureRollsBackTheRegistration` | Added `Store.failNextRegisteredShortcutInsert` fault injection; test asserts `unregister` is called |
| D-006 | **S1** | FIXED (awaiting Muse re-test) | The privacy gate read Secure Input, lock state and the frontmost app from a 2-second poll. A password field gaining focus between two polls would still have counted up to two seconds of keystrokes against the app. | Tests `testSecureInputActivatedBetweenPollsDropsTheVeryNextKey`, `testLockBetweenPollsDropsTheVeryNextKey`, `testRefreshCanAlsoRevokePermissionImmediately` | `CapturePipeline.refreshVolatileState` now re-evaluates the volatile state at the instant of every key event |
| D-007 | **S1** | FIXED (awaiting Muse re-test) | **CGEventFlags were reinterpreted as Carbon modifier bits.** The two layouts share no bits (CG Command = 0x00100000, Carbon Command = 0x0100), so every real keystroke classified as plain text: no shortcut was ever recorded, no keystroke counted as navigation, and every activation fell into `unknown_origin`. The keystroke totals kept rising, so the failure was silent. | Independent code review; tests `AppleModifierConversionTests` (6 cases) | `ComboModifiers(appleEventFlagsRawValue:)` added in core and used at every platform boundary, including `symbolichotkeys` parsing |
| D-008 | **S1** | FIXED (awaiting Muse re-test) | **Deleting all data left OS hotkeys registered.** The database was cleared but Carbon grabs stayed live, so the hotkey still launched apps and immediately wrote fresh rows for a deleted shortcut id, which the UI could no longer show or undo; re-applying that combo then failed permanently with -9878. | Independent code review; test `testDeletingDataReleasesEveryLiveHotkey` | `ShortcutActionManager.releaseAllRegistrations()` + `CapturePipeline.clearNavigationState()` run before deletion |
| D-009 | S1 | FIXED (awaiting Muse re-test) | `unregister` dropped the registration record **before** checking `UnregisterEventHotKey`. On failure, `isRegistered` said false while the OS still held the grab, so a second undo deleted the row and orphaned the hotkey forever. | Independent code review; test `testFailingUnregisterKeepsTheRecordForRetry` | Record is only removed on `noErr`; the ref is kept for retry and exit cleanup |
| D-010 | S2 | FIXED (awaiting Muse re-test) | Apply was not atomic: if the recommendation update failed after the insert, an `is_active=1` row survived, and `restoreOnLaunch` later activated a shortcut the user was told had failed. | Independent code review; test `testFailedSaveLeavesNeitherRowNorAppliedStatus` | `Store.applyRegistration` does both writes in one transaction |
| D-011 | S2 | FIXED (awaiting Muse re-test) | A failed `InstallEventHandler` was only logged; `register` still returned success, so the OS swallowed the key while no handler could ever run. | Independent code review | `register` now fails when the Carbon handler is absent |
| D-012 | S2 | FIXED (awaiting Muse re-test) | **AX menu modifier bits were decoded wrongly**: Command is implied unless `NoCommand` is set, but the code read bit 0 as Command. ⌘⇧N decoded as ⌘N, so conflict checks disagreed with the real menu. | Independent code review; `AXMenuCodecTests` rewritten (4 cases) | Bit constants corrected and tests updated |
| D-013 | S2 | FIXED (awaiting Muse re-test) | Granting Input Monitoring while the app was running never created the event tap; the UI said "Collecting" but nothing was recorded. | Independent code review | `refreshContext` starts the tap when permission appears and none is running |
| D-014 | S3 | FIXED (awaiting Muse re-test) | `deleteAllData` ran `VACUUM` after the WAL checkpoint, and `VACUUM` writes through the WAL, so a populated `-wal` remained. | Independent code review | Checkpoint → `secure_delete` → `VACUUM` → checkpoint |
| D-015 | S3 | FIXED (awaiting Muse re-test) | `isScreenLocked` returned `false` when the session dictionary was unreadable, failing **open** on an unknown state. | Independent code review | Returns `true` (treat as locked) when unknown |
| D-016 | S3 | FIXED (awaiting Muse re-test) | `handleManualMark` wrote to the database without consulting the gate at all. | Independent code review; test `testManualMarkRespectsTheGate` | Goes through `decideMenuObservation` like the verified-click path |
| D-017 | S4 | FIXED (awaiting Muse re-test) | `EventTapSource.stop()` disabled the tap but never invalidated the mach port, so the port and callback outlived teardown. | Independent code review | `CFMachPortInvalidate` on stop |
| D-005 | S3 | FIXED (awaiting Muse re-test) | CI: `Scripts/build-app.sh` was committed without the executable bit; Linux job had no SQLite headers; Swift 5.10 on macOS 14 does not infer `@MainActor` for SwiftUI views. | CI runs 40322321848 / 40322959464 / 40323276153 / 40323730269 | `docs/release/verification.md` |

| D-018 | **S1** | FIXED (awaiting Muse re-test) | **The app never registered itself for Input Monitoring.** `eventTap.start()` only read `CGPreflightListenEventAccess()` and gave up, and that call never writes TCC. The system `TCC.db` had no `kTCCServiceListenEvent` row for the bundle, so a user following the README would open the Input Monitoring pane and find no ShortcutSense to switch on — the product could never be enabled. | Independent Mac probe (subagent), tccd attribution log and `TCC.db` inspection | `AppController.requestMissingPermissionsIfNeeded()` calls `CGRequestListenEventAccess()` and `AXIsProcessTrustedWithOptions(prompt)` once per launch when granted is missing |
| D-027 | S2 | FIXED (awaiting re-test) | **`busy_timeout` was 0 on the live database** even though the connection set it. Any concurrent writer — the 2 s permission poll and the 5 s stats write both touch the store — would fail immediately instead of waiting, and the event path swallows the error with `try?`, so keystrokes would be silently lost. | Reading `pragma busy_timeout` on the running app's database | The return status is now checked and a failure aborts `init`; a test asserts the effective pragma is non-zero |
| D-028 | S3 | FIXED (awaiting re-test) | The WAL grew to **1.2 MB against a 108 KB database** after a few minutes. The default 1000-page autocheckpoint is never reached by a long-lived connection writing a handful of rows per minute, so the log accumulated. | `ls -l` on the live database | `wal_autocheckpoint=256`; a test writes 400 small rows and asserts the WAL stays bounded |
| D-024 | **S1** | FIXED (awaiting re-test) | **The default exclusion list was incomplete for its own stated purpose.** Muse-3 round 2 found that Xcode, JetBrains IDEs, Zed, Ghostty/Alacritty/kitty and Dashlane/Keeper/Enpass were missing — every one a place where a secret is typed. A missing entry leaks; an extra entry only means the user re-includes an app. | Muse-3 review `290ab02b452a59053fd39c1a`, verdict 2 | List expanded to 29 entries; four tests assert class coverage, that ordinary apps are not excluded, and that the terminal subset stays a subset |
| D-025 | S2 | FIXED (awaiting re-test) | Terminal, iTerm2 and Warp appeared in both `codeAndCredentialToolBundleIDs` ("not re-includable") and `terminalClassBundleIDs` ("re-includable"), two contradictory statements about the same apps. | Same review, new issue S2 | `terminalClassBundleIDs` is documented and tested as a subset of the code-tool list |
| D-026 | S3 | FIXED (awaiting re-test) | `ComboModifiers.function = 0x8000` carried the comment `kCGEventFlagMaskSecondaryFn`, but the CG constant is `0x00800000`. The value was right and the comment was wrong, which is exactly how the earlier CG/Carbon confusion could return. | Same review, new issue S3 | Comment corrected, and a test pins both values and asserts the CG bit is never stored raw |
| D-023 | S2 | FIXED (awaiting re-test) | **The macOS permission dialog was counted as a user application.** After granting Input Monitoring on the real Mac, `daily_app_activity` gained a row for `com.apple.accessibility.universalAccessAuthWarn` — the consent sheet itself. System consent/UI processes are not apps the user chose to use, and counting them pollutes recommendations with an "app" nobody opened. | First real capture on the Mac, 2026-10-27 | Nine system-UI bundle identifiers added to the default exclusions; three tests assert they are not counted while ordinary apps still are |
| D-020 | S2 | FIXED (awaiting re-test) | **AI: HTTP redirects were followed.** `isLoopback` validated the URL we asked for, but URLSession's default policy follows a `302 Location: https://elsewhere`, so a local server could have the aggregate payload forwarded off-machine after the loopback check passed. | Muse-3 independent source review, section F | `NoRedirectSessionDelegate` refuses every redirect |
| D-021 | S3 | FIXED (awaiting re-test) | `OptionalAI.parse(_:fallback:)` accepted a template it never returned; a malformed model answer threw to a caller whose fallback depended on code outside the reviewed file. | Same review, section F | `parse(_:)` no longer takes a fallback and always throws; the app layer explicitly substitutes `template(for:)` |
| D-022 | S3 | FIXED (awaiting re-test) | Only `explanation` was screened for executable-looking text; `reason` is rendered in the same card and was unchecked. | Same review, section F | Both fields pass `looksExecutable` |
| D-019 | S2 | FIXED (awaiting Muse re-test) | `--diagnose` reported permission values without saying that, under SSH, they describe the SSH session's TCC identity rather than the app's — an invitation to record a false "denied". | Same probe | Output now includes `launched_from_ssh_session` and an explicit attribution note |

## Blocked — cannot be exercised without a real Mac desktop

| ID | Severity | Status | Summary |
|---|---|---|---|
| B-001 | S1 (release gate) | **RESOLVED** | SSH now works (the Mac account is `the-owner`; the key had been written to that account all along and development had been using the wrong user name). Build, tests, launch and signature are now verified on the real Mac. |
| B-002 | S1 | BLOCKED | AX menu click hit-testing needs Accessibility, which is not granted yet. `--diagnose` currently reports `accessibility: denied`, `menu_readable: false`. Automatic Learn stays disabled until it is proven. |
| B-003 | S1 | BLOCKED | No physical key press has reached a real application yet: Input Monitoring is denied, so no recommendation can be produced from real activity. Carbon registration itself returns `noErr` on the real Mac. |
| B-004 | S1 | BLOCKED | The ad-hoc build is verified on the real Mac (`valid on disk`, 0 signing identities available so notarization is impossible here), but the Gatekeeper "Open Anyway" install from `/Applications` has not been performed. |
| B-005 | S2 | BLOCKED | Secure Input, lock screen, sleep/wake and permission revocation are not yet observed: they require capture to be running, which requires Input Monitoring. A live-state probe (`refreshVolatileState`) is in place and unit-tested. |
| B-007 | S1 | BLOCKED | **No human has launched the app from the Mac's GUI session.** Every launch so far came over SSH, where TCC attributes the process to `sshd-keygen-wrapper`; as a result macOS never recorded `kTCCServiceListenEvent` for the bundle, the Input Monitoring pane has nothing to switch on, and `--diagnose` reports the SSH session's grants rather than the app's. One action at the machine fixes this. |
| B-006 | S2 | BLOCKED | `symbolichotkeys` and live menu reads have not been exercised, so the live conflict results are unverified. |

## Independent review outcomes

| Reviewer | Scope | Result |
|---|---|---|
| Claude subagent (code review) | privacy, hotkey, store, event tap | 11 defects (D-007 … D-017), including 3 silent S1 |
| Muse-2 (queue) | Mac GUI acceptance | BLOCKED — unmanned Linux VM, no macOS desktop |
| Muse-1 (queue) | environment self-description | confirmed: no macOS Aqua desktop, no GUI automation; suitable only for static review |
| Muse-3 (queue) | static review of 13 core files, A–H | **A, B, C, D, E, G, H PASS; no S1 found.** F raised 3 gaps → fixed as D-020…D-022 |
| Muse-3 (queue) | round 2: signing, exclusion list, double-count, modifier bits, redirect | 1–5 mostly PASS; found D-024 (S1, incomplete exclusions), D-025 (S2, contradictory lists), D-026 (S3, wrong comment). All fixed. Its "unverifiable" items (Store SQL, onTrigger wiring) are now covered by `TriggerAccountingIntegrationTests`. |

Muse-3's own scope note: the database wrapper, `AttributionBuffer` and app-layer call
sites were outside the 13 supplied files, so its conclusions on those chains are
marked unverified rather than assumed.

## Closed

None yet.
