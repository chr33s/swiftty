#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: update-grapheme-tables.sh <ucd-dir>" >&2
    exit 2
fi
case "$1" in
    /*) ucd_directory=$1 ;;
    *) ucd_directory=$PWD/$1 ;;
esac

cd "$(dirname "$0")/.."
temporary=$(mktemp -d .grapheme-tables.XXXXXX)
trap 'rm -rf "$temporary"' EXIT
trap 'exit 1' HUP INT TERM

# Generate both outputs successfully before replacing either tracked file.
swift Scripts/gen-grapheme-tables.swift "$ucd_directory" > "$temporary/properties.swift"
swift Scripts/gen-grapheme-tables.swift "$ucd_directory" --test-data > "$temporary/test-data.swift"
chmod 644 "$temporary/properties.swift" "$temporary/test-data.swift"
mv -f "$temporary/properties.swift" Sources/SwifttyCore/Terminal/GraphemeBreakTables.swift
mv -f "$temporary/test-data.swift" Tests/SwifttyCoreTests/GraphemeBreakTestData.swift
