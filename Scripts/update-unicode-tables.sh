#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    echo "usage: update-unicode-tables.sh [EastAsianWidth.txt]" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    case "$1" in
        /*) ;;
        *) set -- "$PWD/$1" ;;
    esac
fi

cd "$(dirname "$0")/.."
destination=Sources/SwifttyCore/Unicode/Tables.swift
temporary=$(mktemp "$destination.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT
trap 'exit 1' HUP INT TERM

swift Scripts/gen-unicode-tables.swift "$@" > "$temporary"
chmod 644 "$temporary"
mv -f "$temporary" "$destination"
