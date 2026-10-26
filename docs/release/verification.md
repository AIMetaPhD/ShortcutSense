# Verification Log

Every row states what was actually executed, where, and what came back. A check
that has not been run is NOT-RUN; a check that cannot run here is BLOCKED. No row is
marked PASS on the strength of a different kind of evidence.

## Environments

| ID | Environment | Facts (observed) |
|---|---|---|
| ENV-L | Linux container, GitHub Actions | `swift:6.2-jammy`, Swift 6.2, `libsqlite3-dev` installed from Ubuntu jammy |
| ENV-M15 | GitHub-hosted macOS runner | Darwin 24.6.0, macOS 15.7.9 (24G830), **arm64**, Xcode 16.4 (16F6), Apple Swift 6.1.2, target `arm64-apple-macosx15.0` |
| ENV-M14 | GitHub-hosted macOS runner | macOS 14, arm64 (job log records `sw_vers` in the run summary) |
| ENV-W | Owner workstation | Windows 11 10.0.26200, x86_64. **No macOS SDK, no Xcode, no `swift` for Darwin.** |
| ENV-MAC | Owner's MacBook Air | **Reached.** Account `the-owner` (the key had been written to this account; development was using the wrong user name `the-owner`). macOS **26.6.2** (25G83), arm64, Apple Swift **6.3.3**, **Command Line Tools only — no Xcode**, so `xcodebuild` and `XCTest` are unavailable. `security find-identity -v -p codesigning` → **0 valid identities**. |

## CI runs (staging repository)

Repository: `XiangchunChen/ShortcutSense-staging` (private; publishing is a separate,
owner-approved step).

| Run | Commit | Result | Jobs |
|---|---|---|---|
| [40324242517](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40324242517) | `19aee37` | **success** | Core (Linux) ✓, macOS 14 ✓, macOS 15 ✓ |
| [40326203525](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40326203525) | — | **success** | after the real Ollama transport was added |
| [40327645803](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40327645803) | — | **success** | first run that also produces the DMG |
| [40331998215](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40331998215) | — | **success** | after the 11 independent-review fixes; **current** |

Latest CI state: **149 tests, 0 failures**, on Linux, macOS 14 and macOS 15.

Earlier runs failed and their failures drove real fixes, recorded here for audit:

| Run | Failure | Fix |
|---|---|---|
| 40322321848 | Linux: `sqlite3.h` not found; macOS: `Scripts/build-app.sh: Permission denied` | install headers in CI; commit the executable bit |
| 40322959464 | macOS: `IsSecureEventInputEnabled` not in scope; optional chaining on `NSMenuItem`; `UInt64`→`UInt32`; main-actor isolation in `AppDelegate` | imports and type fixes |
| 40323276153 | macOS: `AppDelegate()` called outside the main actor from `main.swift` | `MainActor.assumeIsolated` |
| 40323730269 | macOS 14 only: Swift 5.10 does not infer `@MainActor` for SwiftUI views | explicit `@MainActor` on views |

## Real-Mac run (ENV-MAC)

Commands were executed over SSH on the owner's MacBook Air, 2026-10-26.

| Step | Command | Result |
|---|---|---|
| Build | `swift build` | success, 56.87 s |
| Tests | `bash Scripts/test-without-xcode.sh` | **149 tests, 0 failures, 0.36 s** |
| Bundle + signature | `bash Scripts/build-app.sh` | `valid on disk`, `satisfies its Designated Requirement`, thin arm64, `flags=0x2(adhoc)` |
| Launch | `open build/ShortcutSense.app` | process alive |
| Database created | `ls ~/Library/Application Support/ShortcutSense/` | `.sqlite`, `.sqlite-wal`, `.sqlite-shm` |
| Schema | `sqlite3 .tables` | 9 tables, `journal_mode=wal` |
| Default exclusions | `select * from excluded_apps` | 13 rows, all `system_default` |
| Capability probe | `ShortcutSense --diagnose` | see below |

`--diagnose` output on the real Mac:

