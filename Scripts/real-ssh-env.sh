#!/bin/sh
# Real OpenSSH + real swifttyd environment, reusable by several test drivers
# without touching this Mac's SSH setup.
#
#   Scripts/real-ssh-env.sh start [state-dir]   # prints the env file path
#   Scripts/real-ssh-env.sh stop  <state-dir>
# Set RST_REAL_SSH_CONFIGURATION=release for optimized host products (default: debug).
# With RST_PUBLIC_HOST (serving physical devices) the agent is signed with
# RST_REAL_SSH_SIGN_IDENTITY (default: the first Developer ID Application
# identity in the keychain; "-" keeps the ad-hoc signature), so the macOS
# firewall admits it as signed software.
#
# `start` brings up, and leaves running in the background:
#  - a real SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on this Mac (QUIC on 127.0.0.1:<quic port>);
#  - an apple/container Linux VM running OpenSSH (sshd, sftp-server) as user
#    `rst` with a random password and authorized Ed25519 key. Its fixed
#    helper path /usr/local/libexec/swifttyd relays `bootstrap --stdio` over
#    TCP to a bridge here, which forwards to the agent's control socket
#    (swifttyd itself is macOS-only and cannot run in the VM);
#  - a loopback relay 127.0.0.1:<ssh port> to the VM's sshd through
#    `container exec`. macOS Local Network privacy can refuse non-system
#    binaries a route to the VM subnet (EHOSTUNREACH); loopback is always
#    reachable, including from the iOS simulator, which shares it.
#
# It writes `<state-dir>/env`, a sourceable file of exports:
#   RST_REAL_SSH_HOST RST_REAL_SSH_PORT RST_REAL_SSH_USER
#   RST_REAL_SSH_PASSWORD RST_REAL_SSH_HOSTKEY RST_REAL_SSH_FINGERPRINT
#   RST_REAL_SSH_KEY_HEX RST_REAL_SSH_QUIC_PORT RST_REAL_SSH_ENV_DIR
# and prints its path as the only line on stdout (progress goes to stderr).
# `stop` asks each process owner to terminate/reap its child, then removes the VM.
# Legacy PID-only records are retained: a saved PID cannot establish ownership.
set -eu
usage() { echo "usage: $0 start [state-dir] | stop <state-dir>" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
repository_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

stop() {
  dir=$1
  [ -d "$dir" ] || return 0
  cleanup_status=0
  for f in xcodebuild advertiser relay bridge host; do
    if [ -e "$dir/$f.pid" ] || [ -L "$dir/$f.pid" ] ||
       [ -e "$dir/$f.owner" ] || [ -L "$dir/$f.owner" ]; then
      if [ ! -e "$dir/$f.owner" ] && [ ! -L "$dir/$f.owner" ]; then
        echo "no process owner for $dir/$f.pid; legacy PID marker retained" >&2
        cleanup_status=1
      elif ! python3 -I "$repository_root/Scripts/real-ssh-process.py" stop "$dir" "$f"; then
        cleanup_status=1
      fi
    fi
  done
  if [ -e "$dir/container.name" ] || [ -L "$dir/container.name" ]; then
    python3 -I "$repository_root/Scripts/real-ssh-container.py" "$dir" || return 1
  fi
  return "$cleanup_status"
}

case $1 in
  stop)
    [ "$#" -eq 2 ] || usage
    if [ -e "$2/start.lock" ] || [ -L "$2/start.lock" ]; then
      echo "fixture startup still recorded in $2; cannot stop concurrently" >&2
      exit 1
    fi
    stop "$2"; exit $? ;;
  start) [ "$#" -le 2 ] || usage ;;
  *) usage ;;
esac

build_configuration=${RST_REAL_SSH_CONFIGURATION-debug}
case "$build_configuration" in
  debug|release) ;;
  *) echo "RST_REAL_SSH_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac

command -v container >/dev/null || { echo "apple/container required" >&2; exit 1; }
umask 077
workspace=${2:-$(mktemp -d /tmp/rstr.XXXXXX)}
mkdir -p "$workspace"
workspace=$(CDPATH= cd "$workspace" && pwd)
# Serialize resource creation. A second start must never roll back the first
# invocation's resources; only our own EXIT handler bypasses this startup lock.
mkdir "$workspace/start.lock" 2>/dev/null || {
  echo "fixture startup already recorded in $workspace" >&2
  exit 1
}
trap 'rmdir "$workspace/start.lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for marker in host.pid bridge.pid relay.pid advertiser.pid xcodebuild.pid host.owner bridge.owner relay.owner advertiser.owner xcodebuild.owner container.name; do
  [ ! -e "$workspace/$marker" ] && [ ! -L "$workspace/$marker" ] || {
    echo "fixture resources already recorded in $workspace; stop them before starting" >&2
    exit 1
  }
