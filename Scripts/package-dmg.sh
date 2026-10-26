#!/usr/bin/env bash
# Packages build/ShortcutSense.app into a DMG plus a SHA256 checksum.
# Runs on macOS only (uses hdiutil).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${BUILD_DIR:-build}/ShortcutSense.app"
VERSION="${VERSION:-0.1.0}"
OUT_DIR="${OUT_DIR:-release}"
DMG="${OUT_DIR}/ShortcutSense-${VERSION}-arm64.dmg"

test -d "$APP" || { echo "missing $APP — run Scripts/build-app.sh first" >&2; exit 1; }
mkdir -p "$OUT_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/ShortcutSense.app"
# A plain text install note travels with the image so the Gatekeeper path is
# documented next to the binary, not only in the repository.
cat > "$STAGE/INSTALL.txt" <<'TXT'
ShortcutSense is ad-hoc signed and NOT notarized.

To install:
  1. Drag ShortcutSense.app to /Applications.
  2. Try to open it. macOS will refuse the first time.
  3. Open System Settings > Privacy & Security, scroll down, click "Open Anyway".
  4. Confirm, then launch the app again.

Do not disable Gatekeeper or SIP, and do not bulk-remove quarantine attributes.

Then grant Input Monitoring in System Settings > Privacy & Security > Input Monitoring.
Accessibility is optional and is only used for menu reading.
TXT

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "ShortcutSense ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

echo "==> Checksums"
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )

echo "==> Verifying the app still validates inside the image"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Done: $DMG"
