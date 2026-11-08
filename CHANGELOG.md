# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-08

First usable build, archived privately. 250 tests, 0 failures.

### Added

- Menu-bar app with Today, Shortcuts, Opportunities, Conflict Check, Weekly Review
  and Settings.
- Listen-only `CGEventTap` capture with fail-closed privacy gate.
- Daily SQLite aggregates (WAL), typed schema with atomic migration, and full local
  deletion that checkpoints the WAL.
- Activation attribution with a 1.5 s in-memory buffer and three honest origin
  classes (`unknown_origin`, `observed_keyboard_navigation`, `managed_hotkey`).
- Recommendation engine: 7/14 thresholds, `activeDays >= 2`, dismissal cool-down,
  navigation-dominance suppression.
- Four-state conflict resolver with layered evidence; unreadable sources resolve to
  `unknown`, never to "free".
- Carbon hotkey registration with `OSStatus` returned to the caller, rollback on
  persistence failure, restore-on-launch with visible failures, and undo.
- Weekly review with preview/real distinction, idempotent periods and measured
  adoption counts.
- Optional loopback-only Ollama explanations with schema-limited output and a
  deterministic fallback, including a real `URLSession` transport with no redirects,
  no cookies and a hard timeout.
- CI: Linux core job plus macOS 15 and macOS 26 build, test, bundle and signature
  verification.
- Learn & Workspaces screen: controlled T1 opt-in, automatic menu-command learning,
  manual marking of the frontmost app, and workspace suggestions across days.
- Workspace apply/undo with Carbon hotkeys; restore uses the full member list.
- Schema v4 adds `t1_sessions`; migration is additive and read-back verified.

### Known limitations

- Menu-command titles are filtered by a closed vocabulary plus a command-shape rule.
  On a Chinese-locale Mac this accepts 94 of 156 real commands; the 62 refusals contain
  no user content. Refused commands are simply not learned.
- Menu hit-testing was measured with synthetic clicks (18/18). A human mouse click has
  not been measured.
- Third-party global hotkeys cannot be enumerated; those combinations are reported
  as `unknown`, not as free.
- The build is signed with a self-signed certificate and is not notarized; it needs
  the Gatekeeper "Open Anyway" flow. A clean-machine install has not been performed.
- No seven-day real-world result has been observed; weekly review shows Preview until
  that data exists.
