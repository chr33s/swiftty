#!/bin/sh
# Builds, signs and installs Swiftty.app, registers its bundled SwiftMux
# LaunchAgent (SMAppService) and, with --roaming, installs the swifttyd
# bootstrap helper and writes the roaming configuration (spec.inbox.md §1).
# Remote Login is reported, never changed. Firewall changes are opt-in.
#
# usage: Scripts/install.sh [options]
#   --identity ID      signing identity; default: match a running agent,
#                      else the first Developer ID identity or ad-hoc. See
#                      Scripts/notarize.sh for NOTARY_PROFILE etc.
#   --dest DIR         install directory (default /Applications)
#   --roaming          also set up remote clients:
#     --host NAME      advertised host (default `scutil --get LocalHostName`.local)
#     --bind ADDR      QUIC/UDP bind address (default 0.0.0.0)
#     --port N         UDP port (default 51222)
#   --configure-firewall  with --roaming, allow SwiftMux through the macOS
#                      firewall (uses sudo; leaves global policy unchanged)
#   --replace-dev-agent  remove a `swmux agent install` LaunchAgent first;
#                      its running sessions end
#   --restart-agent    re-register a running agent whose signing team
#                      changed, or (ad-hoc builds) whose binary changed;
#                      its running sessions end
#   --team TEAM        team for the iOS/iPadOS app (default: the Mac build's
#                      signing team); see Scripts/install-ios.sh
#   --no-devices       skip installing the iOS/iPadOS app on iPhones and
#                      iPads connected by USB or Wi-Fi
#
# Safe to run inside Swiftty: the running app is replaced in place, not quit.
set -eu
cd "$(dirname "$0")/.."

identity=""
dest=/Applications
roaming=0
configure_firewall=0
firewall=/usr/libexec/ApplicationFirewall/socketfilterfw
host=""
bind=0.0.0.0
port=51222
replace_dev=0
restart_agent=0
team=""
devices=1
while [ $# -gt 0 ]; do
  case "$1" in
    # --option=value is the same as --option value.
    --identity=* | --dest=* | --host=* | --bind=* | --port=* | --team=*)
      value=${1#*=}
      option=${1%%=*}
      shift
      set -- "$option" "$value" "$@"
      continue ;;
    --identity | --dest | --host | --bind | --port | --team)
      option=$1
      if [ $# -lt 2 ]; then
        echo "install.sh: $option requires a value" >&2; exit 64
      fi
      case "$2" in
        --* | -h) echo "install.sh: $option requires a value" >&2; exit 64 ;;
      esac
      case "$option" in
        --identity) identity=$2 ;;
        --dest) dest=$2 ;;
        --host) host=$2 ;;
        --bind) bind=$2 ;;
        --port) port=$2 ;;
        --team) team=$2 ;;
      esac
      shift 2 ;;
    --roaming) roaming=1; shift ;;
    --configure-firewall) configure_firewall=1; shift ;;
    --replace-dev-agent) replace_dev=1; shift ;;
    --restart-agent) restart_agent=1; shift ;;
    --no-devices) devices=0; shift ;;
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

if [ "$configure_firewall" -eq 1 ]; then
  if [ "$roaming" -ne 1 ]; then
    echo "install.sh: --configure-firewall requires --roaming" >&2; exit 64
  fi
  if [ ! -x "$firewall" ]; then
    echo "install.sh: macOS firewall tool unavailable: $firewall" >&2; exit 1
  fi
fi

case "$dest" in
  '' | -*) echo "install.sh: --dest must name a directory" >&2; exit 64 ;;
esac

# Validate before building, installing or changing a running agent. A
# canonical decimal port also keeps the generated JSON number unambiguous.
case "$port" in
  '' | *[!0-9]* | 0*)
    echo "install.sh: --port must be an integer from 1 to 65535" >&2; exit 64 ;;
esac
if [ ${#port} -gt 5 ] || [ "$port" -gt 65535 ]; then
  echo "install.sh: --port must be an integer from 1 to 65535" >&2; exit 64
fi

label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty
app="$dest/Swiftty.app"
helper=/usr/local/libexec/swifttyd
dev_plist="$HOME/Library/LaunchAgents/$label.plist"
roaming_dir="$HOME/Library/Application Support/SwiftMux/roaming"
roaming_config="$roaming_dir/config.json"
domain="gui/$(id -u)"

team_of() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed 's/^not set$//'
}
cdhash_of() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'
}
agent_info=$(launchctl print "$domain/$label" 2>/dev/null || true)
registered_team=$(printf '%s\n' "$agent_info" \
  | sed -n 's/.*"team-identifier" => "\(.*\)".*/\1/p' | head -n 1)

