# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- CI: Linux core job plus macOS 14 and macOS 15 build, test, bundle and signature
  verification.

### Known limitations

- Automatic menu-command learning is disabled until AX menu hit-testing is proven on
  a real Mac.
- Third-party global hotkeys cannot be enumerated; those combinations are reported
  as `unknown`, not as free.
- No Developer ID or notarization yet; the community build is ad-hoc signed and
  requires the Gatekeeper "Open Anyway" flow.
- No seven-day real-world result has been observed; weekly review shows Preview until
  that data exists.
