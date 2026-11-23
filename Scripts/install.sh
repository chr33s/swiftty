#!/bin/sh
# Builds, signs and installs Swiftty.app, installs durable SwiftMux sessions
# (the guardian and gateway helpers, spec.durability.md §9; the gateway also
# serves roaming clients) and, with --roaming, installs the swifttyd
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
#   --end-sessions     when moving to durable sessions, end the sessions the
#                      previous (single-process) SwiftMux agent is running;
#                      without it, installation stops while any are live
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
end_sessions=0
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
    --end-sessions) end_sessions=1; shift ;;
    --no-devices) devices=0; shift ;;
    -h | --help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
gateway_label=com.chr33s.swiftty.swiftmux-gateway
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

# By SHA-1, so duplicate certificates with one name stay unambiguous. The
# guardian and gateway authenticate each other by signing team, so durable
# sessions need a Developer ID identity; ad-hoc builds cannot run them.
if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning \
    | awk '/"Developer ID Application/ { print $2; exit }')
fi
if [ -z "$identity" ] || [ "$identity" = "-" ]; then
  echo "install.sh: durable SwiftMux sessions need a Developer ID signing identity (--identity)." >&2
  exit 1
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

new_team=$(team_of "$built/Contents/MacOS/swiftty")
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

# Durable sessions: the first install moves from the single-process agent
# (ending its sessions only with --end-sessions); later installs replace the
# gateway, keeping every running session.
swiftty="$app/Contents/MacOS/swiftty"
durable=$("$swiftty" --durable-sessions status 2>&1) || {
  echo "install.sh: cannot read durable session status: $durable" >&2; exit 1
}
case "$durable" in
  notInstalled)
    if [ "$end_sessions" -eq 1 ]; then
      result=$("$swiftty" --durable-sessions adopt --confirm 2>&1)
    else
      result=$("$swiftty" --durable-sessions adopt 2>&1)
    fi || { echo "install.sh: durable sessions: $result" >&2; exit 1; }
    case "$result" in
      declined*)
        echo "install.sh: the previous SwiftMux agent is running sessions ($result)." >&2
        echo "  Re-run with --end-sessions to end them and install durable sessions." >&2
        exit 1 ;;
    esac ;;
  *)
    result=$("$swiftty" --durable-sessions update 2>&1) || {
      echo "install.sh: durable sessions: $result" >&2; exit 1
    } ;;
esac
echo "durable sessions: $result"
gateway_helper="$HOME/Library/Application Support/SwiftMux/Helpers/SwiftMuxGateway.app/Contents/MacOS/swiftmux-gateway"

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

  # The gateway reads the configuration at launch. Restarting it keeps
  # every session (the guardian owns them); roaming clients reconnect.
  launchctl kickstart -k "$domain/$gateway_label" >/dev/null 2>&1 || true
  if ! nc -z localhost 22 >/dev/null 2>&1; then
    echo "note: Remote Login looks off; enable it in System Settings > General > Sharing"
  fi
  if [ "$configure_firewall" -eq 1 ]; then
    # The durable gateway owns the QUIC listener; swifttyd only relays SSH
    # bootstrap requests. Reapply after replacement, including repeat installs.
    # socketfilterfw accepts executables, not individual UDP port rules.
    firewall_agent=$gateway_helper
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