# By SHA-1, so duplicate certificates with one name stay unambiguous.
if [ -z "$identity" ]; then
  if [ "$restart_agent" -eq 0 ] \
    && printf '%s\n' "$agent_info" | grep -q 'state = running'; then
    if [ -z "$registered_team" ]; then
      identity=-
    else
      identity=$(security find-identity -v -p codesigning \
        | awk -v team="$registered_team" \
          '/"Developer ID Application/ && index($0, "(" team ")") { print $2; exit }')
      if [ -z "$identity" ]; then
        echo "install.sh: no Developer ID identity for the running agent's team '$registered_team'." >&2
        echo "  Use --identity with a matching identity, or --restart-agent (its running sessions end)." >&2
        exit 1
      fi
    fi
  else
    identity=$(security find-identity -v -p codesigning \
      | awk '/"Developer ID Application/ { print $2; exit }')
  fi
  [ -n "$identity" ] || identity=-
fi
echo "signing with ${identity}"

# The dev agent and the bundled one share a label and Mach service.
if [ -f "$dev_plist" ]; then
  if [ "$replace_dev" -eq 0 ]; then
    echo "install.sh: a development SwiftMux agent is installed ($dev_plist)." >&2
    echo "  Re-run with --replace-dev-agent (its running sessions end)." >&2
    exit 1
  fi
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f -- "$dev_plist"
  echo "removed development agent $dev_plist"
fi

Scripts/package-swiftmux.sh "$identity" .build/package
built=.build/package/Swiftty.app
bin=$(swift build -c release --show-bin-path)

# launchd pins the registered agent to the signing team it had when
# registered (a launch constraint); a different team is killed at spawn
# with "Launch Constraint Violation" until the agent is re-registered. An
# ad-hoc build has no team and is pinned to its agent's cdhash instead,
# which changes with every build: launchd then refuses to spawn it
# (EX_CONFIG, "needs LWCR update") once the running agent exits.
agent_info=$(launchctl print "$domain/$label" 2>/dev/null || true)
registered_team=$(printf '%s\n' "$agent_info" \
  | sed -n 's/.*"team-identifier" => "\(.*\)".*/\1/p' | head -n 1)
new_team=$(team_of "$built/Contents/MacOS/swiftmux-agent")
installed_agent="$app/Contents/MacOS/swiftmux-agent"
reason=""
if [ -n "$agent_info" ]; then
  if [ "$registered_team" != "$new_team" ]; then
    reason="registered for team '${registered_team:-none}', the new build is '${new_team:-none}'"
  elif [ -z "$new_team" ] && { [ ! -f "$installed_agent" ] \
    || [ "$(cdhash_of "$installed_agent")" != "$(cdhash_of "$built/Contents/MacOS/swiftmux-agent")" ]; }; then
    reason="an ad-hoc build, pinned to the previous agent binary"
  fi
fi
reregister=0
if [ -n "$reason" ]; then
  if printf '%s\n' "$agent_info" | grep -q 'state = running' \
    && [ "$restart_agent" -eq 0 ]; then
    echo "install.sh: the running SwiftMux agent is $reason." >&2
    echo "  Re-run with --restart-agent (its running sessions end), or sign" >&2
    echo "  with a Developer ID identity (--identity) to keep it across builds." >&2
    exit 1
  fi
  reregister=1
fi

# Inspect the exact destination before its old bundle is moved by publication.
# The newly built executable implements this query even on a first install.
running=$("$built/Contents/MacOS/swiftty" --running-app "$app") || {
  echo "install.sh: cannot determine whether the destination app is running" >&2
  exit 1
}
case "$running" in
  running | stopped) ;;
  *) echo "install.sh: invalid destination app state: $running" >&2; exit 1 ;;
esac

sudo_if_needed() {
  if [ -w "$1" ]; then shift; "$@"; else shift; sudo "$@"; fi
}
mkdir -p "$dest" 2>/dev/null || sudo mkdir -p "$dest"
sudo_if_needed "$dest" /usr/bin/python3 -I Scripts/install-app.py "$built" "$app" "$new_team"
echo "installed $app"

if [ "$reregister" -eq 1 ]; then
  echo "re-registering the SwiftMux agent ($reason)"
  "$app/Contents/MacOS/swiftty" --swiftmux-agent unregister >/dev/null || true
  launchctl bootout "$domain/$label" 2>/dev/null || true
fi
status=$("$app/Contents/MacOS/swiftty" --swiftmux-agent register || true)
echo "SwiftMux agent: $status"
case "$status" in
  *requiresApproval*)
    echo "  Allow \"Swiftty\" in System Settings > General > Login Items." ;;
  *enabled*) ;;
  *) echo "install.sh: agent registration failed" >&2; exit 1 ;;
esac

