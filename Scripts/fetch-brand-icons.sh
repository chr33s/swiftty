#!/bin/sh
# Refreshes Sources/Swiftty/BrandIcons from xandemon/developer-icons (MIT)
# at a pinned commit. The app draws each SVG by its alpha only (a template
# image), so only logos whose silhouette reads at 12pt are listed; the rest
# keep an SF Symbol (MuxIcons in Sources/Swiftty/MuxChrome.swift).
set -eu
rev=94559559231f54780bc6f1fbd0306ef595cdeff1
names="aws claude-ai cursor-dark docker git github-copilot go homebrew mysql
neovim nodejs openai python rust-dark"
cd "$(dirname "$0")/../Sources/Swiftty/BrandIcons"
base="https://raw.githubusercontent.com/xandemon/developer-icons/$rev"
for name in $names; do
  curl -fsSL "$base/icons/$name.svg" -o "$name.svg"
done
curl -fsSL "$base/LICENSE" -o LICENSE
