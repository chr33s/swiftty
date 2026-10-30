#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then
  echo 'usage: check-unchecked-sendable.sh' >&2
  exit 2
fi

# Every `@unchecked Sendable` conformance must document its mutable state,
# synchronization or immutability invariant, and backing-storage lifetime in
# a `/// Sendable:` paragraph of the doc comment directly above the
# declaration. A conformance may continue a declaration from earlier lines.
python3 - <<'PYTHON'
import os
import re
import sys

paths = [
    os.path.join(root, name)
    for top in ("Sources", "Apps")
    for root, _, names in os.walk(top)
    for name in names
    if name.endswith(".swift")
]
declaration = re.compile(
    r"^\s*(@\w+(\([^)]*\))?\s+)*"
    r"((public|package|internal|fileprivate|private|open|final|indirect)\s+)*"
    r"(class|struct|enum|actor|extension)\b"
)
failures = []
for path in sorted(paths):
    with open(path, encoding="utf-8") as file:
        lines = file.read().split("\n")
    for index, line in enumerate(lines):
        if "@unchecked Sendable" not in line.split("//", 1)[0]:
            continue
        start = index
        while start > 0 and not declaration.match(lines[start]):
            start -= 1
        if not declaration.match(lines[start]):
            failures.append(f"{path}:{index + 1}: declaration not found")
            continue
        documented = False
        above = start - 1
        # Attributes such as `@usableFromInline` may sit between the doc
        # comment and the declaration.
        while above >= 0 and lines[above].strip().startswith("@"):
            above -= 1
        while above >= 0 and lines[above].strip().startswith("///"):
            if lines[above].strip().startswith("/// Sendable:"):
                documented = True
            above -= 1
        if not documented:
            failures.append(
                f"{path}:{index + 1}: @unchecked Sendable lacks a "
                "\"/// Sendable:\" doc comment"
            )
for failure in failures:
    print(failure, file=sys.stderr)
sys.exit(1 if failures else 0)
PYTHON
