#!/bin/bash
# Shape loopback UDP on one port to the spec.roaming.md §13 recovery-target
# profile: 200 ms RTT, 5% independent loss per direction, about 2% reordering
# and 1 Mbit/s per direction. Requires root (dnctl and pfctl).
#
#   sudo Scripts/quic-shaper.sh up [--port N] [--minutes M]
#   sudo Scripts/quic-shaper.sh status
#   sudo Scripts/quic-shaper.sh down
#
# Rules live in the pf anchor com.apple/swiftty-shaper (the stock pf.conf
# evaluates com.apple/* for both filter and dummynet rules) and only match
# UDP to or from the port on lo0, so other traffic is untouched. `up` arms an
# automatic `down` after --minutes (default 60) in case teardown is missed.
# Scripts/test-shaped-quic.sh runs the shaped suite against the same port.
#
# dummynet cannot reorder within a pipe. About 2% of packets in each
# direction go through a parallel pipe with 50 ms more delay, which lets
# later packets overtake them.
set -euo pipefail

anchor="com.apple/swiftty-shaper"
state_dir="/var/run/swiftty-shaper"
port=47431
minutes=60
# Pipe numbers chosen well above those Network Link Conditioner uses.
up_pipe=47101
down_pipe=47102
up_late_pipe=47103
down_late_pipe=47104

command="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    --minutes) minutes="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
}

down() {
  pfctl -a "$anchor" -F all 2>/dev/null || true
  for pipe in "$up_pipe" "$down_pipe" "$up_late_pipe" "$down_late_pipe"; do
    dnctl pipe delete "$pipe" 2>/dev/null || true
  done
  if [ -f "$state_dir/token" ]; then
    pfctl -X "$(cat "$state_dir/token")" 2>/dev/null || true
  fi
  if [ -f "$state_dir/timer" ]; then
    kill "$(cat "$state_dir/timer")" 2>/dev/null || true
  fi
  rm -rf "$state_dir"
}

case "$command" in
  up)
    require_root
    down
    mkdir -p "$state_dir"
    # Each direction: 100 ms one-way delay, 5% loss, 1 Mbit/s.
    dnctl pipe "$up_pipe" config bw 1Mbit/s delay 100 plr 0.05
    dnctl pipe "$down_pipe" config bw 1Mbit/s delay 100 plr 0.05
    dnctl pipe "$up_late_pipe" config bw 1Mbit/s delay 150 plr 0.05
    dnctl pipe "$down_late_pipe" config bw 1Mbit/s delay 150 plr 0.05
    pfctl -a "$anchor" -f - <<RULES
dummynet out quick on lo0 proto udp from any to any port $port probability 2% pipe $up_late_pipe
dummynet out quick on lo0 proto udp from any port $port to any probability 2% pipe $down_late_pipe
dummynet out quick on lo0 proto udp from any to any port $port pipe $up_pipe
dummynet out quick on lo0 proto udp from any port $port to any pipe $down_pipe
RULES
    # Enable pf with a reference token so `down` releases only this hold.
    pfctl -E 2>&1 | sed -n 's/^Token : //p' > "$state_dir/token"
    echo "$port" > "$state_dir/port"
    nohup bash -c "sleep $((minutes * 60)); '$0' down" >/dev/null 2>&1 &
    echo $! > "$state_dir/timer"
    echo "shaping lo0 udp port $port for up to $minutes minutes"
    ;;
  down)
    require_root
    down
    echo "shaping removed"
    ;;
  status)
    require_root
    if [ -f "$state_dir/port" ]; then
      echo "shaping lo0 udp port $(cat "$state_dir/port")"
      pfctl -a "$anchor" -s dummynet 2>/dev/null || true
      dnctl list 2>/dev/null | grep -E "^0?(${up_pipe}|${down_pipe}|${up_late_pipe}|${down_late_pipe}):" -A1 || true
    else
      echo "not shaping"
      exit 1
    fi
    ;;
  *)
    echo "usage: sudo $0 up [--port N] [--minutes M] | status | down" >&2
    exit 2
    ;;
esac
