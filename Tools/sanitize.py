"""Removes personal identifiers from tracked files before publication.

Run from the repository root:  python Tools/sanitize.py

Every rule matches the *shape* of an account name, home path or staging URL, so
this file never stores a value it is meant to remove. That keeps the sanitizer
safe to publish alongside the code it sanitizes.
"""

import os
import re
import sys


SUBS = [
    # Home directories: keep the structure, replace the account name.
    (r'/Users/[A-Za-z0-9._-]+', '/Users/example'),
    (r'C:\\Users\\[A-Za-z0-9._-]+', 'C:\\Users\\example'),
    # The retired staging repository, matched by URL shape rather than by name.
    (r'github\.com/[A-Za-z0-9_.-]+/ShortcutSense-staging',
     'github.com/<account>/ShortcutSense-staging'),
    (r'`[A-Za-z0-9_.-]+/ShortcutSense-staging`',
     '`<account>/ShortcutSense-staging`'),
    # Machine names.
    (r'\bmacbook\b', '<mac-hostname>'),
]

SKIP_DIRS = {'.git', '.build', 'artifacts', 'release', 'Tools/TestRunner/Tests'}
SUFFIXES = {'.md', '.sh', '.py', '.swift', '.yml', '.txt', '.h', '.modulemap'}


def main() -> int:
    root = os.path.abspath('.')
    self_path = os.path.abspath(__file__)
    changed = []

    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        # Compare whole relative paths, not bare names: "release" must skip the
        # build output at the repository root but never "docs/release".
        dirnames[:] = [
            d for d in dirnames
            if os.path.normpath(os.path.join(rel_dir, d)).replace(os.sep, '/')
            not in SKIP_DIRS
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
