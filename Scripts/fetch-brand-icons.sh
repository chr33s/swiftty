#!/bin/sh
# Refreshes Sources/Swiftty/BrandIcons from xandemon/developer-icons (MIT)
# at a pinned commit. The app draws each SVG by its alpha only (a template
# image), so only logos whose silhouette reads at 12pt are listed; the rest
# keep an SF Symbol (MuxIcons in Sources/ProgramIcons). iOS cannot load an
# SVG file at run time, so each logo is also copied into an image set in
# Resources/Assets.xcassets/Brand Icons (the iPhone and iPad terminal header).
set -eu
rev=94559559231f54780bc6f1fbd0306ef595cdeff1
names="apple-dark aws bunjs c c-plus-plus claude-ai cloudflare cursor-dark deepseek
docker esbuild flyio gemini git github-copilot github-dark gitlab go
google-cloud homebrew hugging-face java kotlin kubernetes lua mysql neovim
nodejs npm openai php playwright pnpm-dark postgresql python pytorch ruby
rust-dark swift tensorflow typescript vitejs vitest"
# Logos whose silhouette is a plain shape (a square, a hexagon): drawn in
# their own colors instead (MuxIcon.colored).
colored="bunjs c c-plus-plus esbuild flyio gemini hugging-face kubernetes npm
php ruby swift typescript"
cd "$(dirname "$0")/../Sources/Swiftty/BrandIcons"
base="https://raw.githubusercontent.com/xandemon/developer-icons/$rev"
for name in $names; do
  curl -fsSL "$base/icons/$name.svg" -o "$name.svg"
done
curl -fsSL "$base/LICENSE" -o LICENSE

catalog="../../../Resources/Assets.xcassets/Brand Icons"
rm -rf "$catalog"
mkdir -p "$catalog"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' \
  >"$catalog/Contents.json"
for name in $names; do
  set="$catalog/brand-$name.imageset"
  mkdir -p "$set"
  cp "$name.svg" "$set/$name.svg"
  intent=template
  case " $(echo $colored) " in *" $name "*) intent=original ;; esac
  cat >"$set/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "$intent"
  }
}
JSON
done
