#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
  echo 'usage: format-swift.sh [format|check]' >&2
  exit 2
fi
case "${1:-format}" in
  format) set -- format --in-place ;;
  check) set -- lint --strict ;;
  *) echo 'usage: format-swift.sh [format|check]' >&2; exit 2 ;;
esac

# Xcode includes swift-format even when its toolchain bin directory is not
# on PATH (as on a fresh CI runner).
formatter=$(command -v swift-format || xcrun --find swift-format)

file_list=$(mktemp "${TMPDIR:-/tmp}/swiftty-format.XXXXXX")
trap 'rm -f "$file_list"' EXIT
trap 'exit 1' HUP INT TERM
# Generated Unicode and Blowfish tables retain their generator's formatting.
# Finish discovery before a formatter can consume a partial file list.
if rg --files -0 Sources Tests Scripts -g '*.swift' \
  -g '!Tables.swift' -g '!KittyDiacritics.swift' -g '!BlowfishTables.swift' -g '!GraphemeBreakTables.swift' -g '!GraphemeBreakTestData.swift' \
  > "$file_list"; then
  :
else
  discovery_status=$?
  # rg reports 1 for no matches; an empty tree still checks Package.swift.
  if [ "$discovery_status" -ne 1 ] || [ -s "$file_list" ]; then
    exit "$discovery_status"
  fi
fi
if [ -s "$file_list" ]; then
  xargs -0 "$formatter" "$@" --configuration .swift-format < "$file_list"
fi
"$formatter" "$@" --configuration .swift-format Package.swift
