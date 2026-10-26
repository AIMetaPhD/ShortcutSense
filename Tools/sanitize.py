"""Removes personal identifiers from tracked files before publication.

Run from the repository root:  python Tools/sanitize.py

The identifiers are assembled at runtime rather than written literally, so this
file — which has to live in the repository to be useful — does not itself contain
the strings it removes. The script skips its own path, so it is idempotent and safe
to re-run after any edit.
"""

import os
import re
import sys


def _s(*parts):
    """Joins fragments so the sensitive literal never appears in this source."""
    return ''.join(parts)


WORD = r'\b'

SUBS = [
    # Local account names on the development machine and on the target Mac.
    (WORD + _s('alex', 'chen') + WORD, 'the-owner'),
    (WORD + _s('alex') + WORD, 'the-owner'),
    (_s('{{USERNAME_', 'gajs5wuf}}'), 'the-owner'),
    (_s('{{USERNAME_', '2enyv35g}}'), 'the-owner'),
    (_s('{{USERNAME_', '5tg55gdw}}'), 'the-owner'),
    # Machine hostnames and Tailscale addresses.
    (_s('{{HOSTNAME_', '7nxeug5z}}'), '<mac-hostname>'),
    (_s('{{HOSTNAME_', 'ysmkbpsb}}'), '<mac-hostname>'),
    (_s('{{HOSTNAME_', 'ut5nnfi6}}'), '<workstation-hostname>'),
    (WORD + _s('mac', 'book') + WORD, '<mac-hostname>'),
    (_s('100', r'\.113', r'\.5', r'\.29'), '<mac-ip>'),
    (_s('100', r'\.70', r'\.141', r'\.110'), '<muse-ip>'),
    (_s('100', r'\.111', r'\.90', r'\.123'), '<workstation-ip>'),
    # Absolute home paths.
    (_s('/Users/', 'alex'), '/Users/example'),
    (_s('C:', '\\\\Users\\\\', 'alex'), 'C:\\\\Users\\\\example'),
]

SKIP_DIRS = {'.git', '.build', 'artifacts', 'release', 'Tools/TestRunner/Tests'}
SUFFIXES = {'.md', '.sh', '.py', '.swift', '.yml', '.txt', '.h', '.modulemap'}


def main() -> int:
    root = os.path.abspath('.')
    self_path = os.path.abspath(__file__)
    changed = []

    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIRS
            and os.path.join(rel_dir, d).replace(os.sep, '/') not in SKIP_DIRS
        ]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.abspath(path) == self_path:
                continue
            if os.path.splitext(name)[1] not in SUFFIXES:
                continue
            try:
                with open(path, encoding='utf-8') as handle:
                    text = handle.read()
            except (UnicodeDecodeError, OSError):
                continue

            original = text
            for pattern, replacement in SUBS:
                # A lambda keeps re from interpreting escapes in the replacement.
                text = re.sub(pattern, lambda _m, r=replacement: r, text)
            if text != original:
                with open(path, 'w', encoding='utf-8', newline='\n') as handle:
                    handle.write(text)
                changed.append(os.path.relpath(path, root).replace(os.sep, '/'))

    for item in sorted(changed):
        print('  sanitized:', item)
    print('total files changed:', len(changed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
