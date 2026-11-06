#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then
  echo 'usage: check-agent-purity.sh' >&2
  exit 2
fi

# spec.shell.md §11.6, steps A1 and B1: no decoding, preview, or denial
# path may reach effectful shell preparation, a host launch, or a redirection.
# SwifttyExec (the context protocol and admission) therefore has no
# package dependency beyond SHA-256 on Linux, and SwshAgent (swsh's headless interface) depends on it
# alone. Neither names an API that starts a process or touches the filesystem,
# the environment, or the network. Standard input and output are the only I/O.
python3 - <<'PYTHON'
import os
import re
import sys

failures = []
manifest = open("Package.swift").read()
if '.target(name: "SwifttyExec", dependencies: [linuxCrypto]),' not in manifest:
    failures.append("Package.swift: SwifttyExec may depend on Linux SHA-256 only")
if '.target(name: "SwshAgent", dependencies: ["SwifttyExec"]),' not in manifest:
    failures.append("Package.swift: SwshAgent may depend on SwifttyExec only")
allowed = {"Darwin", "Glibc", "Musl", "CryptoKit", "Crypto", "SwifttyExec"}
forbidden = re.compile(
    r"\b(posix_spawn\w*|fork|vfork|exec[lv]\w*|system|popen|dlopen|open|openat|"
    r"creat|fopen|unlink\w*|rename\w*|mkdir\w*|rmdir|chdir|fchdir|glob|opendir|"
    r"getenv|setenv|environ|socket|connect|Process|FileManager|FileHandle|"
    r"URLSession|NSTask)\s*\("
    r"|\benviron\b|\bProcessInfo\b|\bCommandLine\b"
)
for top in ("Sources/SwifttyExec", "Sources/SwshAgent"):
  for root, _, names in os.walk(top):
    for name in sorted(names):
          path = os.path.join(root, name)
          for number, line in enumerate(open(path), 1):
              code = line.split("//")[0]
              match = re.match(r"\s*(?:@\w+\s+)*import\s+(\w+)", code)
              if match and match.group(1) not in allowed:
                  failures.append(f"{path}:{number}: import {match.group(1)}")
              found = forbidden.search(code)
              if found:
                  failures.append(f"{path}:{number}: {found.group(0).strip()}")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PYTHON
