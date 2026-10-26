#!/usr/bin/env bash
# Creates a reusable self-signed code-signing identity.
#
# Why this exists: an ad-hoc signature has no certificate to anchor to, so codesign
# writes the binary's hash into the designated requirement. macOS keys privacy
# grants to that requirement, which means every rebuild silently loses the user's
# Input Monitoring and Accessibility permissions. A certificate — even self-signed —
# makes the requirement stable across rebuilds.
#
# Run this in a GUI session (Terminal.app), not over SSH: importing into the login
# keychain needs the user's authorization, and SSH cannot provide it.
#
#   bash Scripts/make-cert.sh
set -euo pipefail

NAME="ShortcutSense Local Signing"
KEYCHAIN="$HOME/ss-cert/ss.keychain"
PASSWORD="${KEYCHAIN_PASSWORD:-shortcutsense}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  echo "identity already present in $KEYCHAIN"
  exit 0
fi

echo "==> Generating a 10-year self-signed code-signing certificate"
cd "$WORK"
cat > ext.cnf <<'CNF'
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS ships LibreSSL, which rejects -addext; -extensions with a config file works.
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=$NAME/O=ShortcutSense Local/C=HK" -extensions ext >/dev/null 2>&1
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem \
  -name "$NAME" -passout "pass:$PASSWORD" >/dev/null 2>&1

echo "==> Creating $KEYCHAIN"
mkdir -p "$(dirname "$KEYCHAIN")"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
# -A lets codesign use the key without a per-build prompt; the keychain itself is
# protected by its password and lives only in this user's home.
security import identity.p12 -k "$KEYCHAIN" -P "$PASSWORD" -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> Verifying by signing a scratch file"
echo probe > probe.bin
if codesign --force --sign "$NAME" --keychain "$KEYCHAIN" probe.bin 2>/dev/null; then
  echo "    signing works"
else
  echo "    signing FAILED" >&2
  exit 1
fi

echo
echo "Done. build-app.sh will use this identity automatically."
echo "  identity : $NAME"
echo "  keychain : $KEYCHAIN"
