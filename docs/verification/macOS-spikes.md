# macOS Feasibility Spikes (G1a)

**Status: BLOCKED — no macOS runtime has been reached yet.**

Everything in this file that would normally be filled in by a spike is marked
NOT-RUN. Nothing here is inferred from documentation and presented as observed
behaviour.

## Why this is blocked

| Requirement | Observed state |
|---|---|
| Local machine | Windows 11 (10.0.26200), x86_64, MSYS/Git Bash |
| `xcodebuild` / `swift` (macOS) | not installed — no macOS SDK exists on this machine |
| Target Mac | `<mac-hostname>` (Tailscale <mac-ip>, macOS, online) |
| SSH to Mac | **refused**: `Permission denied (publickey,password,keyboard-interactive)`; remote OpenSSH_10.3 reached the auth stage, so the daemon is running and the failure is key authorisation |
| Tailscale SSH | not enabled on the node (no host keys advertised) |
| GitHub Actions macOS runner | workflow written (`.github/workflows/ci.yml`), **not yet run** |

The SSH key that needs authorising is generated at
`~/.ssh/shortcutsense_mac.pub` on this machine. `Scripts/setup-mac-ssh.sh key`
prints it. Once the owner appends it to `~/.ssh/authorized_keys` on the Mac,
`Scripts/setup-mac-ssh.sh test` verifies the connection.

## Spike checklist (all NOT-RUN)

### S1 — AX menu click hit-testing (AC-10)

Question: on a real Finder and Chrome menu, does
`AXUIElementCopyElementAtPosition` return an `AXMenuItem` at a moment that can be
reliably associated with the user's click?

| Phase tested | Finder result | Chrome result |
|---|---|---|
| mouse down | NOT-RUN | NOT-RUN |
| mouse up (menu still open) | NOT-RUN | NOT-RUN |
| after menu closes | NOT-RUN | NOT-RUN |
| localised (zh-Hans) titles | NOT-RUN | NOT-RUN |

Pass criterion: a real `AXMenuItem` is returned *and* the same command can be
identified consistently across at least 7 real clicks on 2 different days.

If this fails, the product ships with automatic Learn **disabled** and only the
explicit ManualMark entry point. `AppController.menuObservationSupported` stays
`false` until a spike proves otherwise, so the shipped default is already the
honest fallback.

### S2 — Permission surfaces (AC-04)

| Probe | Expected | Observed |
|---|---|---|
| `CGPreflightListenEventAccess()` before grant | false | NOT-RUN |
| `CGRequestListenEventAccess()` prompt appears | yes | NOT-RUN |
| `CGEvent.tapCreate(.listenOnly)` before grant | nil | NOT-RUN |
| Input Monitoring listed separately from Accessibility in System Settings | yes | NOT-RUN |
| `AXIsProcessTrusted()` independent of Input Monitoring | yes | NOT-RUN |
| `IsSecureEventInputEnabled()` true while a password field is focused | yes | NOT-RUN |
| `CGSSessionScreenIsLocked` true on lock | yes | NOT-RUN |

### S3 — Tap lifecycle (AC-04)

| Event | Expected behaviour | Observed |
|---|---|---|
| `tapDisabledByTimeout` | tap re-enabled, status surfaced | NOT-RUN |
| `tapDisabledByUserInput` | tap re-enabled, status surfaced | NOT-RUN |
| display sleep / wake | tap re-created | NOT-RUN |
| fast user switch | collection stops, resumes on return | NOT-RUN |
| permission revoked while running | capture stops, history still visible | NOT-RUN |

### S4 — Carbon registration (AC-12)

| Case | Expected | Observed |
|---|---|---|
| Register `Ctrl+Opt+Shift+C` | `noErr` | NOT-RUN |
| Register the same combo twice | second returns `-9878` | NOT-RUN |
| Register `Cmd+Tab` | rejected by our conflict gate before Carbon | NOT-RUN |
| Physical press reaches handler exactly once | 1 count per press | NOT-RUN |
| `UnregisterEventHotKey` releases the key | combo usable again | NOT-RUN |
| Another tool wins the key at runtime after `noErr` | must be documented | NOT-RUN |

Note: the last row is the reason `noErr` is never treated as proof. `noErr` means
the system accepted the registration; it does not mean the key will be delivered
to us rather than to a tool that grabs it later.

### S5 — Option / Fn / dead keys (AC-05, AC-09)

| Input | Expected classification | Observed |
|---|---|---|
| Option+e (dead key) | text, not a shortcut | NOT-RUN |
| Option+letter producing a character | text | NOT-RUN |
| Fn/Globe key | modifier-only, never a candidate | NOT-RUN |
| Chinese IME composition | text, no combo recorded | NOT-RUN |

The classification rule itself (`Option` alone is never a command) is implemented
and unit-tested; what remains unverified is that macOS delivers the flags as
expected in each of these cases.

### S6 — Activation attribution (AC-10)

| Scenario | Expected bucket | Observed |
|---|---|---|
| Cmd+Tab then app activates | observed_keyboard_navigation | NOT-RUN |
| Dock click then app activates | unknown_origin | NOT-RUN |
| Raycast launch | unknown_origin | NOT-RUN |
| Our own hotkey then target activates | managed_hotkey | NOT-RUN |
| Our hotkey while target already frontmost | trigger +1, activation +0 | NOT-RUN |

### S7 — Gatekeeper and TCC on an ad-hoc build (AC-23)

| Check | Expected | Observed |
|---|---|---|
| `codesign --verify --deep --strict` | passes | NOT-RUN |
| `spctl -a -vv` | rejected (not notarized) | NOT-RUN |
| First launch via Open Anyway | succeeds | NOT-RUN |
| TCC grant survives a rebuild | unknown — must be observed | NOT-RUN |
| `tccutil reset ListenEvent <bundleID>` | unknown — must be observed | NOT-RUN |

## What is already verified without a Mac

- The privacy classification rules, the fail-closed gate, the attribution buffer,
  the recommendation thresholds, the four-state conflict resolver, the Carbon
  wrapper's *contract* (through a fake backend), the weekly preview/idempotency
  logic, and the AI safety envelope: 130 tests, all passing on Linux/Swift 6.2.
- These prove the logic, not macOS behaviour. No AC that requires a real Mac may be
  marked PASS on the strength of them.
