#!/usr/bin/env bash
# Authorize this Windows workstation to SSH into the MacBook Air over Tailscale.
#
# Run the FIRST half on Windows (this repo root, in Git Bash), then paste the
# printed public key into the Mac. You only need to do this once.
#
#   bash Scripts/setup-mac-ssh.sh key      # on Windows: prints the public key
#   bash Scripts/setup-mac-ssh.sh test     # on Windows: verifies the connection
#
# On the Mac, run:
#
#   mkdir -p ~/.ssh && chmod 700 ~/.ssh
#   echo '<PASTE PUBLIC KEY HERE>' >> ~/.ssh/authorized_keys
#   chmod 600 ~/.ssh/authorized_keys
#
# If macOS still refuses the key, enable Remote Login and confirm the key is in
# the right file for the right user:
#   System Settings → General → Sharing → Remote Login
#   ssh -v <user>@<mac-hostname>   (from Windows) shows which key was offered
set -euo pipefail

MAC_HOST="${MAC_HOST:-<mac-hostname>}"
MAC_USER="${MAC_USER:-the-owner}"
KEY="${HOME}/.ssh/shortcutsense_mac"

case "${1:-test}" in
  key)
    if [ ! -f "$KEY" ]; then
      ssh-keygen -t ed25519 -f "$KEY" -N '' -C "shortcutsense-mac-dev" >/dev/null
    fi
    echo "Public key to append to ${MAC_USER}@${MAC_HOST}:~/.ssh/authorized_keys"
    echo
    cat "${KEY}.pub"
    ;;
  test)
    ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "${MAC_USER}@${MAC_HOST}" \
      'echo "connected"; sw_vers; uname -m; xcodebuild -version; swift --version | head -2'
    ;;
  *)
    echo "usage: $0 [key|test]" >&2
    exit 2
    ;;
esac