```json
{
  "accessibility" : "denied",
  "architecture" : "arm64",
  "bundle_id" : "com.aimetaphd.shortcutsense",
  "carbon" : { "install_handler_status" : 0, "register_no_err" : true,
               "register_status" : 0, "unregister_status" : 0 },
  "database_tables" : 9,
  "input_monitoring" : "denied",
  "menu_readable" : false,
  "os_version" : "Version 26.6.2 (Build 25G83)",
  "screen_locked" : false,
  "secure_input_enabled" : false,
  "symbolic_hotkeys_readable" : true,
  "tap_creation" : "failed"
}
```

`register_status: 0` is acceptance only — it does not show that a physical press
reaches a target.

**Correction (same day).** This probe was run over SSH. TCC attributes a process to
its *responsible* process, and under `ssh` that is `/usr/libexec/sshd-keygen-wrapper`,
confirmed in the tccd log:

```
AUTHREQ_ATTRIBUTION: attribution={responsible={TCCDProcess: identifier=com.apple.sshd-keygen-wrapper,
  responsible_path=/usr/libexec/sshd-keygen-wrapper}, requesting={… identifier=com.aimetaphd.shortcutsense …}}
```

So `input_monitoring: denied`, `accessibility: denied`, `tap_creation: failed` and
`menu_readable: false` describe **the SSH session's grants, not the app's**. They must
not be read as "the app was refused". `screen_locked`, `database_tables`, `carbon.*`,
`symbolic_hotkeys_readable` and `secure_input_enabled` are not affected by attribution
and remain valid.

`--diagnose` now prints `launched_from_ssh_session` and a note to that effect, so the
output cannot be misread again. The real app-context values require running it from a
Terminal in the GUI session.

Because Command Line Tools has no XCTest, `Scripts/test-without-xcode.sh` copies the
test sources with a single mechanical change (`import XCTest` → `import Foundation`)
and links them against `Tools/TestRunner/XCTestShim.swift`. The assertions executed
are the same ones CI runs.

## Test execution

| Where | Command | Result |
|---|---|---|
| ENV-L | `swift test` | **130 tests, 0 failures** (0.49 s) |
| ENV-M15 | `swift test` | **130 tests, 0 failures** (0.25 s) |
| ENV-M14 | `swift test` | **130 tests, 0 failures** |

The 130 tests cover the platform-independent core only. They prove logic; they do
not prove macOS behaviour.

## Bundle and signature

| Check | Command | Result |
|---|---|---|
| Bundle assembles | `Scripts/build-app.sh` | `build/ShortcutSense.app` produced on both macOS runners |
| Signature verifies | `codesign --verify --deep --strict --verbose=2` | passed |
| Signature identity | `codesign -dv --verbose=4` | `Identifier=com.aimetaphd.shortcutsense`, `Signature=adhoc`, `TeamIdentifier=not set` |
| Bundle identifier | `PlistBuddy -c "Print :CFBundleIdentifier"` | `com.aimetaphd.shortcutsense` |
| Executable arch | `file` | arm64 (CI is arm64) |
| DMG produced | `Scripts/package-dmg.sh` | `release/ShortcutSense-0.1.0-arm64.dmg` |
| DMG checksum | `shasum -a 256` | `76380e4d83f7cde81920b75ec0664fb1e9cec44c35961dc245fc2008a64a3a48` |
| Checksum re-verified off-machine | downloaded to Windows and hashed locally | matches the CI value exactly |
| Code signature CDHash | `codesign -dv` | `512582e57bcdf8629f98a6213310b9791ce11f2bc6bfd3128789ed4428d9cc83` |
| INSTALL.txt inside the DMG | created by the script | contains the Open Anyway steps, not a quarantine-removal command |

**Not** notarized. **No** Developer ID. Gatekeeper behaviour of this ad-hoc bundle on
a real user machine is NOT-RUN.

## What has NOT been verified

- Any GUI behaviour. The GitHub runners are headless VMs; nothing in this log shows
  the window, the menu bar item, or a SwiftUI view rendering.
- Input Monitoring / Accessibility prompts and TCC behaviour.
- A physical key press reaching a real application.
- AX menu hit-testing.
- Secure Input, lock screen, sleep/wake.
- Gatekeeper "Open Anyway" install on a user machine.
- Any seven-day real-world data.
- The DMG has never been mounted or installed. CI proves it is created and that the
  app inside still passes `codesign --verify`; it does not prove a clean install.

These are listed as BLOCKED in `docs/release/acceptance-status.md` and are Muse's
scope on the real Mac.
