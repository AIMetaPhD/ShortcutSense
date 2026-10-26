#!/usr/bin/env bash
# Fails if a test class exists in Tests/ShortcutSenseCoreTests but is missing from the
# XCTest-shim runner's suite list. Without this, a new test silently never runs on a
# Mac that has no Xcode (the shim path), which is exactly how the count drifted once.
set -euo pipefail
cd "$(dirname "$0")/.."

missing=0
for f in Tests/ShortcutSenseCoreTests/*.swift; do
  # `final class Foo: XCTestCase` / `class Foo: XCTestCase`
  while read -r name; do
    [ -z "$name" ] && continue
    if ! grep -q "\"$name\"" Tools/TestRunner/main.swift; then
      echo "MISSING from Tools/TestRunner/main.swift: $name (declared in $f)"
      missing=1
    fi
  done < <(sed -n 's/.*class \([A-Za-z0-9_]*\): XCTestCase.*/\1/p' "$f")
done

if [ "$missing" -ne 0 ]; then
  echo "Add the missing classes to the suites list so the no-Xcode runner runs them."
  exit 1
fi
echo "test registry OK"
