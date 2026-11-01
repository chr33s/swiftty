#!/bin/sh
# Assembles Swiftty.app with the SwiftMux LaunchAgent, PTY launcher and
# swmux client, then signs it. SMAppService registers the bundled agent
# when the app first enables SwiftMux.
#
# usage: Scripts/package-swiftmux.sh [signing-identity] [output-dir]
#   signing-identity  Developer ID identity, or "-" for ad-hoc (default).
#                     Ad-hoc builds only get the same-user peer check.
#   NOTARY_PROFILE or NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY
#                     notarization credentials (Scripts/notarize.sh); when
#                     set with a Developer ID identity, the app is
#                     notarized, stapled and assessed.
#   SWIFTTY_LINK_DOMAINS  comma-separated Universal Link domains; see below.
#   SWIFTTY_LINK_MODE     "developer" signs applinks:<domain>?mode=developer.
#   SWIFTTY_PROVISIONING_PROFILE  provisioning profile embedded as
#                     Contents/embedded.provisionprofile; macOS honours
#                     the associated-domains entitlement only with one.
#   SWIFTTY_VERSION   CFBundleShortVersionString (default 0.2).
#   SWIFTTY_BUILD     CFBundleVersion (default 1).
set -eu
# Domain records are deliberately word-split below. Their developer-mode
# suffix is literal text, even when the caller has matching filenames.
set -f

identity=${1:--}
out=${2:-.build/package}
label=com.chr33s.swiftty.swiftmux
bundle_id=com.chr33s.swiftty
version=${SWIFTTY_VERSION:-0.2}
build=${SWIFTTY_BUILD:-1}
# Up to three dot-separated integers each, as the bundle keys require.
for number in "$version" "$build"; do
  # Digits and single dots only (no newline can pass), at most two dots.
  case $number in
    '' | *[!0-9.]* | .* | *. | *..* | *.*.*.*)
      echo "package-swiftmux: invalid version or build number: $number" >&2
      exit 64
      ;;
  esac
done

# Attention deep links (spec.inbox.md §4.4): the `swiftty` scheme is
# always registered. SWIFTTY_LINK_DOMAINS (comma-separated hostnames,
# validated by Scripts/link-domains.sh before anything is built) lists
# the domains whose https://<domain>/a/<locator> Universal Links the app
# accepts. When set, the app is signed with
# com.apple.developer.associated-domains (applinks:<domain> each) and
# lists the domains in SwifttyAssociatedDomains; when unset, there is no
# entitlement and the list is empty. Each domain must serve the file from
# Scripts/make-aasa.sh at /.well-known/apple-app-site-association.
domains=$("$(dirname "$0")/link-domains.sh")
applinks=$("$(dirname "$0")/link-domains.sh" --entitlements)

swift build -c release
bin=$(swift build -c release --show-bin-path)

app="$out/Swiftty.app"
rm -rf -- "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$app/Contents/Library/LaunchAgents"

for exe in swiftty swiftmux-agent swmux-launcher swmux swsh; do
  cp "$bin/$exe" "$app/Contents/MacOS/$exe"
done
for bundle in SwifttyCore Swiftty SwifttyJS MuxNavigation; do
  cp -R "$bin/swiftty_$bundle.bundle" "$app/Contents/Resources/"
done

# The app icon, from the asset catalog's macOS images.
icons=Resources/Assets.xcassets/AppIcon.appiconset
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  cp "$icons/mac-${size}x${size}-1x.png" "$iconset/icon_${size}x${size}.png"
  cp "$icons/mac-${size}x${size}-2x.png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf -- "${iconset%/*}"

link_domains=""
for domain in $domains; do
  link_domains="$link_domains<string>$domain</string>"
done

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>Swiftty</string>
  <key>CFBundleExecutable</key><string>swiftty</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$bundle_id.attention</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>swiftty</string></array>
    </dict>
  </array>
  <key>SwifttyAssociatedDomains</key><array>$link_domains</array>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Swiftty makes this Mac discoverable to your iPhone and iPad while Connect a Device is open, so they can find it on your local network.</string>
  <key>NSBonjourServices</key><array><string>_swiftty._tcp</string></array>
</dict>
</plist>
EOF

# Mach-service activation and login startup for configured roaming hosts;
# no KeepAlive or pressured exit.
cat > "$app/Contents/Library/LaunchAgents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>BundleProgram</key><string>Contents/MacOS/swiftmux-agent</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$bundle_id</string></array>
  <key>MachServices</key><dict><key>$label</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnablePressuredExit</key><false/>
  <key>EnableTransactions</key><false/>
</dict>
</plist>
EOF

# Notarization needs a secure timestamp; ad-hoc signatures cannot have one.
if [ "$identity" = "-" ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi

# Sign nested code first, then the app (no --deep).
for exe in swiftmux-agent swmux-launcher swmux swsh; do
  codesign --force --options runtime "$timestamp" --sign "$identity" \
    --identifier "$bundle_id.$exe" "$app/Contents/MacOS/$exe"
done
# Associated domains is the only entitlement, and only when configured.
entitlements=""
if [ -n "$applinks" ]; then
  entitlements="$out/Swiftty.entitlements"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo '  <key>com.apple.developer.associated-domains</key>'
    echo '  <array>'
    for entry in $applinks; do echo "    <string>$entry</string>"; done
    echo '  </array>'
    echo '</dict>'
    echo '</plist>'
  } >"$entitlements"
  plutil -lint "$entitlements" >/dev/null
  if [ -n "${SWIFTTY_PROVISIONING_PROFILE:-}" ]; then
    cp "$SWIFTTY_PROVISIONING_PROFILE" "$app/Contents/embedded.provisionprofile"
  else
    echo "warning: associated domains need SWIFTTY_PROVISIONING_PROFILE (a profile" \
      "with the Associated Domains capability); without one macOS will not" \
      "honour, and may refuse to launch, the signed entitlement" >&2
  fi
fi
codesign --force --options runtime "$timestamp" --sign "$identity" \
  ${entitlements:+--entitlements "$entitlements"} "$app"
codesign --verify --strict --verbose=1 "$app"

if [ -n "${NOTARY_PROFILE:-}${NOTARY_KEY_ID:-}" ] && [ "$identity" != "-" ]; then
  "$(dirname "$0")/notarize.sh" "$app"
fi
echo "$app"