done
# Validate and normalize both advertised ports before building or spawning resources.
ports=$(python3 -I "$repository_root/Scripts/real-ssh-config.py" ports \
  "${RST_QUIC_PORT-$((51500 + $$ % 400))}" "${RST_SSH_PORT-$((52000 + $$ % 400))}") \
  || exit 2
read quic_port ssh_port <<EOF
$ports
EOF
setup_complete=0
cleanup_start() {
  setup_status=$?
  trap - EXIT
  trap '' INT TERM
  if [ "$setup_complete" -eq 0 ]; then
    stop "$workspace" || echo "fixture cleanup incomplete: $workspace" >&2
  fi
  rmdir "$workspace/start.lock" || echo "fixture startup lock retained: $workspace" >&2
  exit "$setup_status"
}
trap cleanup_start EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fixture_id=$(uuidgen)
name="swiftty-rst-ssh-$$-$(printf '%s' "$fixture_id" | tr 'A-Z' 'a-z')"
echo "Workspace: $workspace" >&2
fail() {
  echo "$*" >&2
  exit 1
}

container build --progress plain -t swiftty-rst-ssh:test \
  -f "$repository_root/Tests/RealSSH/Containerfile" \
  "$repository_root/Tests/RealSSH" >"$workspace/build.log" 2>&1 \
  || fail "container build failed; see $workspace/build.log"

(cd "$repository_root" && mise exec -- swift build -c "$build_configuration" --product swiftmux-agent && mise exec -- swift build -c "$build_configuration" --product swmux-launcher && mise exec -- swift build -c "$build_configuration" --product swifttyd) >"$workspace/swift-build.log" 2>&1 \
  || fail "swifttyd build failed; see $workspace/swift-build.log"
bin_dir="$(cd "$repository_root" && mise exec -- swift build -c "$build_configuration" --show-bin-path)"
host_bin="$bin_dir/swiftmux-agent"
# RST_PUBLIC_HOST=<this Mac's LAN address> serves physical devices: swifttyd
# and the SSH relay listen on all interfaces and grants advertise that
# address. Default: loopback only (simulators and local tests).
public_host=${RST_PUBLIC_HOST:-}
if [ -n "$public_host" ]; then
  bind_address=0.0.0.0; advertised=$public_host; relay_bind=0.0.0.0
else
  bind_address=127.0.0.1; advertised=127.0.0.1; relay_bind=127.0.0.1
fi
# The firewall can refuse LAN connections to a rebuilt ad-hoc binary while
# still listing its path as allowed (devices then never reach QUIC; SSH
# through the relay still works). Loopback is never filtered.
if [ -n "$public_host" ]; then
  sign_identity=${RST_REAL_SSH_SIGN_IDENTITY-}
  if [ -z "$sign_identity" ]; then
    sign_identity=$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)
  fi
  if [ -z "$sign_identity" ]; then
    echo "warning: no Developer ID Application identity; the firewall may refuse devices" >&2
  elif [ "$sign_identity" != "-" ]; then
    codesign --force --sign "$sign_identity" --timestamp=none "$host_bin" \
      >"$workspace/sign.log" 2>&1 \
      || fail "cannot sign $host_bin; see $workspace/sign.log"
  fi
fi
python3 -I - "$bind_address" "$advertised" "$quic_port" "$workspace/state" <<'PY' >"$workspace/config.json"
import json, sys
bind, host, port, state = sys.argv[1:]
json.dump(dict(bindAddress=bind, advertisedHost=host, port=int(port), stateDirectory=state), sys.stdout)
PY
host_pid=$(python3 -I "$repository_root/Scripts/real-ssh-process.py" start "$workspace" host \
  "$host_bin" --mach-service "com.chr33s.swiftty.swiftmux.test.$$" --launcher "$bin_dir/swmux-launcher" --roaming-config "$workspace/config.json") \
  || fail "cannot start owned host; see $workspace/host.log"
python3 -I "$repository_root/Scripts/real-ssh-readiness.py" host "$host_pid" \
  "$bin_dir/swifttyd" "$workspace/config.json" >"$workspace/host-readiness.log" 2>&1 \
  || fail "host did not start; see $workspace/host-readiness.log"

