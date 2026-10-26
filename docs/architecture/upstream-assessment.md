# Upstream Assessment (G0)

**Date:** 2026-10-26
**Performed on:** Windows 11 + WSL2 Ubuntu 22.04, Swift 6.2, no macOS toolchain
**Method:** `git clone --depth 1` of each upstream, pinned by commit SHA, then source
inspection. No macOS runtime behaviour is claimed here — that requires a real Mac and
is tracked separately in `docs/verification/macOS-spikes.md`.

## Pinned commits

| Repository | Commit SHA | License file verified |
|---|---|---|
| debugtheworldbot/keyStats | `71dd9e1a85e2b06d376fbce262c8a2d7b05c9142` | `LICENSE` — MIT, "Copyright (c) 2026 pipizhu" |
| soffes/HotKey | `a3cf605d7a96f6ff50e04fcb6dea6e2613cfcbe4` | `LICENSE` — MIT, "Copyright (c) 2017–2019 Sam Soffes" |
| Wunderlandmedia/HotkeyClash | not cloned | GPL-2.0 per upstream description; source deliberately not read |

## KeyStats

**Storage.** `KeyStats/StatsManager.swift` aggregates counts into `UserDefaults`,
not SQLite. There is no typed schema and no migration path.

**Coupled subsystems observed.** `KeyStats/Sync/`, `contracts/sync/v1/*`
(Cloudflare Worker end-to-end encrypted sync), `KeyStats/UpdateManager.swift` and
`UpdateCheckCoordinator.swift` (Sparkle), `KeyStats.Windows/`, plus a privileged
XPC helper (`KeyStatsHelper/`) and `HelperSupervisor.swift`.

**Event tap.** `KeyStatsHelper/EventTapController.swift` creates a
`.cgSessionEventTap` at `.headInsertEventTap` with `.listenOnly`, and re-enables
the tap on `tapDisabledByTimeout` / `tapDisabledByUserInput`. That pattern is sound
and ShortcutSense uses the same one. It also registers a very wide event mask
(keyboard, four mouse button types, mouse movement, drags, scroll wheel) at 30 Hz
for mouse sampling — a privacy and battery profile ShortcutSense does not adopt:
ShortcutSense listens to `keyDown` and `leftMouseUp` only.

**Decision (ADR-001).** Path B. No file copied. The product needs a typed SQLite
schema, strict privacy filtering, and none of sync/Sparkle/Windows; retrofitting
those into this codebase would cost more than writing the modules fresh.

## HotKey (soffes)

`HotKeysController.register` does:

```swift
let registerError = RegisterEventHotKey(...)
guard registerError == noErr, eventHotKey != nil else { return }
```

So it *does* check `OSStatus` — the audit's "ignores the return code" is not
literally accurate. The real defect is different and still disqualifying for this
product: `register` returns `Void`, and `HotKey.init` calls it unconditionally. A
caller therefore gets a non-nil `HotKey` object whether the system accepted the
registration or refused it with `eventHotKeyExistsErr` (-9878). The failure is
swallowed at the API boundary, not at the Carbon call.

`unregister` calls `UnregisterEventHotKey` and also discards its `OSStatus`.

**Decision.** Do not depend on it. `Sources/ShortcutSenseMac/CarbonHotkeyBackend.swift`
is an independent ~120-line wrapper whose `register` returns
`Result<Void, HotkeyRegistrationError>` with the exact `OSStatus`, and whose
`unregister` returns the same. `noErr` is documented as *acceptance only*: it does
not prove the hotkey will fire, and it does not prove another application will not
win the key at runtime. Only a physical key press to a real target proves that.

## HotkeyClash

Not cloned, not read, not translated. GPL-2.0 source must not enter an MIT project.
Publicly documented concepts (detecting that a combination is already taken) are
implemented here from Apple's API documentation only.

## Consequences carried into the build

1. No dependency on any upstream package; `Package.swift` declares only system SQLite.
2. No Sparkle, no sync client, no Windows code paths anywhere in the tree.
3. Carbon registration is owned by this project, with `OSStatus` surfaced to the UI
   and to `registered_shortcuts.last_error_code`.
4. Menu-click observation is implemented as an *experiment* gated behind a real-Mac
   spike; it is off by default (`AppController.menuObservationSupported = false`).
