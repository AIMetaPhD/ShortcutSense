#!/usr/bin/env bash
# Builds ShortcutSense.app from the SwiftPM executable and applies an ad-hoc
# signature. Used by CI and by the local packaging step.
#
# Signing policy (see docs/architecture/ADR-002-signing.md):
#   - Developer ID + notarization is preferred when available.
#   - Otherwise the bundle is ad-hoc signed (`codesign -s -`). It is never left
#     completely unsigned: on Apple Silicon an unsigned arm64 binary is killed by
#     the kernel and cannot be installed at all.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUILD_DIR="${BUILD_DIR:-build}"
APP="${BUILD_DIR}/ShortcutSense.app"

echo "==> Building ${CONFIG}"
swift build -c "$CONFIG" --product ShortcutSense

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/ShortcutSense"
test -f "$BIN_PATH" || { echo "missing executable at $BIN_PATH" >&2; exit 1; }

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/ShortcutSense"
cp Sources/ShortcutSenseMac/Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing identity, in order of preference:
#   1. $DEVELOPER_ID — a real Apple certificate; the only route to notarization
#   2. a local self-signed certificate — stable TCC identity, no Apple account
#   3. ad-hoc — last resort
#
# Why (2) exists: an ad-hoc signature has no certificate to anchor to, so codesign
# writes the CDHash itself into the designated requirement:
#     ad-hoc:  designated => cdhash H"4cb8c3f7…"
#     cert:    designated => identifier "…" and certificate root = H"340125…"
# Every ad-hoc rebuild therefore presents a *new* identity to TCC, silently
# invalidating the permissions the user granted. A certificate — even self-signed —
# makes the requirement stable across rebuilds.
LOCAL_IDENTITY="${LOCAL_IDENTITY:-ShortcutSense Local Signing}"
LOCAL_KEYCHAIN="${LOCAL_KEYCHAIN:-$HOME/ss-cert/ss.keychain}"

sign_with_local_identity() {
  # The keychain holding the identity must be unlocked and on the search list.
  # `find-identity` may report 0 for a non-login keychain even when signing works,
  # so success is judged by the signing call and the resulting requirement.
  security unlock-keychain -p "${LOCAL_KEYCHAIN_PASSWORD:-shortcutsense}" "$LOCAL_KEYCHAIN" 2>/dev/null || true
  local previous
  previous="$(security list-keychains -d user | tr -d '"' | xargs)"
  security list-keychains -d user -s "$LOCAL_KEYCHAIN" $previous
  local rc=0
  codesign --force --sign "$LOCAL_IDENTITY" "$APP" || rc=$?
  security list-keychains -d user -s $previous
  return $rc
}

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Signing with Developer ID: ${DEVELOPER_ID}"
  codesign --force --options runtime --timestamp \
    --sign "${DEVELOPER_ID}" "$APP"
elif [ -f "$LOCAL_KEYCHAIN" ]; then
  echo "==> Signing with local identity: ${LOCAL_IDENTITY}"
  sign_with_local_identity
else
  echo "==> Ad-hoc signing (no certificate available)"
  echo "    NOTE: TCC grants are invalidated by the next rebuild."
  codesign --force --sign - "$APP"
fi

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '1,12p'
echo "==> Built $APP"