password=$(openssl rand -hex 12)
seed=$(openssl rand -hex 32)
cat >"$workspace/pubkey.swift" <<SWIFT
import CryptoKit
import Foundation
let hex = CommandLine.arguments[1]
var seed = [UInt8]()
var i = hex.startIndex
while i < hex.endIndex {
  let j = hex.index(i, offsetBy: 2)
  seed.append(UInt8(hex[i ..< j], radix: 16)!)
  i = j
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
func field(_ b: [UInt8]) -> [UInt8] {
  let n = UInt32(b.count)
  return [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + b
}
let blob = field(Array("ssh-ed25519".utf8)) + field(Array(key.rawRepresentation))
print("ssh-ed25519 " + Data(blob).base64EncodedString())
SWIFT
xcrun swiftc -O "$workspace/pubkey.swift" -o "$workspace/pubkey" 2>"$workspace/pubkey.log" \
  || fail "pubkey helper build failed; see $workspace/pubkey.log"
authorized=$("$workspace/pubkey" "$seed")

# The VM reaches the host through the default network's gateway.
networks=$(container network list --format json)
gateway=$(printf '%s\n' "$networks" | python3 -I "$repository_root/Scripts/real-ssh-config.py" gateway) \
  || fail "container default network has no gateway"
bridge_port=$((51900 + $$ % 90))
echo "$name" >"$workspace/container.name"
container run -d --name "$name" \
  -e RST_PASSWORD="$password" -e RST_AUTHORIZED_KEY="$authorized" \
  -e RST_BRIDGE="$gateway:$bridge_port" swiftty-rst-ssh:test >/dev/null \
  || fail "container run failed"

bridge_pid=$(python3 -I "$repository_root/Scripts/real-ssh-process.py" start "$workspace" bridge \
  python3 -I "$repository_root/Scripts/real-ssh-proxy.py" bridge \
  "$gateway" "$bridge_port" "$workspace/state/control.sock" \
  "$workspace/bridge.ready" "$fixture_id") \
  || fail "cannot start owned bridge; see $workspace/bridge.log"
python3 -I "$repository_root/Scripts/real-ssh-readiness.py" listener "$bridge_pid" \
  "$workspace/bridge.ready" "$fixture_id" >"$workspace/bridge-readiness.log" 2>&1 \
  || fail "bridge did not start; see $workspace/bridge-readiness.log"

address=$(python3 -I "$repository_root/Scripts/real-ssh-readiness.py" container \
  "$host_pid" "$name" 2>"$workspace/container-readiness.log") \
  || fail "container did not start; see $workspace/container-readiness.log"
hostkey=$(container exec "$name" cut -d' ' -f1,2 /tmp/hostkey.pub)
[ -n "$hostkey" ] || fail "container returned no SSH host key"
echo "$hostkey" >"$workspace/hostkey.pub"
key_details=$(ssh-keygen -lf "$workspace/hostkey.pub")
fingerprint=$(printf '%s\n' "$key_details" | awk '{print $2}')
[ -n "$fingerprint" ] || fail "SSH host key has no fingerprint"

relay_pid=$(python3 -I "$repository_root/Scripts/real-ssh-process.py" start "$workspace" relay \
  python3 -I "$repository_root/Scripts/real-ssh-proxy.py" relay \
  "$relay_bind" "$ssh_port" "$name" "$workspace/relay.ready" "$fixture_id") \
  || fail "cannot start owned relay; see $workspace/relay.log"
python3 -I "$repository_root/Scripts/real-ssh-readiness.py" listener "$relay_pid" \
  "$workspace/relay.ready" "$fixture_id" >"$workspace/relay-readiness.log" 2>&1 \
  || fail "relay did not start; see $workspace/relay-readiness.log"
for role in host bridge relay; do
  python3 -I "$repository_root/Scripts/real-ssh-process.py" alive "$workspace" "$role" \
    || fail "fixture process exited during setup"
done
echo "OpenSSH at $address:22 via 127.0.0.1:$ssh_port; bridge $gateway:$bridge_port; swifttyd QUIC $advertised:$quic_port" >&2

python3 -I - "$advertised" "$ssh_port" "$password" "$hostkey" "$fingerprint" \
  "$seed" "$quic_port" "$workspace" "$build_configuration" <<'PY' >"$workspace/env"
import shlex, sys
keys = ["HOST", "PORT", "PASSWORD", "HOSTKEY", "FINGERPRINT", "KEY_HEX", "QUIC_PORT", "ENV_DIR", "CONFIGURATION"]
print("export RST_REAL_SSH_USER=rst")
for key, value in zip(keys, sys.argv[1:]):
    print(f"export RST_REAL_SSH_{key}={shlex.quote(value)}")
PY
chmod 600 "$workspace/env"
rmdir "$workspace/start.lock"
setup_complete=1
trap - EXIT INT TERM
echo "$workspace/env"
