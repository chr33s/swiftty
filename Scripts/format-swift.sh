#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-format}" in
  format) action="format --in-place" ;;
  check) action="lint --strict" ;;
  *) echo 'usage: format-swift.sh [format|check]' >&2; exit 2 ;;
esac
# Generated Unicode tables retain their generator's formatting.
rg --files -0 Sources Tests Scripts -g '*.swift' \
  -g '!Tables.swift' -g '!GraphemeBreakTables.swift' -g '!GraphemeBreakTestData.swift' \
  | xargs -0 swift-format $action --configuration .swift-format
swift-format $action --configuration .swift-format Package.swift
