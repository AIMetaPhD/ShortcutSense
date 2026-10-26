# Third-Party Notices

ShortcutSense is an independent implementation (path B). It does **not** contain
code from, and is not a fork of, `debugtheworldbot/keyStats`.

## Code reused

**None.** No source file from any third-party project is copied into this
repository. All Swift sources under `Sources/` were written for ShortcutSense.

## Upstream projects audited

Audited at the commits below on 2026-10-26. They are listed here because their
public interfaces and reported behaviour informed design decisions; they are not
dependencies and are not vendored.

| Project | Commit | License | What was inspected | What was used |
|---|---|---|---|---|
| [debugtheworldbot/keyStats](https://github.com/debugtheworldbot/keyStats) | `71dd9e1a85e2b06d376fbce262c8a2d7b05c9142` | MIT | `KeyStatsHelper/EventTapController.swift` (CGEventTap setup), `KeyStats/StatsManager.swift` (UserDefaults aggregation), presence of Sparkle and Cloudflare sync services | Nothing copied. Confirmed it stores aggregates in `UserDefaults` and couples to Sparkle/sync, which is why path B was chosen. |
| [soffes/HotKey](https://github.com/soffes/HotKey) | `a3cf605d7a96f6ff50e04fcb6dea6e2613cfcbe4` | MIT | `Sources/HotKey/HotKey.swift`, `Sources/HotKey/HotKeysController.swift` | Nothing copied. Its `register` does check `registerError == noErr` internally, but returns `Void` to the caller, so a caller cannot distinguish success from refusal. ShortcutSense writes its own Carbon wrapper that returns `Result` with the exact `OSStatus`. |
| [Wunderlandmedia/HotkeyClash](https://github.com/Wunderlandmedia/HotkeyClash) | not cloned | GPL-2.0 | Public description only | **No source read, copied, translated or modified.** GPL code is deliberately kept out of this MIT project. |

## System frameworks

AppKit, SwiftUI, Foundation, Carbon (`RegisterEventHotKey`), CoreGraphics
(`CGEventTap`), ApplicationServices (`AXUIElement`), SQLite3 — all Apple system
frameworks, used under their respective SDK licences.

## Dependencies

No third-party package dependencies. `Package.swift` declares only the system
SQLite library.
