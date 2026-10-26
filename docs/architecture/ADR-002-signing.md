# ADR-002: Signing and distribution strategy

- **Status:** Proposed — depends on what the target Mac can do (BLOCKED until verified)
- **Date:** 2026-10-26

## Context

On Apple Silicon, a completely unsigned arm64 binary is killed at launch by the
kernel (invalid code signature). "Unsigned" is therefore not a distribution option;
the realistic fallbacks are *ad-hoc signed and unnotarized*, or *Developer ID signed
and notarized*.

The acceptance matrix (AC-23) requires that whichever route is used is verified on a
real target machine through Apple's own Gatekeeper flow, and explicitly forbids
telling users to disable SIP or Gatekeeper or to bulk-remove quarantine attributes.

## Decision

1. **Preferred:** `Developer ID Application` certificate present on the build
   machine → sign with hardened runtime, notarize with `notarytool`, staple, and
   verify with `codesign --verify --deep --strict` plus `spctl -a -vv`.
2. **Fallback:** ad-hoc sign with `codesign --force --sign -`. Never ship a bundle
   with no signature at all. Document the exact Gatekeeper "Open Anyway" path
   (System Settings → Privacy & Security → Open Anyway) and state plainly that the
   developer identity is not verified and the build is not notarized.
3. **Not acceptable:** disabling SIP, disabling Gatekeeper, running as root, or
   instructing users to `xattr -dr com.apple.quarantine` as the default install step.

`Scripts/build-app.sh` implements 1 and 2 and always runs
`codesign --verify --deep --strict` afterwards. If neither route works on the target
machine, G5 is BLOCKED — the source code is not a substitute for an installable app.

## Measured on the target Mac (2026-10-27)

Observed, not assumed:

- `security find-identity -v -p codesigning` → **0 valid identities**.
- `codesign -d -r- /Applications/ShortcutSense.app` → `# designated => cdhash H"4cb8c3f7…"`.
  An ad-hoc signature has no team or certificate to anchor a requirement to, so the
  designated requirement is the **code hash itself**.
- Consequence: every rebuild produces a new CDHash, so the identity TCC stored the
  user's grant against no longer matches the running binary. This is why the
  Accessibility row survived one grant (`kTCCServiceAccessibility … 2`) while the
  Input Monitoring row was never created, and why the pane appeared to have a working
  switch that did nothing.
- TCC contained exactly one `kTCCServiceListenEvent` row on the whole machine, for a
  different application. No row was ever created for this bundle.

**What this means for release:** ad-hoc signing is not merely "unnotarized"; it
makes TCC grants unstable across rebuilds, so the shipped artifact must be built
**once** and then be the thing the user authorises. Rebuilding after the user grants
permission invalidates the grant. `docs/qa/onmac-checklist.md` and the README must
say this plainly.

**What would fix it properly:** a Developer ID certificate (stable designated
requirement) or a self-signed certificate kept in the Keychain and reused for every
build. The latter is available without Apple, and would give a stable identity —
it is the recommended next step if a Developer ID is not obtainable.

## Open questions (must be answered on the real Mac)

- Is a `Developer ID Application` identity present? (`security find-identity -v -p codesigning`)
- Does the ad-hoc build launch after the Gatekeeper override on the target OS version?
- Does TCC keep Input Monitoring across rebuilds of an ad-hoc signed bundle, or does
  the grant go stale? (Reported behaviour differs by macOS version; must be observed,
  not assumed.)
- Does `tccutil reset ListenEvent <bundleID>` actually work on the target OS? It is
  not documented as a supported per-service reset, so the UI must not promise it.
