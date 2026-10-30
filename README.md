# swiftty

Swift 6.4 terminal core and frontends for macOS (AppKit) and iOS/iPadOS
(UIKit). `SwifttyCore` and `SwifttyMobile` also build for Mac Catalyst,
visionOS and tvOS. [spec.md](spec.md) defines scope, protocols and acceptance requirements.
[Shell](https://github.com/chr33s/shell) embeds the core through its libghostty API.

## Build and test

Requires Xcode 27 and the tools pinned in `mise.toml`:

```sh
mise install
mise run build      # debug build; `mise run release` for release
mise run test-native # full unit suite and real PTY sessions: sh, vim, less, tmux, top
mise run app        # launch the macOS terminal
mise run bench      # Release microbenchmarks
mise run lint
mise run format
mise run format-check
mise run test-internal
mise run bench-storage
mise run compare <ghostty-src> <corpus-dir>
mise run package-swiftmux [identity]   # Swiftty.app with the SwiftMux agent
mise run install [--roaming]           # see SwiftMux below
mise run uninstall [--purge] [-y]
```

The native host runs tests serially because suites share AppKit state and use
blocking dispatch handoffs. Each manifest test bundle must exist and report a
complete run. A missing or failing bundle fails the command; later bundles still
run so their diagnostics are available. Completion is audited separately for
each bundle. Allocation budgets run only with optimized code;
`Scripts/test-native.sh -c release` checks them alongside the rest of the suite.

Use Xcode's Swift 6.4 toolchain, as CI does; `mise.toml` pins the other
tools but not Swift, because swift.org toolchains bundle a Swift Testing runtime
that conflicts with Xcode 27.2's and stops `Scripts/test-native.sh` from
finding tests. Build the UIKit frontend
with Xcode; the package's AppKit executable scheme is macOS-only:

```sh
xcodebuild -scheme SwifttyMobile -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme SwifttyMobile -configuration Release -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
```

Hosted mobile tests need XcodeGen and Python 3:

```sh
Scripts/test-ios-simulator.sh <simulator-udid>
Scripts/test-ipad-frame-time.sh <device-udid> <development-team>
```

Both scripts retain results in a temporary workspace and print its path. Physical
tests use existing signing profiles. Simulator GPU timings are indicative only.
Recorded `sh`, `vim`, `less`, `tmux` and `top` sessions live in
`Tests/SwifttyMobileTests/Fixtures`; regenerate with
`SWIFTTY_RECORD=1 swift test --filter SessionRecorder`.

## Embedding

On macOS, `TerminalSession.start(_:)` can launch a PTY child. External
transports feed program output through `receive(_:)`, send encoded input from
`onWrite`, and forward resize events to the remote program. Connection setup,
authentication and reconnection belong to the embedding app.

`TerminalUIView(session:configuration:fontSize:)` hosts a session. An iOS app
target can use `SwifttyMobileAppDelegate` and `SwifttyMobileSceneDelegate` for
the reference demo. `SwifttyMobile` includes no app project or network
client; the roaming SSH clients under `Apps/` provide both (see Roaming SSH).
visionOS omits accessory views, input clicks, haptics and screen-coordinate
keyboard avoidance. tvOS additionally omits the clipboard, edit menus,
pointer, hover, pinch, long-press and pan gestures: the focus engine can focus
the view, the select button makes it first responder, and hardware or system
keyboards provide input.

### Remote presentation and surface capabilities

`TerminalSession(presentationColumns:rows:configuration:)` creates a session
that displays frames produced by another, authoritative terminal (for example
a roaming host). It never parses program output or encodes input:
`installPresentation(_:)` validates a `PresentationFrame` and replaces the whole
screen atomically, keeping the frame's cell widths, graphemes and wraps without
reflow, and marks it fully damaged. `send` forwards committed text, key presses
and pastes to `semanticInputHandler` (never `onWrite`), `resize` proposes the
view's grid to `gridProposalHandler`, and its own history is disabled:
`scrollViewport(by:)` goes to `viewportScrollHandler`, which a roaming client
turns into an RST/1 `Viewport` request so the host presents that client's own
history window (hosts advertising `historyViewport`). Local selection and copy
work on the displayed frame.

Both frontends expose a settable `capabilities: SurfaceCapabilities` (default
`.full`; set `.roaming` for remote presentation). Program-initiated clipboard writes (OSC
52) reach the pasteboard only with `remoteClipboardWrites`. Without the
matching capability, link opening, search, scrollback, mouse reporting, paste,
copy and text input are hidden or disabled rather than shown as nonfunctional
controls; presentation sessions also disable local resets and raw-byte
bindings. On UIKit, `hidesContentWhenInactive` covers the terminal while its
scene is inactive or in the background, so app-switcher snapshots omit it.
Shell input disables autocorrection, capitalization, spell checking, smart
quotes, dashes and insert/delete, and inline prediction.

OSC 7501 is opt-in through `SessionConfiguration.programStatusEnabled` or
`setProgramStatusEnabled(_:)`. Read `programStatusSnapshot`, subscribe through
`onProgramStatusChange`, and route `onTerminalReply` to the originating transport.
External transports call `programExited()` when the program or connection ends.
The [program-status contract](spec.md#osc-7501-program-status) specifies validation,
lifecycle and reply provenance.

## SwiftMux

[spec.multiplexer.md](spec.multiplexer.md) describes a persistent session
service for Swiftty. A per-user LaunchAgent (`swiftmux-agent`) owns the shells,
PTYs, terminal engines, history and workspace layouts. Frontends connect to it
over one Mach/XPC endpoint using `SMX/2`: tagged JSON records that carry full,
validated pane frames.

- `swmux` is the terminal client. With no command it attaches to the newest
  workspace or creates one. Commands: `new [-s NAME] [-c DIR] [-d] [-- CMD]`,
  `attach [-t NAME]`, `list` (`ls`), `detach`, `end -t NAME`, `end-all`,
  `status` and `agent install|uninstall|status`. Attaching runs only inside
  Swiftty (`TERM_PROGRAM=swiftty`, or pass `--allow-host`). The prefix is
  `C-b`; press `C-b ?` for the bindings. Settings live in
  `$XDG_CONFIG_HOME/swmux/settings.json` (default `~/.config/swmux`):
  `prefix`, `escapeDelayMilliseconds` and `remainOnExit`.
- The service links only `SwifttyEngine`: the parser, terminal state, history,
  input encoding and PTY code, with no Metal, fonts or AppKit. `SwifttyCore`
  re-exports the engine and adds the renderer, fonts and sessions.
- Every Swiftty app window is a SwiftMux workspace: a plain shell is a
  workspace with one tab and one pane, and adding tabs or splits grows the
  same workspace without restarting its shell. One-tab windows show a title
  instead of the tab strip. Panes render service frames directly through
  Metal. AppKit draws the tab strip (icons, titles, activity dots,
  double-click to rename), pane headers and draggable, VoiceOver-adjustable
  dividers. Shortcuts: ⌘N new workspace (in its own window), ⌘T new tab,
  ⇧⌘O open an existing workspace, ⌘W close the window (detaches),
  ⇧⌘] / ⇧⌘[ next/previous tab, ⌘D / ⇧⌘D split, ⌥⌘arrows focus,
  ⌃⌘arrows resize, ⇧⌘↩ zoom, ⌥⌘W end pane, ⌃⌘W end tab. The Workspace menu also
  renames tabs and workspaces and ends a workspace; swiftty › Terminal
  Service stages and installs app updates without replacing the bundle under
  a live service. Only the End commands terminate processes, and ending a
  running pane, tab or workspace asks first. Opening a workspace already
  shown reveals its window; one controlled elsewhere is taken over only
  after confirmation. At launch the last workspace reopens when free;
  otherwise existing workspaces are offered before a new one is created.
  New workspaces follow `command` and `working-directory` (`inherit` means
  the app's own directory); new tabs reuse the workspace's command, and
  splits start a login shell in the split pane's directory. Find (⌘F, ⌘G,
  ⇧⌘G) searches the service-side history, key bindings and font zoom apply
  to panes, and app theme changes update the colours panes report to
  programs. Panes match the direct terminal: mouse reporting to programs
  (Shift still selects), the alternate-screen wheel, `copy-on-select`,
  ⌘-click and ⌘-hover links (`link-url`), `cursor-click-to-move`,
  `mouse-hide-while-typing`, `custom-shader`, prompt jumps, Select Command
  Output, Clear Screen and Reset Terminal. The service performs the ones
  that need the emulator; a service started by an older build lacks them,
  so their menu items are disabled until it is updated. Quitting the app
  detaches every window; the shells keep running. If the helper needs
  approval or is unavailable, the app says so and offers a retry; it never
  starts a non-persistent shell instead.
- Panes start through `swmux-launcher`, which calls `login_tty` and then execs
  the shell. They run with `TERM=swmux-256color`; the agent compiles that
  terminfo entry into `~/Library/Application Support/SwiftMux/terminfo`.

```sh
swift build
.build/debug/swmux agent install   # development LaunchAgent for this build
.build/debug/swmux new -s work     # inside Swiftty
Scripts/package-swiftmux.sh [identity]   # Swiftty.app with the bundled agent (SMAppService)
Scripts/install.sh [--roaming]           # package, install to /Applications, register the agent (+ swifttyd)
Scripts/install-ios.sh --team TEAM      # iOS/iPadOS app on iPhones and iPads connected by USB
Scripts/uninstall.sh [--purge]           # remove the app, agent and swifttyd
```

`install.sh` signs with the first Developer ID Application identity (else
ad-hoc), and re-registers the agent when its signing team changes, or for an
ad-hoc build when its agent binary changes: launchd otherwise refuses to start
it (a launch-constraint violation). It then installs the iOS/iPadOS app
(`MobileClient`) on every paired iPhone and iPad connected by USB, signed
automatically for the Mac build's team or `--team`; `--no-devices` skips this.
Devices must be unlocked and in Developer Mode. The bundled
agent can also be managed directly with
`Swiftty.app/Contents/MacOS/swiftty --swiftmux-agent register|unregister|status`.

Installation uses Python 3 to copy the new app into a private sibling directory,
check its bundle/executables and verify its signature and expected signing team
before publication. An
atomic exchange replaces an existing app; a first install refuses a concurrently
created destination. Copy, validation or publication failures keep the previous
app in place. Filesystems that refuse the atomic operation stop installation.
Registration and optional roaming setup run after publication; they are separate
steps. Interrupted copy/verification workers are killed and collected, and
temporary-directory cleanup failures report the retained directory.
Before replacement, the installer checks the destination bundle's running
application through `swiftty --running-app APP_PATH`. A running copy there is
left alone; otherwise the installer opens the selected installation as a new
instance, even when another copy with the same name or bundle identifier is
running elsewhere.

`uninstall.sh` requires Python 3 to limit each shutdown command to ten seconds.
Failed or timed-out shutdown checks preserve installation files and state.
Repeated signals cannot replace an interruption result or abandon command
collection. Captured command output is limited to 64 KiB and is published only
after the command exits within its budget.

Acceptance evidence and measurements (`mise run bench-swiftmux`) are recorded
in section 11 of [spec.multiplexer.md](spec.multiplexer.md).

The service enforces the limits in `MuxLimits`: 32 panes, a 256 KiB input
buffer per pane, 16 MiB frames, 1 MiB pastes and a bounded history per pane.

### Deep links

Attention items (OSC 7501) can be opened from a link, as described in section 4
of `spec.inbox.md`:

```text
swiftty://attention/open?ref=<locator>
https://<configured domain>/a/<locator>
```

- `MuxNavigation` holds the typed `AttentionDestination`: the recipient's host
  profile ID, service epoch, workspace, tab, pane, terminal epoch, record path
  and incarnation, occurrence and intent (`review`, `result` or `reveal`). It
  also has the locator codec, link validation and `AttentionNavigator`, a
  state machine for the navigation steps. It needs only Foundation and builds
  for every platform, watchOS included. `MuxNavigationSMX` adapts the navigator
  to a local SwiftMux connection.
- The locator is a versioned binary record of IDs, encoded as base64url. It
  holds no endpoints, hostnames, usernames, credentials, message text or
  commands. **It is not an authentication credential.** The app resolves a
  link only against hosts the recipient has configured. If the host is
  unknown, the app asks the user to pick one. It never connects to anything
  named in the link.
- The app checks a link before it contacts anything. The scheme or configured
  domain must match, the link must be at most 2 KiB, the path must match, and
  the URL must have exactly one `ref` and no other parameters. The locator must
  decode strictly. The app then checks the service epoch and the exact
  occurrence before it shows any metadata. If the item is stale, superseded,
  missing or from before a service restart, the app says so and never shows a
  different request in its place. "Open in pane" attaches without taking over.
  If another client holds the workspace, the app asks for an explicit takeover
  tied to the lease generation the user saw. The app marks only the linked
  occurrence seen.
- On macOS, Swiftty handles the `swiftty` scheme (`CFBundleURLTypes`, written
  by `Scripts/package-swiftmux.sh`). It reveals the window that holds the
  linked workspace, or opens one (other workspaces' windows stay attached),
  and focuses the pane. Prompts appear as alerts.
- The roaming clients (iOS/iPadOS, Catalyst, visionOS, tvOS and the Mac
  client) register the scheme through `Apps/Config/AttentionLinks.plist`. They
  route `onOpenURL`, web-browsing activities and attention Handoff into a
  destination sheet. Attention travels over the SSH bootstrap channel
  (no-PTY `swifttyd bootstrap` requests, spec.inbox.md §3.6), not RST/1. The
  apps show one Inbox across every configured Mac; opening an item resumes
  the roaming attachment and asks before taking over a held workspace. There
  is no push delivery.
- Universal Links are off unless `SWIFTTY_LINK_DOMAINS` is set. It is a
  comma-separated list of hostnames, validated by `Scripts/link-domains.sh`
  (an invalid name fails the build). When it is unset, no target gets the
  associated-domains entitlement and only `swiftty://` links work.
  `links.example.invalid` is a placeholder only.

  ```sh
  # 1. The association file each domain serves, with no redirects, as
  #    application/json at /.well-known/apple-app-site-association.
  #    It claims only /a/<locator> (one component, no query or fragment).
  Scripts/make-aasa.sh -o apple-app-site-association TEAMID1234 \
    com.chr33s.swiftty dev.chr33s.swiftty
  Scripts/make-aasa.sh --check apple-app-site-association   # re-validate rule order

  # 2. Native macOS app: Info.plist SwifttyAssociatedDomains plus the
  #    signed com.apple.developer.associated-domains entitlement.
  SWIFTTY_LINK_DOMAINS=links.example.com \
    SWIFTTY_PROVISIONING_PROFILE=Swiftty.provisionprofile \
    Scripts/package-swiftmux.sh "Developer ID Application: …"

  # 3. Roaming clients: XcodeGen's preGenCommand (Scripts/configure-links.sh)
  #    writes Apps/Config/Generated/ with the domain list and per-target
  #    entitlements for MobileClient, CatalystClient and
  #    VisionClient. tvOS stays swiftty:// only.
  SWIFTTY_LINK_DOMAINS=links.example.com Scripts/build-platforms.sh
  ```

  `SWIFTTY_LINK_MODE=developer` signs `applinks:<domain>?mode=developer` so
  development builds fetch the association file directly instead of through
  Apple's CDN. Both generators preserve that literal suffix regardless of
  filenames in the working directory. Association-file validation requires
  the path, query and fragment exclusions before the inclusion rule and
  rejects matching defaults or conditions that change those rules.
  The macOS entitlement is honoured only with a provisioning
  profile that has the Associated Domains capability; without
  `SWIFTTY_PROVISIONING_PROFILE` the script warns.
- The watch shows redacted `AttentionSummary` values: category, app name,
  counts and time. Message text is hidden by default. The watch can offer a
  Handoff (`AttentionHandoffRequest`) to a paired device, but it never takes a
  lease or sends input.
  Companion contexts and replies use wire version 3, so both paired apps
  must support it. Versions 1 and 2 are rejected. The phone persists
  publisher identity and publication sequence; status, attention and preview
  remain in memory. Publication order is separate from the original observation
  timestamps. Preview text is bound to an opaque selection id that changes
  when the selected session changes. That id is not a host or session token.
  The watch drops cached preview text when the id changes, when preview is
  disabled, or when a status reply says no preview can be served. A NaN or
  infinite refresh timeout uses the finite 15-second default.

### Attention inbox

Every SwiftMux pane parses OSC 7501 program status (protocol revision 0.3),
whether or not it is shown, attached or leased. The service reduces each change
in stream order, then sends coalesced updates
([spec.inbox.md](spec.inbox.md) §3):

- `MuxAttention` is a pure reducer with three separate models: the current
  status of each record, **Needs you** occurrences (one per stretch of
  `blocked`), and the latest unreviewed failure and result of each source. A
  source is identified by service epoch, pane, terminal epoch (new after RIS),
  record path and record incarnation, never by program name or text. A fast
  `blocked → working → blocked` sequence produces two occurrences. `done →
  working` keeps the result. Prompts, process exit and `clear` resolve
  requests; silence never does.
- The SMX commands `subscribeInbox`, `inbox` (100 rows per page, opaque
  cursor), `locateAttention`, `markSeen`, `snooze` and `markReviewed` need no
  lease. They never resize panes and must match the occurrence exactly.
  Opening an item marks it seen but does not resolve it. Only failures and
  results can be reviewed. `locateAttention` reports whether another frontend
  holds the workspace lease.
- Limits: 64 records per pane, 16 MiB of decoded status text (resolved history
  is evicted first, then the oldest results), 256 resolved items kept for
  stale links, and 16 subscribers. A subscriber can have at most 64
  unacknowledged updates; if it falls further behind, it gets a single
  `resync` update instead.
- The native window's toolbar shows the Needs-you count. Its popover lists
  requests, failures and results as sanitized plain text. **Open in Pane**
  reveals the pane, and opening a workspace controlled elsewhere asks before
  taking over. **Snooze** (15 minutes, 1 hour or tomorrow at 9:00) hides a
  waiting request from the count until then, and **Unsnooze** brings it back.
  **Mark Reviewed** dismisses failures and results. **Load More** reads past
  the first 100 rows. A failed command is reported in the popover, or in an
  alert once the popover has closed. Stale or missing items are dropped and
  the list is reread. OSC 7501 reports status only: Swiftty never answers a
  request for the program.

## Roaming SSH (RST/1)

[spec.roaming.md](spec.roaming.md) (with its Swiftty integration in Appendix A) defines SSH clients for Apple
platforms whose shells survive network changes: the per-user SwiftMux agent on
the Mac owns the PTY and the authoritative Swiftty terminal, and clients
receive complete current screens over QUIC instead of a byte log. There is no
speculative echo; typing latency is ordinary remote echo.
Appendix B of the spec records the design sources.

| Target | Role |
|---|---|
| `SessionCore` | IDs, limits, input ledger (client queue, host admission), lifecycle, backoff, transfer manifests |
| `ScreenProtocol` | RST/1 messages, framing, RFC 1950 snapshots, validation, snapshot scheduler, bootstrap envelope and attention metadata, `RSTConnection` |
| `SSHClient` | SwiftNIO SSH: host trust, password/Ed25519, exec, shell, SFTP v3 subset, resumable verified transfers |
| `SSHIdentity` | SSH identities (spec.ssh-identity.md): UUID metadata, Keychain storage policies, read-only resolution, bounded OpenSSH Ed25519 import, including passphrase-protected keys; client-only |
| `AppleTransport` | Network framework QUIC (ALPN `rst/1`, TLS 1.3, no 0-RTT), SPKI and exact-certificate pinning, host identity |
| `TerminalHost` | RST/1 host over the SwiftMux service (owns no PTYs): `RoamingHost` QUIC listener and grants, in-process SMX client, screen exporter, session registry, bootstrap/attention service, control socket, roaming configuration |
| `TerminalSurface` | Client: `RoamingClient`, frontend backends (roaming, ordinary SSH, local PTY), SSH and QUIC bridges |
| `CompanionModel` | Bounded watch/iPhone status DTOs; no Swiftty, SSH or QUIC |
| `HostConnection` | Pairing-code descriptor and `_swiftty._tcp` discovery contract (spec.connection-setup.md); Foundation only |
| `RoamingApp` (`Apps/Shared`) | Shared app model and SwiftUI for the direct clients |
| `swifttyd` (`Apps/swifttyd`) | No-PTY SSH helper: `bootstrap --stdio`, `status` |

Host setup (spec.inbox.md §1): there is one PTY owner, the SwiftMux service.
`swiftmux-agent` serves remote clients from the same process as the native
app when a roaming configuration exists at
`~/Library/Application Support/SwiftMux/roaming/config.json` (or
`--roaming-config PATH`, or `$SWIFTMUX_ROAMING_CONFIG`) with an explicit
`bindAddress`, `advertisedHost` and UDP `port` (51222 by default), plus an
optional `stateDirectory`. A relative state directory is resolved against the
directory of the selected configuration file, so the agent and SSH helper select
the same control socket independently of their working directories. A missing
default configuration disables roaming. A missing explicitly selected file, or
an unreadable or invalid configuration, exits with status 78 before the agent
starts its service. `--no-roaming` ignores the file; the last roaming option wins.
`--idle-exit
SECONDS|never` sets the local idle exit, which roaming disables.
`Scripts/install.sh --roaming [--host H] [--bind A] [--port N]` writes this
file (default `<LocalHostName>.local`, `0.0.0.0`, 51222) and installs the
helper. Enable Remote Login yourself. The signed bootstrap helper lives at
`/usr/local/libexec/swifttyd`; it only relays `bootstrap --stdio` to the
service's control socket (`swifttyd status` checks it). RST/1 session IDs
are SwiftMux workspace IDs, the grant's server instance is the service
epoch, and each attachment takes the workspace's interactive lease: a
workspace the Mac app controls is refused (`writerBusy`) unless the client
resumes with `takeover`. Grant expiry never ends a shell the remote client
did not create.

To allow incoming connections to the bundled `swiftmux-agent` through the
macOS firewall, run `Scripts/install.sh --roaming --configure-firewall`.
This uses `sudo` to add and unblock the installed agent, verifies its exception,
and reapplies it on repeat installs. The exception covers the executable,
rather than a single UDP port. Setup reports whether the firewall is disabled
or **Block all incoming connections** overrides the exception; global firewall
settings stay unchanged. Other firewalls, routers and managed network policies
may still need to allow the configured roaming UDP port. A configured exception
does not verify reachability from another device. Without `--configure-firewall`,
setup leaves firewall policy unchanged.

### Xcode Cloud, TestFlight and releases

The roaming clients are one universal-purchase app, `dev.chr33s.swiftty`:
`MobileClient` (iOS/iPadOS, embedding `WatchCompanion` as
`dev.chr33s.swiftty.watchkitapp`), `CatalystClient` (macOS), `VisionClient`
and `TVClient` are platforms of one App Store Connect app, so testers see a
single TestFlight entry. Swiftty.app is the Mac terminal and host; Mac users
reach remote sessions through the Catalyst build.

`Apps/ci_scripts/ci_post_clone.sh` drives Xcode Cloud: it installs XcodeGen,
generates `Apps/Swiftty.xcodeproj` and copies `Package.resolved` into
it (Xcode Cloud never resolves packages itself). Create one Xcode Cloud
product for the app, pointed at `Apps/Swiftty.xcodeproj`, with
`SWIFTTY_TEAM_ID` (and optionally `SWIFTTY_LINK_DOMAINS`) in the workflow
environment, and one workflow with an archive action per platform, each
with a TestFlight post-action:

| Scheme | Archive platform |
|---|---|
| `MobileClient` | iOS |
| `CatalystClient` | macOS |
| `VisionClient` | visionOS |
| `TVClient` | tvOS |

tvOS and visionOS need layered icons (`Apps/TVClient/Assets.xcassets` with
the Top Shelf images, `Apps/VisionClient/Assets.xcassets`); regenerate them
from `icon.svg` with `xcrun swift Scripts/gen-platform-icons.swift`.

Swiftty.app is unsandboxed (it owns local PTYs) and is distributed with
Developer ID. `.github/workflows/release-mac.yml` runs on the Namespace
`namespace-profile-mac` runner for a pushed `v<version>` tag (or manually, as a
`mac-v<version>-<build>` prerelease): `Scripts/package-swiftmux.sh` builds and
signs it, then `Scripts/release-mac-github.sh` notarizes it (`Scripts/notarize.sh`,
shared with the package and install scripts) and uploads a zip and SHA-256 to
the release, or to an existing draft for the tag. The Namespace `mac` profile must
provide Apple Silicon, macOS 27, Xcode 27 and Swift 6.4. The workflow imports the
Developer ID certificate and private key into a temporary keychain from the
base64 `MACOS_CERTIFICATE_P12` secret and its `MACOS_CERTIFICATE_PASSWORD` secret,
then removes the keychain after the release, including on failure. It also needs
the repository variable `DEVELOPER_ID_IDENTITY` and an App Store Connect API key as the secrets
`NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` and `NOTARY_KEY` (the `.p8` contents).

### Connecting a device

[spec.connection-setup.md](spec.connection-setup.md) covers client setup. To
set up a device:

1. On the Mac, open **Terminal Service › Connect a Device…**. The panel shows
   the SSH host, port and account; the configured roaming endpoint; local
   checks of SSH and `swifttyd`; and the SSH host-key fingerprints. Turn on
   **Show Pairing Code** for a QR code, or **Make Discoverable While This
   Panel Is Open** to advertise `_swiftty._tcp` on the local network. Closing
   the panel stops advertising. The panel never turns on Remote Login or
   changes the firewall or roaming configuration.
2. On the iPhone or iPad, open **Settings › Connect to Mac** and choose **Nearby Macs**,
   **Scan Mac Code**, **Paste Mac Code** or **Enter Address Manually**. The
   app asks for Local Network access when it browses or first reaches a LAN
   address, and asks for camera access only when you scan. A code's SSH key
   fingerprints must match before any password is sent, and an unknown key
   still needs an explicit Trust.
3. After sign-in, choose a workspace, or choose **New Workspace**. Opening a
   saved host always shows this list; nothing is created automatically.
   Taking control of a workspace that another client holds needs your
   confirmation.

SSH and roaming use separate addresses. The device first reaches the Mac
over SSH, then reaches the roaming endpoint that the Mac's configuration
advertises over UDP. A `<LocalHostName>.local` endpoint works only on the
local network or a VPN that carries it. If SSH works but that endpoint does
not, the app shows "SSH connected; roaming endpoint unavailable" with the
address it tried.

Clients bootstrap with `ssh <mac> /usr/local/libexec/swifttyd bootstrap --stdio`
(a no-PTY exec with a length-prefixed JSON request), receive a session grant
with the agent's certificate, its SPKI pin (SHA-256 of the certificate's
SubjectPublicKeyInfo) and a bearer token, and attach over QUIC. The TLS
handshake must present that key and that exact certificate before the token is
sent; a changed pin fails closed (spec.inbox.md §1.8). The apps are generated
with XcodeGen:

```sh
Scripts/build-platforms.sh   # iOS, macOS, Catalyst, visionOS, tvOS, watchOS, swifttyd
mise exec -- swift test --filter "ProtocolTests|IntegrationTests"
```

`IntegrationTests/EndToEnd` runs the real registry, PTY, QUIC listener, pinned
client and a presentation-mode display, with and without an in-process SSH
server. Simulator runtimes:

```sh
Scripts/test-roaming-simulator.sh <ios-or-ipad-udid> [iOS|tvOS|visionOS]  # client in the simulator vs a real roaming SwiftMux agent
Scripts/test-companion-watch.sh <watch-udid>                             # companion tests hosted by the watch app
Scripts/test-real-ssh.sh                                                 # real OpenSSH (apple/container Linux VM) + real swifttyd
Scripts/test-app-ui.sh '<xcodebuild destination>' [xcodebuild args]      # XCUITest of a client app vs real OpenSSH + swifttyd
Scripts/test-keychain-signed.sh '<destination>' [team-id]                # signed, app-hosted Keychain test
```

`test-roaming-simulator.sh` accepts `--configuration release` to build both
the native host products and simulator test bundle in Release; it defaults to
Debug. The fixture records the selected configuration alongside its results.

`test-real-ssh.sh` needs `container`. `swifttyd` is macOS-only, so the Linux
VM's `/usr/local/libexec/swifttyd` relays `bootstrap --stdio` to an agent on
this Mac. macOS Local Network privacy can deny test runners a route to the VM
subnet, so the script reaches sshd through `container exec`.
Set `RST_REAL_SSH_CONFIGURATION=release` to build and run the host, launcher,
bootstrap helper and test bundle in Release; the default is `debug`.
The wrapper compiles tests before starting the fixture and runs them without
rebuilding while the host is live.

The fixture keeps a private process owner for each host/bridge/relay, the UI-test
build (`xcodebuild.log`) and optional Bonjour advertiser (`advertiser.log`). `stop`
authenticates those owners and waits for child exit, escalating after six seconds
while allowing the proxies to reap their own children. PID files alone never
authorize signals. Missing owners, legacy PID-only records and failed cleanup
retain their markers and return an error. A `start.lock` prevents concurrent
startup/stop; if startup was forcibly killed, verify it has ended before removing
that lock and retrying cleanup.
The UI wrapper polls the collected build status so cancellation can stop an
active build before retiring the rest of the fixture. A build that ignores TERM
is killed and reaped after the same six-second grace period.
Container deletion and listing each have a ten-second deadline and capped output.
The container marker clears after successful deletion, or after a successful,
validated listing confirms the recorded VM is already absent; failed commands
and malformed listings alone never establish absence.

Roaming verification record (2026-10-10, Xcode 27.0, OS 27 SDKs):

| Destination | Evidence |
|---|---|
| iPhone 16, iOS 27.0.1 (physical) | App UI flow over LAN to real `swifttyd` + OpenSSH; signed Keychain; A2: 50 Wi-Fi↔5G switches over Tailscale, one retained shell, no duplicated input (`Tests/DeviceHandover/Evidence`) |
| iPad Pro 12.9" (5th gen), iPadOS 27.0.1 (physical) | App UI flow over LAN; signed Keychain |
| macOS 27 native, Mac Catalyst | App UI flow; signed Keychain (Apple Development) |
| iOS, iPadOS, tvOS, visionOS simulators | Roaming runtime test vs real `swifttyd`; Keychain |
| watchOS simulator | Companion tests hosted by the watch app |
| macOS host | Unit, integration, end-to-end QUIC and real OpenSSH suites |

QUIC connection migration: clients enable it (`multipathServiceType =
.handover`), but Network framework's QUIC listener on the OS 27 SDK keeps
replying to a client's old address, so a path change ends in reattachment to
the retained session instead (spec §9 fallback). `MigrationTests` documents
the listener behaviour and `RoamingEndToEndTests` checks recovery to the same
shell with each command applied once.

Still open (spec §2.4, §13): physical Apple TV, Vision Pro and paired Apple
Watch runs.

`Scripts/test-handover.sh <iphone-udid> [switches] [team-id]` runs A2: a standalone app
on the phone keeps one roaming session open while you toggle Wi-Fi, and the
retained shell on the Mac logs one line per switch.

### SSH keys and iCloud sync

[spec.ssh-identity.md](spec.ssh-identity.md) makes an SSH key a reusable
identity. **Settings › SSH Keys** (or **New Key** in the host editor)
generates an Ed25519 key or imports an OpenSSH Ed25519 private key from a
file or an explicit paste; a passphrase-protected key asks for its passphrase
once, which is not saved. Hosts select a key by UUID, so renaming never breaks them. Add the shown public key
to `~/.ssh/authorized_keys` on the Mac yourself. Signing in only reads the
selected key: a missing, locked, deleted or mismatched key fails closed, never
generates a replacement and never falls back to a password.

Keys are device-only by default (`WhenUnlockedThisDeviceOnly`, never
synchronized). A key created or imported as **iCloud Keychain** is
synchronizable (`WhenUnlocked`); the policy is fixed per key, with explicit
**Create iCloud Copy** and **Withdraw from iCloud** actions that make a new key.
Items use service `dev.chr33s.swiftty.ssh-identity.v1` and the access group
`$(AppIdentifierPrefix)dev.chr33s.swiftty`.

**Settings › iCloud Sync** separately opts in to syncing host profiles and
public key metadata, and trusted host keys, through the private CloudKit
database (zone `SwifttyConnectionsV1`). Both are off by default and only appear
when the clients are generated with `SWIFTTY_CLOUDKIT_CONTAINER` set to a
provisioned container (Scripts/configure-links.sh). Sync runs in the
foreground only, never carries private keys or passwords, and keeps another
iCloud account's data hidden after an account switch. tvOS keeps local key
sign-in and generation, without import or sync.

iCloud key operations use the configured account provider even when metadata
sync is off. Interrupted operations retain their original account; enabling
metadata sync does not move another account's pending work. Older interrupted
creations without account information require explicit Restore in SSH Keys.
Older removals appear under **Key Removals Needing Review**. Review the
fingerprint before authorizing removal from the current iCloud account;
failed removals remain queued for retry. Returning to the foreground retries
interrupted key operations even when metadata sync is off.
Completed iCloud keys also stay with their original account. Older descriptions
without account information appear under **Keys Needing Account Review**;
restoring one verifies its fingerprint in the current account without enabling
metadata sync.
Builds without an account provider still support device-only keys.

`hosts.json` uses a version-4 snapshot of all non-secret connection state.
It preserves separate account caches when record names collide and upgrades
version-2 and version-3 snapshots, retaining records and queued edits while
requiring review for older iCloud keys with unknown account ownership.
Version-1 key labels migrate to device-only identities with the same key and
fingerprint. Migration keeps the original file as `hosts.v1.json` and removes
each legacy Keychain item only after its replacement is verified. Earlier builds reject the version-4 file when
loading it.

## API and storage contracts

The session, snapshot, input, configuration, and frontend APIs are the embedding
surface. This pre-1.0 package provides source compatibility within patch releases;
minor releases may change public APIs. Internal and `package` declarations have
no compatibility guarantee. Physical row ids, pointer access, storage pools, and
benchmark hooks are implementation details.

`Grid.cells(row:)`, `Grid.historyCells(at:)`, `TerminalState.viewportCells(row:)`,
and `TerminalState.scrollbackCells(at:)` return borrowed spans. End each borrow
before mutating its owner. Grid writes require exclusive access;
`withMutableCells(row:_:)` updates the row extent even when its closure throws.
Indices and allocation sizes are checked before accessing memory. Nonpositive
screen dimensions are clamped to one.

History storage is reclaimable and, on macOS and iOS/iPadOS, compressed when
idle. History
chunks use dedicated page-aligned mappings divided into compression units of at
most 256 KiB; after 250 ms without output, input, viewport or resize activity,
the owning session or SwiftMux pane encodes at most one unit per step on its own
queue (LZ4 through Apple's Compression framework, verified by CRC-32C). The
viewport, recent captures, the next eviction rows and both live screens stay
resident. Warm row access is O(1) with no Swiftty heap allocation; a cold
borrowed read restores its units in place, costing O(bytes of those units)
plus page commitment, and never invalidates another borrowed row. Search,
selection copy, ANSI dumps, link detection, OSC 8 reclamation, invariant checks
and reflow read cold history through at most two units of scratch without
restoring it. Clearing history drops compressed units without decoding them and
returns fully free units' pages to the system. Retention limits count
uncompressed history cells, so compression never changes which rows are kept.
Compression runs no timers when idle and never redraws, publishes, or changes
addressing or search generations. A compressed unit that fails its integrity
check traps (fail-fast). macOS and iOS/iPadOS use this backend; Catalyst,
visionOS and tvOS keep uncompressed heap chunks.
`TerminalState.scrollbackStatistics` reports logical, resident, compressed,
metadata, workspace, protected, eligible and reclaimed bytes from metadata
alone; `scrollbackCompression` reports the requested and effective policy with
the fallback reason.

Snapshot spans borrow the snapshot. Retaining a snapshot preserves its cells
while later frames reuse other pool entries. Grapheme ids belong to the snapshot
that produced the cell; passing a cell from another snapshot to
`graphemeScalars(_:)` is invalid even when the numeric id happens to match.

`SWIFTTY_INTERNAL_CHECKS` validates row ownership, ring bounds, blank extents,
grapheme references, and wide-cell structure at completed parser batches and
storage bounds after mutations. Checks and their scratch storage are absent
from normal builds.
`mise run test-internal` enables them. Storage benchmarks vary size and ring layout,
exclude setup from timing, and report consumed results alongside nanoseconds per
operation; run them in Release without internal checks.

Swift formatting follows the pinned Swift Collections configuration: two-space
indentation, 80-column wrapping, and unindented conditional-compilation bodies.
`mise run format-check` also validates documentation comments. Generated Unicode
tables retain their generator's layout. CI and release builds use the Namespace
`namespace-profile-mac` runner with Apple Silicon, macOS 27, Swift 6.4 and Xcode 27.
The shared macOS setup action verifies the toolchain and installs ripgrep and
tmux for native tests.

## Configuration

Ghostty-style `key = value` files support whole-line `#` comments, repeatable
keys, empty-value resets and `config-file` includes. Unknown keys are reported
and ignored. macOS reads `$XDG_CONFIG_HOME/swiftty/config` (default
`~/.config/swiftty/config`). Settings (Cmd-,) edits the common options in
place, rewriting only their own lines, and lists configuration problems;
Edit Configuration File (Opt-Cmd-,) opens the file and Shift-Cmd-, reloads it.
Reduce Motion, Reduce Transparency and Increase Contrast adjust how it is
drawn without changing the file ([spec.apple.md](spec.apple.md)).
iOS reads `Documents/config`.

Terminal windows use Liquid Glass by default, with `background-opacity = 0.5`
and `background-blur = true`. Set `background-opacity = 1` for an opaque
terminal or `background-blur = false` for translucency without glass.

```text
font-family = JetBrains Mono
font-size = 14
font-feature = calt
font-variation = wght=500
font-synthetic-style = no-bold
adjust-cell-height = 10%
theme = light:Swiftty Light,dark:Swiftty Dark
background = #1e1e2e
palette = 1=#f38ba8
background-opacity = 0.9
background-blur = true
minimum-contrast = 3
cursor-style = bar
cursor-style-blink = false
cursor-click-to-move = true
rectangle-checksum-report = false
copy-on-select = true
link-url = true
mouse-hide-while-typing = true
window-padding-x = 6
scrollback-limit-bytes = 20000000
scrollback-limit-lines = 100000
scrollback-compression = true
command = /opt/homebrew/bin/fish
keybind = super+shift+k=clear_screen
keybind = ctrl+shift+arrow_up=jump_to_prompt:-1
```

`scrollback-limit-bytes` (alias `scrollback-limit`; the last assignment wins)
budgets uncompressed history cells per terminal (default 10,000,000);
`scrollback-limit-lines` caps physical history rows (default 100,000). Zero
disables history; negative, overflowing and `unlimited` values are rejected.
`scrollback-compression` (default `true`) compresses idle history where
supported; turning it off stops maintenance without decoding existing history.
Limits apply when a terminal is created.

Style-specific font families use `-bold`, `-italic` and `-bold-italic` suffixes.
`font-style` (and the same suffixes) selects a named face such as `Retina`;
`false` uses the regular face for that style, and a name the family lacks is
reported and falls back to the default face. `macos-icon` is accepted so a
shared Ghostty config loads, but Swiftty has a single icon.
Cell adjustments accept points or percentages. Foreground, cursor and selection
colors can be configured separately. Themes are searched in
`~/.config/swiftty/themes`, `~/.config/ghostty/themes`, then the built-in
`Swiftty Dark` and `Swiftty Light` themes (Blackboard dark and light). Without
`theme`, the palette follows the appearance as
`light:Swiftty Light,dark:Swiftty Dark`.

Includes load in declaration order and override earlier settings; nested includes
join the end of the queue. Each file loads once. `config-file =` clears pending
includes. Relative paths resolve against the declaring file; `?path` permits a
missing include, while `"?path"` names a literal leading question mark.
Theme files must be regular UTF-8 files of at most 64 KiB. Configuration files
are limited to 1 MiB each and a shared 4 MiB read allowance across at most 128
file attempts, including missing, repeated and invalid files. Size checks may
read one extra byte per file to detect growth. Clearing pending includes keeps
the work already charged. Rejected files leave earlier settings applied and
report diagnostics; an optional include suppresses only missing-file errors.
An unavailable theme uses the next lookup directory or built-in fallback;
an unavailable explicit path uses the default palette plus configured colors.
`palette =` clears indexed overrides and restores theme colors.

`command` uses shell expansion, including quotes, variables and globs; `shell:`
selects it explicitly. `direct:` splits arguments on spaces without expansion
or quote processing. Programmatic `SessionConfiguration(command: [...])` passes
arguments directly. `working-directory` accepts a path, `home` or `inherit`.
Desktop launches default to the account shell and home directory; command-line
launches inherit the directory and prefer a nonempty `SHELL`.

Keybinding actions include clipboard operations, font sizing, selection, scrolling,
prompt jumps, search, clear/reset, `text:…`, `csi:…`, `esc:…`, `ignore` and `unbind`;
their names and parameters are defined in
[Keybindings.swift](Sources/SwifttyCore/Config/Keybindings.swift).

Custom shaders use Metal and define
`float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u)`.
See [PostProcess.swift](Sources/SwifttyCore/Renderer/PostProcess.swift) for uniforms.
`position` uses pixel coordinates; normalize it for a `coord::normalized` sampler.
Shaders accessing `u.time` animate continuously. Memory aliases and preprocessor
directives enable animation conservatively; other shaders draw on demand.
Relative shader paths resolve against the declaring configuration file.

## Generated Unicode data

```sh
mise run unicode [EastAsianWidth.txt]
mise run graphemes <ucd-dir>
```

The width generator needs matching `PropList.txt`,
`extracted/DerivedGeneralCategory.txt` and `emoji/emoji-data.txt`; without a path,
it downloads companion files from the same release. Grapheme data must match the
Ghostty comparison build. Both commands stage replacements and reject truncated
inputs missing their final `# EOF` or `#EOF` marker.

## Measured results

These are Release measurements on Apple Silicon. Parser throughput, physical iPad
frame time and the centered onscreen comparison were measured on 2026-10-10.
Earlier probes are identified below.

### Swiftty vs Ghostty

Parser and terminal-state throughput on an Apple M5 Max (18 CPU cores): Ghostty
`5dc28bb`, Zig 0.16.0 ReleaseFast, versus Swift 6.4 Release. Each binary read the
same generated 100 MiB files in 64 KiB chunks at 120×80 with 10,000 bytes of
history. Medians include startup and file I/O: two warmups and 20 serial,
alternating measured runs per binary. Swiftty was faster on all 14 inputs by median.

Lower times are better. Relative throughput is `Ghostty time / Swiftty time`;
100% means equal speed. This benchmark measures parsing and state updates;
the onscreen comparison below measures a separate frontend endpoint.

| Input                |   Ghostty |   Swiftty | Relative throughput |
| -------------------- | --------: | --------: | ------------------: |
| ascii                |   99.0 ms |   93.8 ms |              105.6% |
| cat-source           |  122.0 ms |  114.4 ms |              106.6% |
| compiler-log         |  140.9 ms |  125.1 ms |              112.7% |
| csi-heavy            |  477.5 ms |  357.4 ms |              133.6% |
| ghostty-ascii        |   68.6 ms |   61.0 ms |              112.5% |
| ghostty-osc          | 4104.0 ms | 1092.8 ms |              375.6% |
| ghostty-styled       |  409.1 ms |  211.9 ms |              193.1% |
| ghostty-utf8         |  687.9 ms |  536.7 ms |              128.2% |
| osc-heavy            | 1111.7 ms |  541.4 ms |              205.3% |
| scroll               |  406.4 ms |  303.9 ms |              133.7% |
| unicode-joins        |  348.2 ms |  258.6 ms |              134.7% |
| utf8 (mixed scripts) |  333.1 ms |  332.3 ms |              100.2% |
| utf8-latin           |  129.2 ms |  122.5 ms |              105.4% |
| utf8-cjk             |  100.6 ms |   92.4 ms |              108.9% |

Wide-cell batching cut CJK time by 17.7% versus the frozen previous build. CJK
throughput relative to Ghostty has a 95% paired bootstrap interval of 108.1–110.0%.
Other inputs changed by −1.0% to +1.9% in time. Larger eight-scalar UTF-8 decode
batches were slower and were discarded. Mixed UTF-8 has little margin over Ghostty.
The corpus combines nine Swiftty inputs, four Ghostty inputs (styled: seed 42,
style rate 0.3; UTF-8: seed 42) and a combining/ZWJ/flag fixture.

To compare the same workloads, build Ghostty's benchmark and use generated `.bin`
inputs (`swiftty-bench gen <name>` or `ghostty-gen +<name>`):

```sh
# In the Ghostty checkout:
zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
# In this repository (also builds swiftty-bench in Release):
RUNS=20 mise run compare <ghostty-src> <corpus-dir>
```

### Memory and rendering

Against milestone 1 (`67c8dfa`), the current Release build passed all 18
text-only RSS cases: nine inputs at 120×80 with 10,000-byte and 10 MiB
histories, two warmup pairs and six alternating measured pairs. Median RSS
changes ranged from −30.7% to +0.74%.
Offscreen scrolling at 120×40, 20 lines/frame, improved p95 from 0.640 to
0.508 ms across 20 measured pairs after four warmups (paired change −0.129 ms,
95% interval −0.171 to −0.119 ms). Both builds used Swift 6.4; the display was
locked during this offscreen comparison.

Borrowed grapheme-cache lookups reduced warmed full-redraw allocations to 11
per frame, matching plain text. Median offscreen frame time fell by 17.7% for
combining marks, 12.8% for ZWJ emoji and 10.0% for long clusters.
Parser/grid allocation tests require zero steady-state allocations for common
ASCII, UTF-8, CSI and cell updates. OSC metadata and table growth can allocate.

A physical iPad Pro (12.9-inch, 5th generation), iPadOS 27.0.1, measured the
current core's 120×40 offscreen full redraw at p50 1.580 ms and p95 2.930 ms
(20 warmups, 220 frames). Dense search highlights measured p95 3.030 ms
(five warmups, 35 frames). GPU completion was awaited; both tests passed.

### Onscreen probes

The current Swiftty AppKit view in a Release probe was compared with Ghostty
1.3.1 (15212) on the same M5 Max display. Both used Menlo 13, an 80×24 PTY,
blinking disabled and the same raw-PTY response script.

Three serial alternating pairs posted synthetic keys to trigger alternating
black/white backgrounds. The same independent ScreenCaptureKit observer detected
these changes through a 32×32 crop at the display center, requesting 120 capture
frames/s. Each run used 20 warmups and 100 measured responses; all 720 were
observed. Ranges span runs; lower times are better.

| Terminal      |              p50 |              p95 |
| ------------- | ---------------: | ---------------: |
| Swiftty       | 16.683–16.983 ms | 23.461–24.919 ms |
| Ghostty 1.3.1 | 18.574–21.319 ms | 24.665–25.661 ms |

Median paired p95 difference was −0.742 ms (Swiftty minus Ghostty). This
measures synthetic key-to-captured-pixel delivery, including capture overhead.
Physical-keyboard, glyph-typing and photon-level latency have not been measured.

AppKit now uses two drawables. Matched foreground scrolling probes without
Instruments used 900 updates at 60 Hz and 1,800 at 120 Hz per queue. Compared
with the default three drawables, 120 Hz draw-to-presentation p95 fell from
40.7 to 32.3 ms; presentation-interval p95 stayed at 8.33 ms, with two-refresh
intervals falling from eight to two. Neither run had presentation gaps over
100 ms; earlier multi-second profiled stalls did not recur.

Earlier physical iPad probes at 169×57 presented all 220 measured updates from
a confirmed 120 Hz source after 20 warmups: presentation-interval p95 8.338 ms,
synthetic output-to-presentation p95 24.748–24.797 ms. A 60 Hz probe measured
latency p95 25.961 ms and presentation-interval p95 25.014 ms. All timestamps
were positive. With blinking disabled, the probes observed zero draws during
eight idle seconds and two background seconds with incoming output.

## Verification status

These results describe earlier tested builds. Current validation gaps are tracked
in [todo.md](todo.md); historical device results do not verify the current tree.

The earlier macOS Debug/Release baseline passed 1,156 tests. Added keypad-mode coverage
and 86 AppKit checks passed in both configurations. The hosted simulator
passed 171 mobile tests. The physical iPad build tested then passed 169 correctness
tests and two separate frame-time tests. Release builds passed for visionOS and
Mac Catalyst.

Coverage includes Unicode batching, recorded sessions, shader classification,
visibility/opacity recovery, animation suspension, momentum cancellation and
accessibility. Native probes verified
drawable recovery and draw suspension/restoration on both platforms.
UI automation passed shell typing and Find navigation, highlighting, query/terminal
focus and accessory-bar restoration, including narrow windows and resizing.

Physical keyboard, Find, VoiceOver, link navigation and browser-return redraw
checks passed on both devices; macOS also passed interactive `vim`/`less`, resizing
and scrolling. User checks passed blur and corrected static/animated shaders on
both devices. Scripted and hands-on USB shell checks with `vim`, `less`, `tmux`
and `top` passed on the physical iPad. The user reported typing and scrolling
equally responsive alongside Ghostty in the two-drawable Mac build.
Battery consumption has not been measured.
[The consolidated backlog](todo.md#deferred-terminal-feature-checks) lists deferred
checks that need protocols or APIs Swiftty does not implement yet.