if [ "$roaming" -eq 1 ]; then
  # Sign as this user (the identity lives in the login keychain), then
  # install the signed copy as root.
  signed=.build/package/swifttyd
  cp "$bin/swifttyd" "$signed"
  if [ "$identity" = "-" ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi
  codesign --force --options runtime "$timestamp" --sign "$identity" \
    --identifier "$bundle_id.swifttyd" "$signed"
  codesign --verify --strict --verbose=1 "$signed"
  if [ -n "${NOTARY_PROFILE:-}${NOTARY_KEY_ID:-}" ] && [ "$identity" != "-" ]; then
    Scripts/notarize.sh "$signed"
  fi
  sudo mkdir -p "$(dirname "$helper")"
  sudo install -m 0755 -o root -g wheel "$signed" "$helper"
  codesign --verify --strict "$helper"
  echo "installed $helper"

  # The control directory must be owner-only (ControlDirectory).
  mkdir -p "$roaming_dir"
  chmod 0700 "$roaming_dir"
  if [ -f "$roaming_config" ]; then
    echo "kept existing $roaming_config"
  else
    [ -n "$host" ] || host="$(scutil --get LocalHostName).local"
    (
      umask 077
      temporary=$(mktemp "$roaming_dir/.config.XXXXXX")
      trap 'rm -f "$temporary"' EXIT
      trap 'exit 1' HUP INT TERM
      # Pass strings as values: plutil escapes JSON quotes, backslashes and
      # control characters. Publish only the completed configuration.
      plutil -create xml1 "$temporary"
      plutil -insert bindAddress -string "$bind" "$temporary"
      plutil -insert port -integer "$port" "$temporary"
      plutil -insert advertisedHost -string "$host" "$temporary"
      plutil -lint "$temporary" >/dev/null
      plutil -convert json "$temporary"
      mv "$temporary" "$roaming_config"
    )
    echo "wrote $roaming_config ($host, $bind:$port/udp)"
  fi

  # The agent reads the configuration at launch; restarting it would end
  # running shells, so an already running agent is left alone.
  if launchctl print "$domain/$label" 2>/dev/null | grep -q 'state = running'; then
    echo "note: the SwiftMux agent is running; roaming starts the next time it launches"
  fi
  if ! nc -z localhost 22 >/dev/null 2>&1; then
    echo "note: Remote Login looks off; enable it in System Settings > General > Sharing"
  fi
  if [ "$configure_firewall" -eq 1 ]; then
    # The bundled agent owns the QUIC listener; swifttyd only relays SSH
    # bootstrap requests. Reapply after replacement, including repeat installs.
    # socketfilterfw accepts executables, not individual UDP port rules.
    firewall_agent="$(cd "$app/Contents/MacOS" && pwd -P)/swiftmux-agent"
    firewall_state=$(LC_ALL=C "$firewall" --getglobalstate) || {
      echo "install.sh: cannot read macOS firewall state" >&2; exit 1
    }
    blockall_state=$(LC_ALL=C "$firewall" --getblockall) || {
      echo "install.sh: cannot read macOS firewall block-all state" >&2; exit 1
    }
    if ! sudo "$firewall" --add "$firewall_agent" \
      || ! sudo "$firewall" --unblockapp "$firewall_agent"; then
      echo "install.sh: could not configure the macOS firewall for SwiftMux" >&2; exit 1
    fi
    app_state=$(LC_ALL=C "$firewall" --getappblocked "$firewall_agent") || {
      echo "install.sh: cannot verify the SwiftMux firewall exception" >&2; exit 1
    }
    case "$app_state" in
      *" is permitted.") ;;
      *)
        echo "install.sh: SwiftMux firewall exception was not verified: $app_state" >&2
        exit 1 ;;
    esac
    echo "macOS firewall exception configured for SwiftMux"
    printf '%s\n' "$firewall_state" "$blockall_state"
    case "$firewall_state" in
      *"State = 0)"*) echo "note: macOS firewall is off; the exception applies when it is enabled" ;;
    esac
    case "$blockall_state" in
      *"block all state set to enabled."*)
        echo "note: Block all incoming connections overrides the SwiftMux exception; review System Settings > Network > Firewall > Options" ;;
    esac
    echo "note: other firewalls and routers may still need to allow the configured roaming UDP port; remote reachability is not verified"
  else
    echo "note: allow UDP $port through any firewall yourself; nothing is changed"
    echo "  To configure the macOS firewall, re-run with --roaming --configure-firewall."
  fi
fi

if [ "$running" = running ]; then
  echo "Swiftty is running the previous build; quit and reopen it to update."
else
  # A different copy can have the same bundle identifier. Open this copy.
  open -n "$app"
fi
if [ "$roaming" -eq 1 ]; then
  i=0
  until "$helper" status 2>/dev/null || [ $i -ge 50 ]; do sleep 0.2; i=$((i + 1)); done
  "$helper" status || echo "note: roaming is not serving yet; enable SwiftMux in the app"
fi

# The iOS/iPadOS app, on iPhones and iPads connected by USB, then Wi-Fi. The Mac
# install above is complete whether or not this succeeds.
if [ "$devices" -eq 1 ]; then
  [ -n "$team" ] || team=$new_team
  if [ -z "$team" ]; then
    echo "note: skipping iPhone/iPad install: an ad-hoc build has no team; pass --team"
  elif ! Scripts/install-ios.sh --team "$team"; then
    echo "install.sh: the Mac app is installed, but the iPhone/iPad install failed" >&2
    exit 1
  fi
fi
