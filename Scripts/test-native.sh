#!/bin/bash
# Run every manifest test bundle in its own synchronous main-loop host.
# Arguments are swift build options (-c release, -Xswiftc ...), plus --skip-build.
# Prebuilt Release tests need -Xswiftc -enable-testing when using --skip-build.
set -euo pipefail
repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"

build_arguments=()
skip_build=false
sdk_path=""
previous_argument=""
for argument in "$@"; do
  if [ "$argument" = --skip-build ]; then
    skip_build=true
  else
    build_arguments+=("$argument")
    if [ "$previous_argument" = --sdk ]; then
      sdk_path="$argument"
    fi
  fi
  previous_argument="$argument"
done
# Standalone swiftc from a swift.org toolchain has no default SDK; use the
# same SDK as swift build so the host can import AppKit.
export SDKROOT="${sdk_path:-${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
if [ "$skip_build" = false ]; then
  # Release also imports internals through @testable; swift build alone does
  # not enable testability for that configuration.
  swift build --build-tests -Xswiftc -enable-testing ${build_arguments[@]+"${build_arguments[@]}"}
fi
binary_directory=$(swift build --show-bin-path ${build_arguments[@]+"${build_arguments[@]}"})
export SWMUX_LAUNCHER="${SWMUX_LAUNCHER-$binary_directory/swmux-launcher}"
platform_developer="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-native-tests.XXXXXX")
trap 'rm -rf "$workspace"' EXIT

swiftc -swift-version 6 -parse-as-library Scripts/SwiftTestingHost.swift -o "$workspace/host"
swift package dump-package ${build_arguments[@]+"${build_arguments[@]}"} > "$workspace/package.json"
python3 - "$workspace/package.json" > "$workspace/targets" <<'PY'
import json
from pathlib import Path
import sys

package = json.loads(Path(sys.argv[1]).read_text())
for target in package["targets"]:
    if target["type"] == "test":
        print(target["name"])
PY
[ -s "$workspace/targets" ] || { echo "No test targets in the manifest" >&2; exit 1; }
# Load the same Xcode test frameworks and Swift runtime as the built bundles.
swiftc -print-target-info > "$workspace/toolchain.json"
runtime_libraries=$(python3 - "$workspace/toolchain.json" <<'PY'
import json
from pathlib import Path
import sys

# swift.org toolchains ship Swift Testing as libTesting.dylib under each
# runtime directory's testing/ subdirectory; Xcode uses Testing.framework.
paths = []
for path in json.loads(Path(sys.argv[1]).read_text())["paths"]["runtimeLibraryPaths"]:
    testing = Path(path) / "testing"
    if testing.is_dir():
        paths.append(str(testing))
    paths.append(path)
print(":".join(paths))
PY
)
export DYLD_FRAMEWORK_PATH="$platform_developer/Library/Frameworks:$platform_developer/Library/PrivateFrameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$platform_developer/usr/lib:$runtime_libraries:$binary_directory${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

run_bundles() {
  local status=0
  while IFS= read -r target; do
    local bundle="$binary_directory/$target.xctest/Contents/MacOS/$target"
    if [ ! -f "$bundle" ]; then
      echo "Missing test bundle: $target" >&2
      status=1
      continue
    fi
    echo "Running test bundle: $target"
    # Name the Swift Testing image the bundle links so the host avoids a
    # second copy loaded through XCTest (swift.org toolchain vs. Xcode).
    local testing_library
    testing_library=$({ otool -L "$bundle" 2>/dev/null || true; } | awk '
      $1 ~ /\/libTesting\.dylib$/ { print $1; found = 1; exit }
      $1 ~ /\/Testing\.framework\// && framework == "" { framework = $1 }
      END { if (!found && framework != "") print framework }
    ')
    # A silent zero exit can bypass the in-process ABI audit. Check each
    # bundle's raw output before another target can contribute completions.
    SWIFTTY_TEST_BUNDLE="$bundle" SWIFTTY_TESTING_LIBRARY="$testing_library" \
      "$workspace/host" 2>&1 \
      | tee "$workspace/bundle.log" || status=1
    if ! python3 Scripts/check-test-output.py --suite-log "$workspace/bundle.log"; then
      echo "Incomplete test bundle: $target" >&2
      status=1
    fi
  done < "$workspace/targets"
  return "$status"
}
run_bundles 2>&1 | tee "$workspace/suite.log"
python3 Scripts/check-test-output.py --suite-log "$workspace/suite.log"
