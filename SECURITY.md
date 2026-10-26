# Security Policy

## Supported versions

Only the latest release is supported. This is pre-release software.

## Reporting a vulnerability

Open a private security advisory on the project repository, or contact the
maintainer listed in the repository profile. Please do not open a public issue for a
vulnerability.

Include: affected version, macOS version, steps to reproduce, and what data or
capability is exposed.

## Threat model

ShortcutSense runs with two sensitive grants: Input Monitoring (sees keystrokes) and
Accessibility (can read UI elements). The design assumes these are dangerous and
minimises what the app does with them.

**In scope**

- A path that persists typed text, key sequences, window titles, URLs, clipboard
  content or `AXValue` — anywhere: SQLite, WAL, logs, exports, crash reports.
- Recording while paused, locked, in Secure Input, or for an excluded application.
- A network request other than the opt-in loopback AI call.
- Registering a hotkey that the UI reported as failed, or reporting success when
  Carbon returned an error.
- Model output that changes configuration or is rendered as an instruction.

**Out of scope**

- Another process with the same TCC grants reading ShortcutSense's database. On
  macOS, any process with Full Disk Access can read any user file; ShortcutSense does
  not claim to defend against a compromised local account.
- Kernel-level attackers or SIP-disabled systems.
- The user deliberately re-including a sensitive application.

## Design controls

| Control | Where |
|---|---|
| Fail-closed gate evaluated before any write | `Sources/ShortcutSenseCore/PrivacyGate.swift` |
| Text keys never reach storage | `KeyCombo.classify` + `CapturePipeline.handle` |
| Listen-only event tap, never modifies events | `Sources/ShortcutSenseMac/EventTapSource.swift` |
| Only `keyDown` and `leftMouseUp` are observed | same file (no mouse movement, no scroll, no drags) |
| Menu titles filtered for user data | `AXMenuCodec.isSafeStaticTitle` |
| `OSStatus` surfaced, never swallowed | `CarbonHotkeyBackend` |
| AI restricted to loopback, schema-limited | `OptionalAI` |
| Deletion checkpoints WAL and vacuums | `Store.deleteAllData` |

## Tests that guard these

`Tests/ShortcutSenseCoreTests/PrivacyTests.swift` and `OptionalAITests.swift` include
byte-level scans of the SQLite/WAL files for typed text, and assertions that a
disabled or non-loopback AI configuration makes no call at all.
