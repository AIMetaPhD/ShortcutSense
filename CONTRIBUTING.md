# Contributing

## Ground rules

1. **Never weaken a privacy invariant to make a test pass.** If a test fails, fix the
   code. Tests that assert "no typed text reaches disk" are the product, not a formality.
2. **Never report a macOS behaviour you have not observed.** If a change needs a real
   Mac and you do not have one, mark it BLOCKED in `docs/release/acceptance-status.md`.
3. **Never present simulated data as measurement.** Fixtures prove logic; they never
   prove a seven-day history or a physical key press.
4. **Do not copy GPL code.** HotkeyClash (GPL-2.0) must never enter this tree, not even
   translated or paraphrased. Any MIT code reuse needs a file-level entry in
   `THIRD_PARTY_NOTICES.md` with the upstream commit.

## Layout

```
Sources/ShortcutSenseCore/   platform-independent logic — builds and tests on any OS
Sources/ShortcutSenseMac/    AppKit / SwiftUI / Carbon / CoreGraphics layer
Sources/CSQLite/             system SQLite module shim
Tests/ShortcutSenseCoreTests/
Scripts/                     build and remote-access helpers
docs/                        architecture, verification, QA, release status
```

Put logic in `ShortcutSenseCore` whenever it does not need AppKit. Anything that
touches Carbon, CGEvent, AX or NSWorkspace belongs in `ShortcutSenseMac`. This is why
the AX modifier decoding lives in `AXMenuCodec` — it is pure and privacy-sensitive,
so it must be testable everywhere.

## Workflow

```bash
swift build
swift test
./Scripts/build-app.sh
```

CI runs the core on Linux and the full package on macOS 14 and macOS 15, including
bundle assembly and `codesign --verify`.

## Testing expectations

- A behavioural change needs a test that fails before the change.
- Privacy tests must assert on the actual bytes on disk, not only on the model.
- Carbon behaviour is tested through `FakeHotkeyBackend`; a test may not claim that a
  fake proves a physical key press.
- Date logic needs a DST case and a time-zone case.

## Commits

Small, focused commits with a message that says what changed and why. Do not mix a
behaviour change with a reformat.
