# ADR-001: Build a clean native project (path B) instead of forking KeyStats

- **Status:** Accepted
- **Date:** 2026-10-26
- **Deciders:** Owner (product), Gemini (independent audit), Claude Code (implementation)

## Context

The first plan offered two paths:

- **A** — fork `debugtheworldbot/keyStats` and reshape it.
- **B** — create a new macOS project and reuse only small MIT pieces with
  file-level attribution.

The audit found that KeyStats stores aggregates in `UserDefaults`, is built around
AppKit view controllers and a privileged XPC helper, and ships Sparkle auto-update
plus a Cloudflare Worker end-to-end-encrypted sync service. See
`upstream-assessment.md` for the evidence and pinned commits.

ShortcutSense additionally requires things KeyStats does not have:

- a typed SQLite schema with migrations and provable WAL cleanup;
- an entry-point privacy gate that fails closed on secure input, lock, pause and
  excluded apps;
- a Carbon wrapper that returns `OSStatus` to the caller;
- conflict resolution with layered evidence and four states;
- weekly reports that distinguish preview from real data.

## Decision

Take **path B**. New `Package.swift` project with:

- `ShortcutSenseCore` — platform-independent logic, buildable and testable on any
  platform with Swift 6.2 (verified on Linux);
- `ShortcutSenseMac` — AppKit/SwiftUI/Carbon/CoreGraphics layer, macOS 14+;
- `CSQLite` — system SQLite module shim.

No third-party package dependencies. No file copied from any upstream project.

## Consequences

**Positive**

- Privacy invariants are structural: text-producing keys are classified out before
  they reach storage, and that rule is unit-tested.
- The core is testable without a Mac. 130 tests run in ~3 seconds on Linux, so a
  regression is caught long before anyone needs the MacBook.
- No inherited sync/update surface, so the "no outbound network when AI is off"
  claim is provable by inspection and by a dependency inventory.
- Carbon failure semantics are ours to define, and `OSStatus` reaches the UI.

**Negative**

- macOS-specific behaviour (event tap, AX, Carbon, TCC) cannot be verified on
  Windows/Linux. Those gates are BLOCKED until a real Mac runs them, and this is
  recorded as such rather than worked around.
- Some UI work that a fork would have inherited (window controllers, popover) has
  to be written here.

## Alternatives rejected

- **A (fork KeyStats).** Rejected: incompatible storage, coupled sync/update, and
  the audit's finding that the fork would carry more to remove than to reuse.
- **Adopting soffes/HotKey.** Rejected: its API cannot report a failed registration
  to the caller, which directly contradicts AC-12.
- **Electron/Tauri/Rust shell.** Rejected: the product needs TCC-scoped native
  input monitoring, Carbon hotkeys and AX menus; a shell would add a second
  runtime without removing any of that work.
