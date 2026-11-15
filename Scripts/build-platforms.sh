#!/bin/sh
# Builds every roaming-SSH product for its generic destination and records
# A0 build evidence (spec.roaming.md §2.4, §13 A0).
#
# usage: Scripts/build-platforms.sh [evidence-file]
#
# - Generates Apps/project.yml with XcodeGen. The project must sit beside
#   the spec because Xcode resolves the local package path (`..`) and the
#   entitlements paths relative to the project directory, so it is written
#   to Apps/Swiftty.xcodeproj, which is gitignored (*.xcodeproj) and
#   never committed. Derived data, logs and evidence go to a temp dir.
# - XcodeGen's preGenCommand runs Scripts/configure-links.sh, which writes
#   Apps/Config/Generated/ from SWIFTTY_LINK_DOMAINS (spec.inbox.md §4.4).
#   The evidence records the associated domains each target was given:
#   none when the variable is unset.
# - Builds each app with CODE_SIGNING_ALLOWED=NO for: iOS Simulator,
#   Mac Catalyst, visionOS Simulator, tvOS Simulator and watchOS
#   Simulator.
# - Builds the swifttyd helper with SwiftPM.
# - Writes an evidence file with toolchain/SDK versions, destinations and
#   pass/fail per target. Exit status is non-zero if a build or report failed.
#
# This is BUILD evidence only. Simulator/device runtime validation, physical
# hardware, entitlements under real signing, and paired-watch tests are
# separate release gates and are not exercised here.
set -u

for tool in xcodegen xcodebuild swift; do
  command -v "$tool" >/dev/null || { echo "required tool: $tool" >&2; exit 1; }
done

repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-platforms.XXXXXX") || exit 1
evidence=${1:-"$work/build-evidence.txt"}
logs="$work/logs"
derived="$work/DerivedData"
mkdir -p "$logs" || exit 1

echo "Workspace: $work"
xcodegen generate --quiet \
  --spec "$repository_root/Apps/project.yml" \
  --project "$repository_root/Apps" || { echo "xcodegen failed" >&2; exit 1; }
project="$repository_root/Apps/Swiftty.xcodeproj"

# Resolve package dependencies once so per-target builds share the result.
xcodebuild -resolvePackageDependencies -project "$project" \
  -scheme MobileClient -derivedDataPath "$derived" \
  >"$logs/resolve.log" 2>&1 || echo "package resolution failed; see $logs/resolve.log" >&2

failures=0
evidence_failed=0

evidence_error() {
  if [ "$evidence_failed" -eq 0 ]; then
    echo "Build evidence incomplete: $evidence (logs: $logs)" >&2
  fi
  evidence_failed=1
}

# Each command's write status is checked independently; a later successful
# write cannot hide a lost section. Continue collecting every build result.
record_evidence() {
  "$@" >>"$evidence" || evidence_error
}

# Capture the version command's status before filtering its diagnostic lines.
record_swift_version() {
  if version_text=$("$@" 2>&1); then
    :
  else
    evidence_error
  fi
  printf '%s\n' "$version_text" | grep -v libSwiftScan >>"$evidence" || evidence_error
}

: >"$evidence" || evidence_error

record_evidence echo "# Roaming SSH platform build evidence (spec.roaming.md A0)"
record_evidence echo
record_evidence echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
record_evidence echo "Host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
record_evidence echo "Revision: $(git -C "$repository_root" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$repository_root" diff --quiet 2>/dev/null || echo ' (with uncommitted changes)')"
record_evidence echo
record_evidence echo "## swift --version (SwiftPM swifttyd build)"
record_swift_version swift --version
record_evidence echo
record_evidence echo "## xcodebuild -version (app builds)"
record_evidence xcodebuild -version
record_evidence echo
record_evidence echo "## Xcode toolchain swift"
record_swift_version xcrun swift --version
record_evidence echo
record_evidence echo "## SDKs"
for sdk in iphoneos iphonesimulator macosx appletvos appletvsimulator \
  xros xrsimulator watchos watchsimulator; do
  record_evidence printf '%-18s %s (%s)\n' "$sdk" \
    "$(xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null || echo missing)" \
    "$(xcrun --sdk "$sdk" --show-sdk-build-version 2>/dev/null || echo -)"
done
record_evidence echo
record_evidence echo "## Resolved package dependencies"
resolved="$repository_root/Package.resolved"
if [ -f "$resolved" ]; then
  record_evidence /usr/bin/python3 - "$resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1])).get("pins", [])
for pin in pins:
    state = pin.get("state", {})
    print(f'{pin.get("identity")}: {state.get("version") or state.get("branch")} @ {state.get("revision")}')
