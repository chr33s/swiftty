#!/bin/sh
# Restarts the SwiftMux gateway (durable sessions, spec.durability.md §5).
# The guardian owns every shell and PTY, so running sessions survive; native
# and roaming clients reconnect to them. The guardian itself is restarted
# only by `mise run restart-guardian`, which ends every session.
#
# usage: Scripts/restart-swiftmux.sh
set -eu
domain="gui/$(id -u)"
gateway=com.chr33s.swiftty.swiftmux-gateway

if ! launchctl print "$domain/$gateway" >/dev/null 2>&1; then
  echo "restart-swiftmux: durable sessions are not installed; run Scripts/install.sh" >&2
  exit 1
fi
launchctl kickstart -k "$domain/$gateway"
echo "restarted $gateway; sessions keep running"
