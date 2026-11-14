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
properties=Sources/SwifttyEngine/Terminal/GraphemeBreakTables.swift
test_data=Tests/SwifttyEngineTests/GraphemeBreakTestData.swift
temporary=$(mktemp -d .grapheme-tables.XXXXXX)
publication_started=0
committed=0

save_previous() {
    # mv treats a directory or its symlink as a container, not a file path.
    if [ -d "$1" ]; then
        echo "cannot replace non-file destination: $1" >&2
        return 1
    fi
    if [ -L "$1" ] || [ -f "$1" ]; then
        cp -pP "$1" "$2"
    elif [ -e "$1" ]; then
        echo "cannot replace non-file destination: $1" >&2
        return 1
    fi
}

restore_previous() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        mv -f "$2" "$1"
    else
        rm -f "$1"
    fi
}

cleanup() {
    cleanup_status=$?
    trap - EXIT
    # Repeated handled signals must not interrupt restoration itself.
    trap '' HUP INT TERM
    recovery_failed=0
    if [ "$publication_started" -eq 1 ] && [ "$committed" -eq 0 ]; then
        if ! restore_previous "$properties" "$temporary/properties.previous"; then
            recovery_failed=1
        fi
        if ! restore_previous "$test_data" "$temporary/test-data.previous"; then
            recovery_failed=1
        fi
    fi
    if [ "$recovery_failed" -eq 1 ]; then
        echo "grapheme table recovery failed; saved files retained in $PWD/$temporary" >&2
        cleanup_status=1
    elif ! rm -rf "$temporary"; then
        cleanup_status=1
    fi
    exit "$cleanup_status"
}

trap cleanup EXIT
trap 'trap "" HUP INT TERM; exit 1' HUP INT TERM

# Generate both outputs successfully before replacing either tracked file.
swift Scripts/gen-grapheme-tables.swift "$ucd_directory" > "$temporary/properties.swift"
swift Scripts/gen-grapheme-tables.swift "$ucd_directory" --test-data > "$temporary/test-data.swift"
chmod 644 "$temporary/properties.swift" "$temporary/test-data.swift"

# Save both former paths (including symlinks or absence) before any mutation.
save_previous "$properties" "$temporary/properties.previous"
save_previous "$test_data" "$temporary/test-data.previous"
# Set this before mv: failure or a handled signal can follow a completed rename.
publication_started=1
mv -f "$temporary/properties.swift" "$properties"
mv -f "$temporary/test-data.swift" "$test_data"
committed=1
