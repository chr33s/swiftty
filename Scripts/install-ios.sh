#!/bin/sh
# Builds the iOS/iPadOS app (MobileClient, with its embedded watch
# companion) for devices and installs it on every iPhone and iPad
# connected over USB. Scripts/install.sh runs it after the Mac app.
#
# usage: Scripts/install-ios.sh --team TEAM [--device UDID]...
#   --team TEAM     Apple Developer team ID used for automatic signing;
#                   Xcode creates or updates the development profiles.
#   --device UDID   install only on this device (repeatable); default:
#                   every paired iPhone or iPad connected by USB.
#   --configuration Debug|Release (default Release)
#
# Devices must be paired with this Mac, unlocked and in Developer Mode.
set -eu
cd "$(dirname "$0")/.."

team=""
configuration=Release
devices=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team=* | --device=* | --configuration=*)
      value=${1#*=}
      option=${1%%=*}
      shift
      set -- "$option" "$value" "$@"
      continue ;;
    --team | --device | --configuration)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "install-ios.sh: $1 requires a value" >&2; exit 64
      fi
      case "$1" in
        --team) team=$2 ;;
        --device) devices="$devices $2" ;;
        --configuration) configuration=$2 ;;
      esac
      shift 2 ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-ios.sh: unknown option $1" >&2; exit 64 ;;
  esac
done
case "$team" in
  '') echo "install-ios.sh: --team is required for device signing" >&2; exit 64 ;;
  *[!A-Z0-9]*) echo "install-ios.sh: --team must be a team ID such as ABCDE12345" >&2; exit 64 ;;
esac
case "$configuration" in
  Debug | Release) ;;
  *) echo "install-ios.sh: --configuration must be Debug or Release" >&2; exit 64 ;;
esac
for tool in xcodegen xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "install-ios.sh: requires $tool" >&2; exit 1; }
done

# Paired, USB-connected physical iPhones and iPads (UDID and name).
work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-ios.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
xcrun devicectl list devices --quiet --json-output "$work/devices.json" >/dev/null
connected=$(/usr/bin/python3 -I - "$work/devices.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if (hw.get("reality") == "physical" and hw.get("platform") == "iOS"
            and conn.get("transportType") == "wired"
            and conn.get("pairingState") == "paired"
            # devicectl opens the tunnel on demand, so an idle device
            # reports "disconnected"; only "unavailable" is unusable.
            and conn.get("tunnelState") != "unavailable"):
        print(hw["udid"], d.get("deviceProperties", {}).get("name", hw["udid"]))
PY
)
if [ -n "$devices" ]; then
  wanted=""
  for udid in $devices; do
    line=$(printf '%s\n' "$connected" | awk -v u="$udid" '$1 == u')
    [ -n "$line" ] || { echo "install-ios.sh: device $udid is not connected by USB" >&2; exit 1; }
    wanted="$wanted$line
"
  done
  connected=$wanted
fi
if [ -z "$(printf '%s' "$connected" | tr -d '[:space:]')" ]; then
  echo "no iPhone or iPad connected by USB; skipping the iOS app"
  exit 0
fi

project=Apps/Swiftty.xcodeproj
xcodegen generate --quiet --spec Apps/project.yml --project Apps
derived=.build/ios
log=.build/ios-build.log
mkdir -p .build
echo "building the iOS app for team $team ($configuration)..."
if ! xcodebuild build -project "$project" -scheme MobileClient \
  -configuration "$configuration" -destination generic/platform=iOS \
  -derivedDataPath "$derived" -allowProvisioningUpdates \
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
  >"$log" 2>&1; then
  grep -E "error:|requires a provisioning profile|No Account" "$log" | head -5 >&2 || true
  echo "install-ios.sh: build failed; see $log" >&2
  exit 1
fi
app="$derived/Build/Products/$configuration-iphoneos/MobileClient.app"
[ -d "$app" ] || { echo "install-ios.sh: built app not found at $app" >&2; exit 1; }

status=0
printf '%s\n' "$connected" | while read -r udid name; do
  [ -n "$udid" ] || continue
  if xcrun devicectl device install app --quiet --device "$udid" "$app" \
    >"$work/install-$udid.log" 2>&1; then
    echo "installed Swiftty on $name"
  else
    echo "install-ios.sh: install on $name failed:" >&2
    tail -3 "$work/install-$udid.log" >&2
    exit 1
  fi
done || status=1
exit "$status"
