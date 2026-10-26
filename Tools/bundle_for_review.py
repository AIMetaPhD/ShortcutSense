"""Bundles the Swift sources into a compact payload for a Muse review task.

The Muse queue accepts a request body up to 64 KiB, so the sources are gzipped and
base64 encoded and placed in inputs.sources_b64.
"""

import base64
import gzip
import json
import os
import sys


def collect():
    files = {}
    for root, _, names in os.walk('Sources'):
        for name in names:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, encoding='utf-8') as handle:
                    files[path.replace(os.sep, '/')] = handle.read()
            except (UnicodeDecodeError, OSError):
                continue
    with open('Package.swift', encoding='utf-8') as handle:
        files['Package.swift'] = handle.read()
    return files


def main():
    files = collect()
    raw = json.dumps(files, ensure_ascii=False).encode('utf-8')
    packed = base64.b64encode(gzip.compress(raw, 9)).decode()
    out = os.path.join(os.environ.get('TEMP', '/tmp'), 'src-b64.txt')
    with open(out, 'w', encoding='utf-8') as handle:
        handle.write(packed)
    print('files:', len(files))
    print('raw chars:', len(raw))
    print('packed:', len(packed), '->', out)
    if len(packed) > 60_000:
        print('WARNING: payload too large for one task body; split the file list')
    return 0


if __name__ == '__main__':
    sys.exit(main())
