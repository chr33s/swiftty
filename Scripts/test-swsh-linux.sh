#!/bin/sh
# Builds swsh in the official Swift Linux image and runs a command there.
# Usage: [SWSH_LINUX_PLATFORM=linux/amd64] Scripts/test-swsh-linux.sh [command...]
# Default command: the unit tests, then the acceptance suite. Tracked and
# unignored files are copied into a Docker volume, so the working tree is never
# written from the container.
set -eu
cd "$(dirname "$0")/.."
image=${SWSH_LINUX_IMAGE:-swift:6.4}
# For example linux/amd64, the architecture of GitHub's hosted runners.
platform=${SWSH_LINUX_PLATFORM:-}
suffix=$(printf %s "$platform" | tr -c 'a-z0-9' '-')
command=${*:-swift test --scratch-path /build && python3 Scripts/test-swsh.py /build/debug/swsh}
# Unpacked by the native image: tar in an emulated one can lack system calls.
git ls-files -co --exclude-standard -z |
  python3 -c 'import os, sys
names = sys.stdin.buffer.read().split(b"\0")
sys.stdout.buffer.write(b"\0".join(name for name in names if name and os.path.lexists(name)))' |
  COPYFILE_DISABLE=1 tar -c --no-xattrs --null -T - |
  docker run --rm -i -v "swsh-linux-src$suffix:/src" "$image" sh -c \
    'find /src -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -x -C /src'
docker run --rm ${platform:+--platform "$platform"} \
  -v "swsh-linux-src$suffix:/src" -v "swsh-linux-build$suffix:/build" \
  -w /src "$image" sh -c "
    { command -v python3 >/dev/null && command -v zsh >/dev/null ||
      { apt-get update -qq && apt-get install -y -qq python3 zsh procps; } >/dev/null 2>&1; } &&
    swift build --product swsh --scratch-path /build 2>&1 | tail -3 &&
    $command"
