#!/usr/bin/env bash
# Compares swiftty's parser+terminal-state throughput with upstream Ghostty's
# `ghostty-bench terminal-stream` on identical input files, using hyperfine.
#
# Usage: Scripts/compare-ghostty.sh <ghostty-src> <corpus-dir>
#   <ghostty-src>  a Ghostty checkout built with
#                  zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
#   <corpus-dir>   *.bin inputs (`swiftty-bench gen <name> > x.bin`,
#                  `ghostty-gen +<name> | head -c 100M > ghostty-x.bin`)
set -euo pipefail
ghostty_src=${1:?ghostty source dir}
corpus=${2:?corpus dir}
cols=${COLS:-120}
rows=${ROWS:-80}
ghostty="$ghostty_src/zig-out/bin/ghostty-bench"
swiftty="$(cd "$(dirname "$0")/.." && pwd)/.build/release/swiftty-bench"
out="${OUT:-$corpus/results}"
mkdir -p "$out"

for data in "$corpus"/*.bin; do
  name=$(basename "$data" .bin)
  hyperfine --warmup 2 --runs "${RUNS:-10}" -N --export-json "$out/$name.json" \
    -n ghostty "$ghostty +terminal-stream --data=$data --terminal-cols=$cols --terminal-rows=$rows" \
    -n swiftty "$swiftty stream --data=$data --terminal-cols=$cols --terminal-rows=$rows" \
    > "$out/$name.txt" 2>&1
  printf '%-22s %s\n' "$name" "$(jq -r '[.results[] | "\(.command)=\(.median*1000|floor)ms"] | join("  ")' "$out/$name.json")"
done
