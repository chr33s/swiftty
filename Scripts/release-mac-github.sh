#!/bin/sh
# Notarizes, staples and publishes a Developer ID-signed macOS app
# (Swiftty.app from Scripts/package-swiftmux.sh) as a GitHub release asset
# (zip plus SHA-256). .github/workflows/release.yml runs it; it also
# runs locally.
#
# usage: Scripts/release-mac-github.sh <path/to/App.app>
#
# Environment:
#   GITHUB_TOKEN       token with contents:write on the repository.
#   GITHUB_REPOSITORY  owner/name; default parsed from the origin remote.
#   NOTARY_*           notarization credentials, see Scripts/notarize.sh;
#                      not needed when the app is already stapled.
#   Release naming:
#     RELEASE_TAG      release this existing tag as-is; otherwise a
#                      prerelease tagged mac-v<version>-<build> is
#                      created at RELEASE_COMMIT (default HEAD). A release
#                      this script creates stays a draft until its assets
#                      are uploaded. An existing release for the tag, draft
#                      or published, receives the assets and keeps its
#                      state, except a draft left by an earlier failed run.
set -eu

app=${1:?usage: Scripts/release-mac-github.sh <App.app>}
[ -d "$app" ] || { echo "release-mac-github: no app at $app" >&2; exit 66; }
: "${GITHUB_TOKEN:?release-mac-github: GITHUB_TOKEN is required}"

repository_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/swiftty-release.XXXXXX")
# The work directory holds the token header: remove it on signals too.
trap 'rm -rf -- "$work"' EXIT
trap 'exit 1' HUP INT TERM

info="$app/Contents/Info.plist"
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")

repository=${GITHUB_REPOSITORY:-$(git -C "$repository_root" remote get-url origin |
  sed -E 's#^(git@github\.com:|https://([^@/]*@)?github\.com/)##; s#\.git$##')}
case "$repository" in
  */*) ;;
  *) echo "release-mac-github: set GITHUB_REPOSITORY=owner/name" >&2; exit 64 ;;
esac

if [ -n "${RELEASE_TAG:-}" ]; then
  tag=$RELEASE_TAG
  prerelease=false
else
  tag="mac-v$version-$build"
  prerelease=true
fi
commit=${RELEASE_COMMIT:-$(git -C "$repository_root" rev-parse HEAD)}
title="$name $version ($build)"
notes=$(printf '%s\n\n%s' \
  "Developer ID-signed, notarized macOS build of $title from $commit." \
  "Unzip and move the app to /Applications.")

# The app must be Developer ID-signed under the hardened runtime.
codesign --verify --strict --deep --verbose=1 "$app"
codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application' || {
  echo "release-mac-github: $app is not signed with a Developer ID identity" >&2
  exit 65
}

# Notarize and staple (or check an existing staple), then assess ---------
"$repository_root/Scripts/notarize.sh" "$app"

# Package ----------------------------------------------------------------
# Asset names keep to characters GitHub stores, and URLs carry, as-is.
asset=$(printf '%s' "$name-$version-$build-macOS.zip" | tr -c 'A-Za-z0-9._-' '-')
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$asset"
(cd "$work" && shasum -a 256 "$asset" >"$asset.sha256")

# Publish ----------------------------------------------------------------
headers="$work/headers"
(umask 077 && printf '%s\n' \
  "Authorization: Bearer $GITHUB_TOKEN" \
  "Accept: application/vnd.github+json" \
  "X-GitHub-Api-Version: 2022-11-28" >"$headers")
api="https://api.github.com/repos/$repository"

# github <method> <url> [curl args...]: the response body on stdout; fails
# on HTTP errors.
github() {
  method=$1
  url=$2
  shift 2
  curl --silent --show-error --fail-with-body --location \
    --header @"$headers" --request "$method" "$@" "$url"
}

json_field() {
  /usr/bin/python3 -I -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# The release for the tag, if any. /releases/tags/{tag} never returns
# drafts, so search the listing (newest first), which includes them; any
# HTTP error or malformed page stops the script instead of creating a
# duplicate.
release=""
page=1
while [ -z "$release" ]; do
  listing=$(github GET "$api/releases?per_page=100&page=$page")
  release=$(printf '%s' "$listing" | /usr/bin/python3 -I -c '
import json, sys
releases = json.load(sys.stdin)
match = next((r for r in releases if r["tag_name"] == sys.argv[1]), None)
print(json.dumps(match) if match else "" if releases else "none")
' "$tag")
  page=$((page + 1))
done

if [ "$release" != none ]; then
  publish=$(printf '%s' "$release" | /usr/bin/python3 -I -c '
import json, sys
release = json.load(sys.stdin)
print("true" if release.get("draft") is True and release.get("body") == sys.argv[1] else "false")
' "$notes")
  echo "release-mac-github: updating release $tag"
else
  body=$(/usr/bin/python3 -I - "$tag" "$commit" "$title" "$notes" "$prerelease" <<'PY'
import json, sys
tag, commit, title, notes, prerelease = sys.argv[1:]
print(json.dumps({
    "tag_name": tag,
    "target_commitish": commit,
    "name": title,
    "body": notes,
    "draft": True,
    "prerelease": prerelease == "true",
}))
PY
  )
  release=$(github POST "$api/releases" --header 'Content-Type: application/json' --data "$body")
  publish=true
  echo "release-mac-github: created draft release $tag"
fi
release_id=$(printf '%s' "$release" | json_field id)

# Upload under temporary names, then swap each in: an existing asset is
# replaced only once its successor is uploaded.
existing=$(github GET "$api/releases/$release_id/assets?per_page=100")
asset_id() {
  printf '%s' "$existing" | /usr/bin/python3 -I -c '
import json, sys
print(next((a["id"] for a in json.load(sys.stdin) if a["name"] == sys.argv[1]), ""))
' "$1"
}
# upload <file> <content type>: the uploaded asset's id.
upload() {
  stale=$(asset_id "$1.partial")
  [ -z "$stale" ] || github DELETE "$api/releases/assets/$stale" >/dev/null
  github POST "https://uploads.github.com/repos/$repository/releases/$release_id/assets?name=$1.partial" \
    --header "Content-Type: $2" --data-binary @"$work/$1" | json_field id
}
# swap <file> <uploaded id>
swap() {
  previous=$(asset_id "$1")
  [ -z "$previous" ] || github DELETE "$api/releases/assets/$previous" >/dev/null
  github PATCH "$api/releases/assets/$2" --header 'Content-Type: application/json' \
    --data "{\"name\": \"$1\"}" >/dev/null
  echo "release-mac-github: uploaded $1"
}
archive_id=$(upload "$asset" application/zip)
checksum_id=$(upload "$asset.sha256" text/plain)
swap "$asset" "$archive_id"
swap "$asset.sha256" "$checksum_id"

if [ "$publish" = true ]; then
  release=$(github PATCH "$api/releases/$release_id" \
    --header 'Content-Type: application/json' --data '{"draft": false}')
  echo "release-mac-github: published release $tag"
fi
printf '%s' "$release" | json_field html_url
