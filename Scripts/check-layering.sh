#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then
  echo 'usage: check-layering.sh' >&2
  exit 2
fi

# The roaming client stack is layered so each piece is reusable on its own
# (README "Roaming SSH"): the headless core never reaches the renderer, a
# transport or a UI; adapters never reach the renderer; the TTY frontends
# never reach the renderer or the SwiftMux service connection. Checked on
# the manifest's transitive target graph and on each target's imports.
python3 - <<'PYTHON'
import json
import os
import re
import subprocess
import sys

renderer = {"SwifttyCore", "SwifttyMac", "SwifttyMobile"}
transports = {"SSHClient", "SSHIdentity", "AppleTransport"}
nio = {"NIOCore", "NIOPosix", "NIOSSH", "NIOTransportServices"}
mux_runtime = {"SwiftMuxClient", "SwiftMuxXPC", "SwiftMuxService"}
ui = {"AppKit", "UIKit", "SwiftUI", "Metal", "MetalKit", "CoreText"}
rules = {
    "RoamingKit": renderer | transports | nio | mux_runtime | ui | {"Network"},
    "RoamingConnect": renderer | mux_runtime | ui,
    "TTYKit": renderer | transports | nio | mux_runtime | ui | {"Network"},
    "RoamingTerminal": renderer | transports | nio | mux_runtime | ui
    | {"Network", "RoamingConnect"},
    "SwRoamCLI": renderer | mux_runtime | ui,
}

package = json.loads(
    subprocess.run(
        ["swift", "package", "dump-package"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
)
targets = {t["name"]: t for t in package["targets"]}


def direct(name):
    out = set()
    for dependency in targets[name].get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in dependency:
                out.add(dependency[kind][0])
    return out


def closure(name):
    seen, stack = set(), [name]
    while stack:
        for dependency in direct(stack.pop()):
            if dependency not in seen:
                seen.add(dependency)
                if dependency in targets:
                    stack.append(dependency)
    return seen


failures = []
for name, forbidden in rules.items():
    if name not in targets:
        failures.append(f"Package.swift: missing target {name}")
        continue
    for reached in sorted(closure(name) & forbidden):
        failures.append(f"Package.swift: {name} reaches {reached}")
    path = targets[name].get("path") or f"Sources/{name}"
    for root, _, names in os.walk(path):
        for file in sorted(names):
            if not file.endswith(".swift"):
                continue
            full = os.path.join(root, file)
            for number, line in enumerate(open(full), 1):
                match = re.match(r"\s*(?:@\w+\s+)*import\s+(\w+)", line)
                if match and match.group(1) in forbidden:
                    failures.append(f"{full}:{number}: import {match.group(1)}")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PYTHON
