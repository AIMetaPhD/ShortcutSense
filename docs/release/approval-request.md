# Release Approval Request — ShortcutSense v0.1.0

**Date:** 2026-10-26
**Status: NOT READY FOR G6. This is a request for two decisions, not for publication.**

Publication cannot be approved yet, because the acceptance matrix has release-blocking
items that no one has executed. This document separates what is proven from what is
merely written, and asks for the two things only the owner can provide.

---

## 1. What is proven

| Evidence | Result |
|---|---|
| Unit tests, Linux (Swift 6.2) | 149 passed |
| Unit tests, macOS 14 arm64 runner | 149 passed |
| Unit tests, macOS 15.7.9 arm64 runner | 149 passed |
| Full package build on macOS | passed, Xcode 16.4 / 16.6 |
| `.app` assembly + `codesign --verify --deep --strict` | passed, `Signature=adhoc` |
| DMG creation + SHA256 | `ShortcutSense-0.1.0-arm64.dmg`, `76380e4d…a3a48` |
| Checksum re-verified off-machine | matches |
| CI run | [40333209146](https://github.com/XiangchunChen/ShortcutSense-staging/actions/runs/40333209146) — success |

Staging repository (private): `XiangchunChen/ShortcutSense-staging`.

## 2. What is NOT proven, and why

Nothing in the list below has been executed. Every one of them needs a real Mac
desktop session.

| Blocked item | AC | Consequence if wrong |
|---|---|---|
| Permission prompts, TCC grant/revoke, tap creation | AC-04 | The app may collect nothing, or collect when it should not |
| A physical hotkey press reaching a real app | AC-12 | The core product claim is unverified |
| AX menu hit-testing | AC-10 | Automatic Learn cannot ship; it is already off by default |
| Secure Input / lock / sleep-wake behaviour | AC-05, AC-04 | Privacy claim unverified in the real environment |
| Gatekeeper "Open Anyway" clean install | AC-19, AC-23 | The DMG may not install at all |
| Live call to a running Ollama | AC-16 | The optional AI may not answer |

**The app has never been launched by a human.** CI runners are headless VMs; they
compile and test, they do not show a window.

## 3. Defects found

Seventeen, all documented in `docs/qa/defects.md`. Three were silent and would have
shipped broken:

1. **D-007** — CGEventFlags were reinterpreted as Carbon modifier bits. The layouts
   share no bits, so every shortcut lookup failed and every app activation was
   classified `unknown_origin`. The keystroke counters kept rising, so nothing looked
   wrong from the outside. This was found by an independent code review, not by tests.
2. **D-008** — deleting all data left OS hotkeys registered; they kept launching apps
   and writing fresh rows after the user was told everything was deleted.
3. **D-009** — a failed unregister dropped the record, leaving a grab the UI could
   never release.

All seventeen are fixed and covered by tests, but **none has been re-tested by Muse**
as the QA process requires.

## 4. Decision 1 — unblock the Mac

The MacBook is online on Tailscale and refuses SSH at the key stage
(`Permission denied (publickey)`). One of the following unblocks Muse and all the GUI
work:

**Option A — authorise the key.** On the Mac:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB9tOypfGAT9ltKC8LcB/1qnTA/weOA4xtHsEtJL17wB shortcutsense-mac-dev' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Then confirm from Windows: `bash Scripts/setup-mac-ssh.sh test`

**Option B — Muse runs the handoff directly on the Mac**, with GUI access, following
`docs/qa/muse-handoff.md`. No SSH is needed for that.

## 5. Decision 2 — publication is not on the table yet

G6 requires all three of: local core ACs PASS, a real clean install PASS, and the
owner's approval. The second is missing. Per the frozen plan, G5 with unresolved
core failures "must not be called a releasable v0.1.0".

When the Mac items pass, the approval request will contain exactly what the plan
requires: repository `AIMetaPhD/ShortcutSense`, licence, full AC table, macOS and
signing evidence, Release filename and SHA256, known limitations, and the one-line
diff for `AIMetaPhD/AIMetaPhD`.

## 6. Not done

- No public repository, no push to `AIMetaPhD`, no Release, no profile change.
- No notarization (no Developer ID certificate available to this environment).
- README install instructions describe the Gatekeeper path; they have not been
  followed on a real machine.
