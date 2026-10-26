#!/usr/bin/env bash
# Runs the full core test suite on a Mac that has only Command Line Tools.
#
# XCTest ships with Xcode, not with the Command Line Tools, so `swift test` cannot
# build test targets there. This copies the real test sources into the runner target
# with exactly one change — `import XCTest` becomes `import Foundation`, because the
# shim supplies the XCTest API — so the assertions executed are byte-identical.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf Tools/TestRunner/Tests
mkdir -p Tools/TestRunner/Tests
for f in Tests/ShortcutSenseCoreTests/*.swift; do
  # Files may carry CRLF line endings (they are edited on Windows), so match
  # without anchoring to end-of-line.
  sed 's/^import XCTest/import Foundation/' "$f" > "Tools/TestRunner/Tests/$(basename "$f")"
done

echo "Test files linked: $(ls -1 Tools/TestRunner/Tests | wc -l | tr -d ' ')"
swift run -c debug ShortcutSenseTests 2>&1 | tee /tmp/shortcutsense-tests.txt
status=${PIPESTATUS[0]}
rm -rf Tools/TestRunner/Tests
exit "$status"