PY
else
  record_evidence echo "Package.resolved not present"
fi
record_evidence echo
record_evidence echo "## Universal Links (SWIFTTY_LINK_DOMAINS=${SWIFTTY_LINK_DOMAINS:-})"
for target in MobileClient CatalystClient VisionClient; do
  entitlements="$repository_root/Apps/Config/Generated/$target.entitlements"
  if domains=$(/usr/bin/python3 -I - "$entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    domains = plistlib.load(f).get("com.apple.developer.associated-domains", [])
print(" ".join(domains) or "no associated domains")
PY
  ); then
    :
  else
    evidence_error
  fi
  record_evidence printf '%-16s %s\n' "$target" "$domains"
done
record_evidence printf '%-16s %s\n' "TVClient" "no associated domains (swiftty:// only)"
record_evidence echo
record_evidence echo "## Builds (deployment target 27.0 everywhere; CODE_SIGNING_ALLOWED=NO)"
record_evidence echo
record_evidence printf '%-16s %-48s %s\n' "Target" "Destination" "Result"

# build <scheme> <destination>
build() {
  scheme=$1
  destination=$2
  log="$logs/$scheme.log"
  echo "Building $scheme for $destination"
  if xcodebuild build -project "$project" -scheme "$scheme" \
    -destination "$destination" -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    >"$log" 2>&1; then
    result=PASS
  else
    result="FAIL (log: $log)"
    failures=$((failures + 1))
    grep -E "error:" "$log" | sort -u | head -20 >&2
  fi
  warning_log="$logs/$scheme.warnings"
  # Opening the output may fail with status 1, which also means no matches
  # from grep. Capture the grep result only after redirection succeeds.
  {
    if grep -E "^/[^:]*/Apps/[^:]*\.swift:[0-9]+:[0-9]+: warning:" "$log"; then
      warning_status=0
    else
      warning_status=$?
    fi
  } >"$warning_log" || warning_status=unavailable
  case "$warning_status" in
    0) warnings=$(sort -u "$warning_log" | wc -l | tr -d ' ') ;;
    1) warnings=0 ;;
    *) warnings=unavailable; evidence_error ;;
  esac
  record_evidence printf '%-16s %-48s %s; app-source warnings: %s\n' \
    "$scheme" "$destination" "$result" "$warnings"
}

build MobileClient "generic/platform=iOS Simulator"
build CatalystClient "generic/platform=macOS,variant=Mac Catalyst"
build VisionClient "generic/platform=visionOS Simulator"
build TVClient "generic/platform=tvOS Simulator"
build WatchCompanion "generic/platform=watchOS Simulator"

# The watch target must link only CompanionModel and MuxNavigation (spec §2.2).
watch_log="$logs/WatchCompanion.log"
if grep -qE "SwifttyCore|SSHClient|NIOSSH|NIOCore|RoamingKit|TerminalSurface|AppleTransport" "$watch_log"; then
  record_evidence echo "WatchCompanion dependency check: FAIL (direct-client modules built for watchOS)"
  failures=$((failures + 1))
else
  case $? in
    1) record_evidence echo "WatchCompanion dependency check: PASS (only CompanionModel and MuxNavigation built for watchOS)" ;;
    *)
      record_evidence echo "WatchCompanion dependency check: FAIL (cannot read $watch_log)"
      failures=$((failures + 1))
      ;;
  esac
fi

echo "Building swifttyd with SwiftPM"
if (cd "$repository_root" && swift build --product swifttyd) >"$logs/swifttyd.log" 2>&1; then
  result=PASS
else
  result="FAIL (log: $logs/swifttyd.log)"
  failures=$((failures + 1))
fi
record_evidence printf '%-16s %-48s %s\n' "swifttyd" "SwiftPM, native macOS host" "$result"

record_evidence echo
record_evidence echo "## Scope of this evidence"
record_evidence echo
record_evidence echo "Build-only: each product compiled and linked for its generic destination."
record_evidence echo "NOT covered: simulator or device launch, runtime behaviour, physical"
record_evidence echo "iPhone/iPad/Apple Vision/Apple TV/paired Apple Watch runs, signed"
record_evidence echo "entitlements, the 27.x shipping-runtime matrix, SSH/RST/SFTP tests."
record_evidence echo "Those device/runtime gates (spec §2.4, A0) are validated separately."

cat "$evidence" || evidence_error
if [ "$evidence_failed" -eq 0 ]; then
  printf '\nEvidence: %s\n' "$evidence" || evidence_error
fi
[ "$failures" -eq 0 ] && [ "$evidence_failed" -eq 0 ]
