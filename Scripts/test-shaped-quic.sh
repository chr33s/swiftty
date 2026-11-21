#!/bin/bash
# Run ShapedQUICTests (A20, A22, the screenDeltas cost report and the
# recovery-target measurement over real loopback QUIC) under the
# spec.roaming.md §13 recovery-target profile. Shape the port first:
#
#   sudo Scripts/quic-shaper.sh up
#   Scripts/test-shaped-quic.sh [--port N] [extra test-native.sh arguments]
#   sudo Scripts/quic-shaper.sh down
#
# Builds release, as the in-process cost report does. The suite refuses to
# run if the port is not shaped (it measures the RTT first).
set -euo pipefail
repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"

port=47431
arguments=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    *) arguments+=("$1"); shift ;;
  esac
done

export SWIFTTY_SHAPED_QUIC=1
export SWIFTTY_SHAPED_QUIC_PORT="$port"
exec Scripts/test-native.sh -c release --filter 'ShapedQUICTests' \
  ${arguments[@]+"${arguments[@]}"}
