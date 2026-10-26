#!/bin/bash
# Run this ON THE MAC, in Terminal, as the user you are trying to log in as.
# Paste the whole output back. It prints no private key material.
#
#   bash mac-ssh-diagnose.sh > /tmp/ssh-diag.txt 2>&1; open /tmp/ssh-diag.txt
#
# WHY: the client offers the key (fingerprint SHA256:DU6xYV1Ha/okSNaVxSb5ezaFDA/ipuDsDYI/iROy+q8)
# and the server refuses it. These checks cover every common cause on the server side.

EXPECTED_FP="SHA256:DU6xYV1Ha/okSNaVxSb5ezaFDA/ipuDsDYI/iROy+q8"

echo "== identity =="
whoami
echo "HOME=$HOME"
sw_vers
echo

echo "== permissions (sshd StrictModes rejects group/world-writable home) =="
ls -ld "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys" 2>&1
stat -f '%Sp %Su %Sg %N' "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys" 2>&1
echo

echo "== is the key present, and does it parse? =="
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  LINES=$(grep -c 'shortcutsense-mac-dev' "$HOME/.ssh/authorized_keys")
  echo "matching lines: $LINES"
  echo "fingerprints in the file:"
  ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>&1
  echo "does the expected fingerprint appear?"
  ssh-keygen -lf "$HOME/.ssh/authorized_keys" 2>&1 | grep -F "$EXPECTED_FP" && echo "MATCH" || echo "NO MATCH"
  echo "line endings (CRLF breaks the file silently):"
  file "$HOME/.ssh/authorized_keys"
  awk 'END{print "total lines:", NR}' "$HOME/.ssh/authorized_keys"
else
  echo "authorized_keys DOES NOT EXIST for $HOME"
fi
echo

echo "== macOS app sandbox / Remote Login state =="
echo "(System Settings > General > Sharing > Remote Login must be ON, and this user allowed)"
systemsetup -getremotelogin 2>&1 | head -2
echo

echo "== sshd effective settings that can reject a valid key =="
grep -vE '^\s*#|^\s*$' /etc/ssh/sshd_config 2>/dev/null \
  | grep -iE "allowusers|denyusers|allowgroups|denygroups|pubkey|authorizedkeysfile|strictmodes|authenticationmethods|permitrootlogin|chroot"
echo

echo "== what the server logged for the last attempt =="
echo "(run this right after a failed attempt from Windows for the clearest result)"
log show --last 10m --predicate 'process == "sshd"' 2>/dev/null | tail -30
echo

echo "== is the key perhaps in a different user's file? =="
echo "candidate users with an .ssh directory:"
for d in /Users/*; do
  [ -d "$d/.ssh" ] && echo "  $d  $(ls -ld "$d/.ssh" | awk '{print $1}')"
done
