# swiftty

Swift 6.4 terminal core and frontends for macOS (AppKit) and iOS/iPadOS
(UIKit). `SwifttyCore` and `SwifttyMobile` also build for Mac Catalyst,
visionOS and tvOS. [spec.md](spec.md) defines scope, protocols and
acceptance requirements. [Shell](https://github.com/chr33s/shell) embeds the
core through its libghostty API.

## Build and test

Requires Xcode 27 and the tools pinned in `mise.toml`:

```sh
mise install
mise run build      # debug build; `mise run release` for release
mise run test-native # full unit suite and real PTY sessions: sh, vim, less, tmux, top
mise run test-internal # the same, with storage and terminal invariant checks
mise run app        # launch the macOS terminal
mise run bench      # Release microbenchmarks; bench-storage for storage scaling
mise run lint
mise run format     # format-check also validates documentation comments
```

Packaging and installation are under [SwiftMux](#swiftmux); the Ghostty
comparison is under [Measured results](#measured-results).

The native host runs tests serially because suites share AppKit state and use
blocking dispatch handoffs. Each manifest test bundle must exist and report a
complete run. A missing or failing bundle fails the command; later bundles still
run so their diagnostics are available. Allocation budgets run only with
optimized code; `Scripts/test-native.sh -c release` checks them alongside the
rest of the suite. Run a subset with `Scripts/test-native.sh --filter PATTERN`
(repeatable; the same regular expressions as `swift test --filter`); a filter
that matches no test fails. Use it rather than plain `swift test` for AppKit
tests: SwiftPM's runner can end those bundles early with a zero exit, which
`Scripts/test.sh` reports as incomplete.

Use Xcode's Swift 6.4 toolchain, as CI does; `mise.toml` pins the other
tools but not Swift, because swift.org toolchains bundle a Swift Testing runtime
that conflicts with Xcode 27.2's and stops `Scripts/test-native.sh` from
finding tests. CI and release builds use the GitHub-hosted `xcode-27` runner
and enforce `Package.resolved`; see
[setup-macos](.github/actions/setup-macos/action.yml) for toolchain selection.
Formatting follows the pinned Swift Collections configuration: two-space
indentation, 80-column wrapping and unindented conditional-compilation bodies;
generated Unicode tables retain their generator's layout.

Build the UIKit frontend with Xcode; the package's AppKit executable scheme is
macOS-only:

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

## Native shell development

[spec.shell.md](spec.shell.md) defines `swsh`, the native shell: the
[language contract](spec.shell.md#2-simplify-the-language-deliberately)
(quoting, expansion, builtins, functions, subshells, command substitution,
programmable completion), the
[process and pipeline runtime](spec.shell.md#6-process-and-pipeline-runtime),
job control, session shutdown, the
[acceptance matrix](spec.shell.md#failure-focused-verification-matrix) and the
[implementation record](spec.shell.md#10-implementation-record). None of it
aims at Bash compatibility.

```sh
swift build --product swsh
swift run swsh -c "name='two words'; /usr/bin/printf '<%s>\\n' \$name"
swift test --filter SwshTests
python3 Scripts/test-swsh.py "$(swift build --show-bin-path)/swsh"
```

Usage details not spelled out in the spec:

- Source may also arrive on nonterminal stdin. Inside double quotes a
  backslash escapes `$`, `"`, `\` or a newline and is otherwise literal;
  outside quotes backslash-newline continues a line, and unquoted `#` starts
  a comment at a word boundary. Ambiguous redirect targets are errors.
- `cd` uses a physical cwd and defaults to `HOME`; `pwd` takes no options.
  `export NAME` exports the current scalar (empty if unset), `export
  NAME=value` sets and exports it, and `unset` removes both value and export
  status. `exit` takes an optional 0–255 status. Assignment-only commands
  commit together. Redirect descriptor duplication accepts `-` to close.
- `exec` rejects prefix assignments, redirections and a missing program. A
  failed lookup or replacement returns 127/126 and later commands still run;
  interactive failure restores the editor on the next prompt.
- Standalone stateful builtins with redirects commit state only after setup
  succeeds. FIFO setup can be cancelled with Ctrl-C or session shutdown and is
  not a separately stoppable job.
- `fg` and `bg` take an optional job ID, with or without `%`, defaulting to the
  newest live job. `SWSH_TERMINAL_METADATA=0` disables OSC 7 and OSC 133.
- Interactive mode (terminal stdin or `-i`) reads `~/.swshrc` once. Ctrl-C
  cancels the edit, Ctrl-D at an empty prompt exits, Ctrl-U clears the line,
  Ctrl-W removes the last word, and up/down browse history. Bracketed paste
  inserts without submitting embedded newlines. History lives in the mode-0600
  JSON-lines `~/.swsh_history`, bounded to 1 MiB and 1,000 entries; a
  submission over 64 KiB is not persisted.
- For direct PTY hosts that create a session without assigning its controlling
  terminal, interactive `swsh` claims the attached slave only when it is the
  session leader and has no controlling terminal.

Run `python3 Scripts/measure-swsh.py --output /tmp/swsh-measurements.json` for
release measurements; [spec.shell.md](spec.shell.md#measurements) describes
the method and the recorded baselines
([2 November](Benchmarks/Swsh/baseline-2026-11-02.json),
[1 November](Benchmarks/Swsh/baseline-2026-11-01.json)). The 1 November
baseline, on an Apple M5 Max with 128 GiB RAM, gave these medians of 30
warm-cache samples:

| Workload | Median |
| --- | ---: |
| CLI startup and `:` exit | 4.38 ms |
| Private builtin worker startup, prewritten payload | 3.94 ms |
| Interactive first prompt, including PTY fixture setup | 9.41 ms |
| 16 MiB binary stream through three external pipeline stages | 147.6 MiB/s |
| 16 MiB stderr stream | 1,059.0 MiB/s |

After subtracting the median empty invocation, the amortized cost was 12.1 µs
per parent builtin, 1.88 ms per builtin pipeline worker (including two-stage
concurrency) and 3.30 ms per parent-redirect helper. An empty invocation made a
median 1,265 allocations across all threads with 6.66 MiB peak RSS; builtin
workers made 1,320 allocations and 6.52 MiB each. These are local observations,
not regression thresholds.

## Embedding

On macOS, `TerminalSession.start(_:)` can launch a PTY child. External
transports feed program output through `receive(_:)`, send encoded input from
`onWrite`, and forward resize events to the remote program. Connection setup,
authentication and reconnection belong to the embedding app.

For a local macOS view, call `TerminalView.start(_:)` with an explicit
`SessionConfiguration` to preserve exact executable arguments, environment, and
cwd while retaining the view's grid and display lifecycle. Its parameterless
`start()` still uses the view configuration. `onTerminalEvent` forwards passive
events on the main actor after built-in handling, alongside `onTitle` and
`onExit`. Metadata can be coalesced or forged by terminal programs; it is not an
authoritative command-completion API.

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
`.full`; set `.roaming` for remote presentation). Program-initiated clipboard
writes (OSC 52) reach the pasteboard only with `remoteClipboardWrites`. Without
the matching capability, link opening, search, scrollback, mouse reporting,
paste, copy and text input are hidden or disabled rather than shown as
nonfunctional controls; presentation sessions also disable local resets and
raw-byte bindings. On UIKit, `hidesContentWhenInactive` covers the terminal
while its scene is inactive or in the background, so app-switcher snapshots
omit it. Shell input disables autocorrection, capitalization, spell checking,
smart quotes, dashes and insert/delete, and inline prediction.

OSC 7501 program status is opt-in through
`SessionConfiguration.programStatusEnabled` or `setProgramStatusEnabled(_:)`;
read `programStatusSnapshot`, subscribe through `onProgramStatusChange`, route
`onTerminalReply` to the originating transport, and call `programExited()`
when the program or connection ends. The
[program-status contract](spec.md#osc-7501-program-status) specifies
validation, lifecycle and reply provenance.

## SwiftMux

[spec.durability.md](spec.durability.md) proposes session survival across
app/gateway updates and restarts, followed by planned live worker replacement.
Exact worker-crash recovery is a deferred extension. Saved layouts after reboot
are Capability C (spec.durability.md §12.2): with the durable gateway,
`swmux --gateway-service NAME saved` lists them, `restore` reopens one with
fresh shells, and the app offers them in Open Workspace and at launch. A separate `swiftmux-gateway` executable now composes native control,
continuous discovery and worker routing for the durable topology. It requires
explicit launchd service arguments and team signing; the app installer does not
yet register or select it. The behavior below describes the current production
implementation.

For an explicitly installed durable gateway, `swmux --gateway-service NAME`
selects its native control service. This supports `list`, `status`, `new`,
`attach`, targeted `end`, and interactive workspace switching. Listings include
retained unavailable workspaces and their IDs. Use an ID with `end -t ID` when
name metadata is unavailable. `detach` as a global command, `end-all` and `agent`
management are not yet implemented for this topology; interactive prefix detach
is supported. An attached terminal automatically reconnects after gateway transport
loss when its retained worker is available and its lease is free. Input typed
during recovery is discarded; prefix then `d` still detaches. Without this option, `swmux` keeps using the existing agent.

`swiftty --gateway-service NAME` selects the same explicitly installed topology
for the native app's startup, New Workspace, chooser and windows. It does not
install the helpers. Quit detaches windows and closes app control without ending
sessions. Attached windows automatically seek a fresh attachment after gateway
transport loss, preserving retained terminal state. Recovery stops if another
controller holds the lease or the worker is unavailable; it never replays input
or creates a replacement shell. App-managed updates, device pairing and external attention links are
not yet available in this mode; the app does not send those operations to the
legacy agent. Normal app launch continues to use the existing registration.

[spec.multiplexer.md](spec.multiplexer.md) describes SwiftMux, the persistent
session service: a per-user LaunchAgent (`swiftmux-agent`) owns the shells,
PTYs, terminal engines, history and workspace layouts, and frontends connect
over one Mach/XPC endpoint using `SMX/2`. Its
[limits](spec.multiplexer.md#execution-and-budgets) are enforced in `MuxLimits`.

- `swmux` is the terminal client. With no command it attaches to the newest
  workspace or creates one. Commands: `new [-s NAME] [-c DIR] [-d] [-- CMD]`,
  `attach [-t NAME]`, `list` (`ls`), `detach`, `end -t NAME`, `end-all`,
  `status` and `agent install|uninstall|status`. Attaching runs only inside
  Swiftty (`TERM_PROGRAM=swiftty`, or pass `--allow-host`). The prefix is
  `C-b`; press `C-b ?` for the bindings. Settings live in
  `$XDG_CONFIG_HOME/swmux/settings.json` (default `~/.config/swmux`):
  `prefix`, `escapeDelayMilliseconds` and `remainOnExit`.
- Every Swiftty app window is a SwiftMux workspace; its
  [commands, shortcuts and startup](spec.md#swiftmux-native-workspace) are in
  spec.md. swiftty › Terminal Service stages and installs app updates without
  replacing the bundle under a live service. Panes match the direct terminal,
  including `copy-on-select`, `link-url`, `cursor-click-to-move`,
  `mouse-hide-while-typing`, `custom-shader`, prompt jumps, Select Command
  Output, Clear Screen and Reset Terminal. A service started by an older build
  lacks the emulator-side ones, so their menu items stay disabled until it is
  updated.
- Panes start through `swmux-launcher`, which calls `login_tty` and then execs
  the shell. They run with `TERM=swmux-256color`; the agent compiles that
  terminfo entry into `~/Library/Application Support/SwiftMux/terminfo`.

```sh
swift build
.build/debug/swmux agent install   # development LaunchAgent for this build
.build/debug/swmux new -s work     # inside Swiftty
mise run package-swiftmux [identity]     # Swiftty.app with the bundled agent (SMAppService)
mise run install [--roaming]             # package, install to /Applications, register the agent (+ swifttyd)
Scripts/install-ios.sh --team TEAM       # iOS/iPadOS app on iPhones and iPads by USB, then Wi-Fi
mise run uninstall [--purge] [-y]        # remove the app, agent and swifttyd
```

`Scripts/install.sh` documents its signing identity, agent re-registration
(`--restart-agent`) and device options in its header. It also installs the
iOS/iPadOS app (`MobileClient`) on every paired, unlocked iPhone and iPad in
Developer Mode, connected by USB first and then over Wi-Fi (`--no-devices`
skips this). The bundled agent can be managed directly with
`Swiftty.app/Contents/MacOS/swiftty --swiftmux-agent register|unregister|status`.

Installation uses Python 3 to copy and verify the new app before an atomic
exchange publishes it ([spec.roaming.md](spec.roaming.md#4-macos-deployment-and-session-lifetime));
filesystems that refuse the atomic operation stop installation. Before
replacement, the installer checks the destination bundle's running application
through `swiftty --running-app APP_PATH`. A running copy there is left alone;
otherwise the installer opens the selected installation as a new instance,
even when another copy with the same name or bundle identifier is running
elsewhere.

`uninstall.sh` requires Python 3 to limit each shutdown command to ten seconds.
Failed or timed-out shutdown checks preserve installation files and state.
Repeated signals cannot replace an interruption result or abandon command
collection. Captured command output is limited to 64 KiB and is published only
after the command exits within its budget.

Acceptance evidence and measurements (`mise run bench-swiftmux`) are recorded
in [section 11 of spec.multiplexer.md](spec.multiplexer.md#11-acceptance-and-measurement-record).

### Deep links and attention inbox

Every SwiftMux pane parses OSC 7501 program status into an
[attention inbox](spec.inbox.md#3-osc-7501-attention-inbox) (reducer, service
hub, lease-free commands, native toolbar UI). Items open from
`swiftty://attention/open?ref=<locator>` or `https://<configured domain>/a/<locator>`
links; [spec.inbox.md §4](spec.inbox.md#4-deep-links-and-navigation) defines
the destination, the locator, link validation and per-platform routing. The
locator is not an authentication credential, and the app never connects to
anything named in a link.

Universal Links are off unless `SWIFTTY_LINK_DOMAINS` is set
(`Scripts/link-domains.sh` validates it; an invalid name fails the build).
`links.example.invalid` is a placeholder only. Setup:

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
Apple's CDN. The macOS entitlement is honoured only with a provisioning
profile that has the Associated Domains capability; without
`SWIFTTY_PROVISIONING_PROFILE` the script warns.

The watch shows redacted attention summaries and can hand off to a paired
device, but never takes a lease or sends input. Its preview text is bound to
an opaque selection id (not a host or session token) and is dropped when the
id changes, preview is disabled, or a status reply says no preview can be
served. A NaN or infinite refresh timeout uses the finite 15-second default.

## Roaming SSH (RST/1)

[spec.roaming.md](spec.roaming.md) (with its Swiftty integration in Appendix
A) defines SSH clients for Apple platforms whose shells survive network changes:
the per-user SwiftMux agent on the Mac owns the PTY and the authoritative
Swiftty terminal, and clients receive complete current screens over QUIC
instead of a byte log. There is no speculative echo; typing latency is ordinary
remote echo. Appendix B of the spec records the design sources.

| Target | Role |
|---|---|
| `SessionCore` | IDs, limits, input ledger (client queue, host admission), lifecycle, backoff, transfer manifests |
| `ScreenProtocol` | RST/1 messages, framing, RFC 1950 snapshots, validation, snapshot scheduler, bootstrap envelope and attention metadata, `RSTConnection` |
| `SSHClient` | SwiftNIO SSH: host trust, password/Ed25519, exec, shell, SFTP v3 subset, resumable verified transfers |
| `SSHIdentity` | SSH identities (spec.ssh-identity.md): UUID metadata, Keychain storage policies including Secure Enclave, read-only resolution, bounded OpenSSH Ed25519/ECDSA and PEM ECDSA import, including passphrase-protected keys, and saved host passwords; client-only |
| `AppleTransport` | Network framework QUIC (ALPN `rst/1`, TLS 1.3, no 0-RTT), SPKI and exact-certificate pinning, host identity |
| `TerminalHost` | RST/1 host over the SwiftMux service (owns no PTYs): `RoamingHost` QUIC listener and grants, in-process SMX client, screen exporter, session registry, bootstrap/attention service, control socket, roaming configuration |
| `RoamingKit` | Headless client core: `RoamingClient`, semantic input, presentation frames and the bootstrap/connector/sink seams; links the engine only |
| `RoamingConnect` | `RoamingKit` seams bound to SSH (`SSHBootstrapper`, `SSHShellByteChannel`) and pinned QUIC (`QUICGrantConnector`); no renderer or UI |
| `TerminalSurface` | GUI client glue: frontend backends (roaming, ordinary SSH, local PTY) over `TerminalSession`; re-exports `RoamingKit` and `RoamingConnect` |
| `TTYKit` | Outer-terminal I/O shared by `swmux` and `swroam`: raw mode, input decoding, display-width text, cell diff renderer |
| `RoamingTerminal` | TTY frontend for `RoamingKit`: frames through `TTYKit`, decoded input as semantic operations, reconnect banner |
| `swroam` (`SwRoamCLI`) | mosh-style roaming client for any terminal |
| `CompanionModel` | Bounded watch/iPhone status DTOs; no Swiftty, SSH or QUIC |
| `HostConnection` | Pairing-code descriptor and `_swiftty._tcp` discovery contract (spec.connection-setup.md); Foundation only |
| `RoamingStore` (`Apps/Store`) | Saved hosts, SSH identity lifecycle, CloudKit metadata sync and transfer manifests; no UI, terminal or renderer code |
| `RoamingApp` (`Apps/Shared`) | Shared app model and SwiftUI for the direct clients |
| `swifttyd` (`Apps/swifttyd`) | No-PTY SSH helper: `bootstrap --stdio`, `status` |

Host setup is defined in [spec.inbox.md §1](spec.inbox.md#1-one-service-two-transports):
`swiftmux-agent` serves remote clients when a roaming configuration exists at
`~/Library/Application Support/SwiftMux/roaming/config.json` (or
`--roaming-config PATH`, or `$SWIFTMUX_ROAMING_CONFIG`). `--no-roaming` ignores
it, and `--idle-exit SECONDS|never` sets the local idle exit, which roaming
disables. `Scripts/install.sh --roaming [--host H] [--bind A] [--port N]` writes
the file and installs the signed bootstrap helper at
`/usr/local/libexec/swifttyd` (`swifttyd status` checks it). Enable Remote Login
yourself. A workspace the Mac app controls is refused (`writerBusy`) unless the
client resumes with `takeover`.

From any terminal, `swroam [-i KEY] [user@]host` bootstraps over SSH and then
follows the session over QUIC through network changes and sleep, like mosh,
but drawing the host's authoritative screen with no local prediction. It
accepts OpenSSH Ed25519 keys (default `~/.ssh/id_ed25519`, passphrase
prompted) or a password, and asks once about an unknown host key before
raw mode; reconnects never prompt. Trusted keys live in
`~/Library/Application Support/swroam/known_hosts.json`. In the session,
Ctrl-^ `.` detaches (printing the `swroam -r ID host` to resume), Ctrl-^ `k`
terminates the shell, and Ctrl-^ Ctrl-^ sends Ctrl-^.

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

The roaming clients are one universal-purchase app, `dev.chr33s.swiftty`
([Apps/project.yml](Apps/project.yml)). Swiftty.app is the Mac terminal and
host; Mac users reach remote sessions through the Catalyst build.
[`Apps/ci_scripts/ci_post_clone.sh`](Apps/ci_scripts/ci_post_clone.sh) prepares
Xcode Cloud and lists the workflow environment. Create one Xcode Cloud product
pointed at `Apps/Swiftty.xcodeproj` and one workflow with an archive action per
platform, each with a TestFlight post-action:

| Scheme | Archive platform |
|---|---|
| `MobileClient` | iOS |
| `CatalystClient` | macOS |
| `VisionClient` | visionOS |
| `TVClient` | tvOS |

tvOS and visionOS layered icons are regenerated from `icon.svg` with
`xcrun swift Scripts/gen-platform-icons.swift`.

Swiftty.app is unsandboxed (it owns local PTYs) and is distributed with
Developer ID through [`.github/workflows/release.yml`](.github/workflows/release.yml),
whose header lists its triggers, variables and secrets.

### Connecting a device

[spec.connection-setup.md](spec.connection-setup.md) covers pairing: on the Mac,
**Terminal Service › Connect a Device…**; on the iPhone or iPad,
**Settings › Connect to Mac**. SSH and roaming use
[separate addresses](spec.connection-setup.md#5-two-addresses-ssh-then-roaming),
and clients bootstrap over SSH before attaching to the pinned QUIC endpoint
([spec.inbox.md §1.2](spec.inbox.md#12-bootstrap-helper),
[§1.8](spec.inbox.md#18-quic-pin)). The apps are generated with XcodeGen:

```sh
Scripts/build-platforms.sh   # iOS, Catalyst, visionOS, tvOS, watchOS, swifttyd
mise exec -- swift test --filter "ProtocolTests|IntegrationTests"
```

`IntegrationTests/EndToEnd` runs the real registry, PTY, QUIC listener, pinned
client and a presentation-mode display, with and without an in-process SSH
server. Simulator, device and fixture runs (each script's header lists its
options):

```sh
Scripts/test-roaming-simulator.sh <ios-or-ipad-udid> [iOS|tvOS|visionOS]  # client in the simulator vs a real roaming SwiftMux agent
Scripts/test-companion-watch.sh <watch-udid>                             # companion tests hosted by the watch app
Scripts/test-real-ssh.sh                                                 # real OpenSSH (apple/container Linux VM) + real swifttyd
Scripts/test-app-ui.sh '<xcodebuild destination>' [xcodebuild args]      # XCUITest of a client app vs real OpenSSH + swifttyd
Scripts/test-keychain-signed.sh '<destination>' [team-id]                # signed, app-hosted Keychain test
Scripts/test-handover.sh <iphone-udid> [switches] [team-id]              # A2: one session kept open across Wi-Fi toggles
```

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

Later connection-setup runs are recorded in
[spec.connection-setup.md](spec.connection-setup.md#6-acceptance-evidence);
open device validation is tracked in
[todo.md](todo.md#platform-and-release-validation).

QUIC connection migration: clients enable it (`multipathServiceType =
.handover`), but Network framework's QUIC listener on the OS 27 SDK keeps
replying to a client's old address, so a path change ends in reattachment to
the retained session instead (spec §9 fallback). `MigrationTests` documents
the listener behaviour and `RoamingEndToEndTests` checks recovery to the same
shell with each command applied once.

### SSH keys and iCloud sync

[spec.ssh-identity.md](spec.ssh-identity.md) defines SSH keys as reusable
identities: Ed25519 or ECDSA (P-256, P-384, P-521) generation and import in
**Settings › SSH Keys**, device-bound P-256 keys in the Secure Enclave
(optionally requiring Face ID, Touch ID or the passcode), Keychain storage
policies, fail-closed sign-in, CloudKit metadata sync and account changes. Add
the shown public key to `~/.ssh/authorized_keys` on the Mac yourself. A
password can be saved in the device's Keychain from the sign-in prompt; it is
offered only to the same host, port and username, and removed if rejected. RSA
and keyboard-interactive authentication are unsupported because SwiftNIO SSH
lacks them (spec.ssh-identity.md §13.4).

**Settings › Connection** controls ordinary SSH recovery
([spec.roaming.md §9.1](spec.roaming.md#91-ordinary-ssh-recovery-and-transport-options)):
a dropped connection opens a new shell in the same screen, in bounded bursts
then once a minute, and says the previous shell was not resumed. Health checks,
TCP keepalive and an IPv4-only option apply to every SSH connection. **Settings › iCloud Sync** appears only when the clients are
generated with `SWIFTTY_CLOUDKIT_CONTAINER` set to a provisioned container
(`Scripts/configure-links.sh`). Interrupted iCloud key operations are listed
under **Key Removals Needing Review** and **Keys Needing Account Review**, and
returning to the foreground retries them even when metadata sync is off.
Migrating a version-1 `hosts.json` keeps the original as `hosts.v1.json`.

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
idle; [spec.scrollback.md](spec.scrollback.md) defines the representation,
borrowing and scan contracts, scheduling, platform policy and failure policy.
`TerminalState.scrollbackStatistics` reports logical, resident, compressed,
metadata, workspace, protected, eligible and reclaimed bytes from metadata
alone; `scrollbackCompression` reports the requested and effective policy with
the fallback reason.

Snapshot spans borrow the snapshot. Retaining a snapshot preserves its cells
while later frames reuse other pool entries. Grapheme ids belong to the snapshot
that produced the cell; passing a cell from another snapshot to
`graphemeScalars(_:)` is invalid even when the numeric id happens to match.

`SWIFTTY_INTERNAL_CHECKS` (`mise run test-internal`) validates row ownership,
ring bounds, blank extents, grapheme references, and wide-cell structure at
completed parser batches and storage bounds after mutations. Checks and their
scratch storage are absent from normal builds. Storage benchmarks vary size and
ring layout, exclude setup from timing, and report consumed results alongside
nanoseconds per operation; run them in Release without internal checks.

## JavaScript automation (macOS)

At launch, Swiftty provisions `~/.config/swiftty/config.js`, `jsconfig.json`
and `swiftty.d.ts`; open that directory in a JavaScript/TypeScript-aware editor
for completion and type checks. [spec.javascript.md](spec.javascript.md)
defines the runtime, the `swiftty` API (filters, panes, shortcuts, UI, JSONC
data), lifecycle events including OSC 7501 changes, and an
[example](spec.javascript.md#54-consumer-example).

## Kitty graphics

Swiftty implements the kitty graphics protocol with Ghostty `167acf0c` as the
oracle ([spec.graphics.md](spec.graphics.md)). Sixel is not supported.

| Path | Status |
|---|---|
| Engine | APC `G` commands, every action and delete target, chunking, RGB/RGBA/PNG, zlib, file/temp-file/shared-memory media for local programs, eviction, relative and virtual placements, Unicode placeholders, animation, region scrolls, reflow, checkpoints (section 15) |
| Direct sessions (Mac, iOS/iPadOS) | Metal image layers (below backgrounds, below text, above text), texture cache with memory-warning trimming, animation clocked by the view while visible; Reduce Motion holds animations; VoiceOver elements "Image, *c* by *r* cells" |
| SwiftMux panes (every app window) | Pane pixel geometry and `TIOCGWINSZ` pixels, the frame `images` section (SMXB tag 19) with animation frame sets for prefetch, pixels fetched with `imageChunk`, animations ticked on the pane queue |
| RST/1 roaming | `kittyGraphics` feature, `KGIB/1` image records (PNG; reduced variant PNG or HEIC), digest inventory and aliases across reattachment, `ImageRequest`, prefetched animation frames, 2 images/s after a burst of 8; with images off, boxes that load on tap (`ImageLoad`) |
| `swroam`, `swmux` | Outer-terminal detection, Unicode-placeholder re-emission (tmux passthrough when `$TMUX` is set), half-block fallback; `swroam --graphics auto\|kitty\|halfblocks\|off` |

Settings: `terminal.image_storage_limit` (bytes per screen; default 320 MB on
macOS, 128 MB on iOS and iPadOS; 0 disables images; SwiftMux panes cap it at
256 MB and read it when the service or a workspace worker starts) and
`terminal.images_on_cellular` (Ghostty-style key `images-on-cellular`: `full`,
`reduced` (default) or `off`) for roaming on expensive paths; Low Data Mode
always uses reduced images.

Inside tmux, programs that use Unicode placeholders (`kitten icat
--unicode-placeholder`, yazi, timg, chafa) draw through passthrough:

```tmux
set -g allow-passthrough all
set -as terminal-features ',xterm-256color:RGB:usstyle'
```

tmux 3.4–3.8 drop the placeholders' diacritics when drawing new output, so an
image may show only its first row, or not appear, until tmux redraws the pane:
run `tmux refresh-client`, zoom, or switch windows. Directly placed images
(`a=T` without `U=1`) land at the outer cursor under tmux and are not supported
there. Swiftty supports the protocol in its own
engine only; tmux's own width tables decide how it lays out placeholder cells.

Tests: about 209 of Ghostty's kitty graphics tests ported with Ghostty's
values (`GhosttyOracle/KittyGraphicsOracleTests.swift`); the real `kitten
icat` (stream, file, memory and placeholder modes), timg, chafa, yazi and
image.nvim on a real PTY (`KittyRealProgramTests`, each skipped when not
installed); tmux 3.4, 3.5a, 3.6a, 3.7c and 3.8 with the configuration above;
and device runs on an iPad Pro and iPhone 16
(`Scripts/test-ipad-frame-time.sh <udid> <team>`).

Measured 2026-11-24, Release, against the gates in
[spec.graphics.md §26.4](spec.graphics.md#264-gate-measurements-2026-11-24-apple-silicon-release):

| Benchmark | Mac (Apple Silicon) | iPad Pro 12.9″ (M1) | iPhone 16 |
|---|---|---|---|
| kitty's Images payload, against Ghostty `167acf0c` (gate 95%) | 103.7–105.2% | | |
| 3840×2160 RGBA transmit, against Ghostty (gate: at most 1.1× its time) | 100.7% | 34.7 ms | 22.4 ms |
| 2000×2000 PNG decode, p95 | 23.1 ms (gate 25) | 34.6 ms (gate 60) | 26.9 ms |
| 33 MB texture upload frame | 4.9 ms (8.33 ms at 120 Hz) | 7.2 ms (8.33 ms at 120 Hz) | 8.6 ms (16.7 ms at 60 Hz) |
| Placeholder screen while typing, against ASCII (gate 1.10) | 1.03–1.06 | 1.03–1.05 | 1.04 |
| 381 MB file medium (bound 250 ms) | 20.9 ms | | |

Paired runs against the parent commit show every text workload at 99.2–101.2%
of its throughput. The later comparison below (2026-11-25) puts kitty's Images
payload at 114.9% of Ghostty's throughput and `transmit-4k` at 109.2%.
`Scripts/compare-ghostty.py` now also generates the
`transmit-4k` input. Roaming across networks: an iPhone 16 switched between
Wi-Fi and cellular through 20 reattachments with an image on screen, and no
image it held was sent again (`Scripts/kg28-image-resends.sh`: 18 aliases,
0 resends).

## Configuration

Swiftty reads JSONC configuration;
[spec.md](spec.md#jsonc-format-and-discovery) defines file discovery,
[diagnostics](spec.md#parsing-and-diagnostics), the
[typed model](spec.md#typed-model-and-editor-schema) and
[saving](spec.md#serialization-and-required-coverage). `schema.json` provides
editor completion. Settings (Cmd-,) edits the selected file; Edit
Configuration File (Opt-Cmd-,) opens it and Shift-Cmd-, reloads it. iOS reads
`Documents/config.jsonc`. Accessibility preferences adjust presentation
without changing the file ([spec.apple.md](spec.apple.md#a05--accessibility-preferences-ui-01-ui-02-cfg-04)).

Select a shell for new sessions in **Settings › Shell** or set
`terminal.preferred_shell` to `system`, `bash`, `zsh`, `swsh`, or `custom`.
Omitting it preserves the existing command and `terminal.shell` behavior.
Profiles retain their settings when you change the selection:

```json
"terminal": {
  "preferred_shell": "swsh",
  "shell_profiles": {
    "bash": { "arguments": ["--login"] },
    "zsh": { "arguments": ["-l"] },
    "swsh": { "environment": { "EDITOR": "vim" } },
    "custom": {
      "executable": "/opt/homebrew/bin/fish",
      "arguments": ["--login"],
      "working_directory": "/tmp"
    }
  }
}
```

Arguments are passed literally. Set login or interactive flags explicitly;
the `system` profile retains the default login-shell policy. Profile environment
values override the frontend snapshot; SwiftMux still supplies terminal identity
variables. A selected profile applies to future workspaces, tabs, and splits;
running sessions keep their launch settings. The app bundle includes and signs
`swsh` alongside its other executables.

Themes use JSONC too. Place a file such as `Night.jsonc` in
`~/.config/swiftty/themes` and set `"theme": "Night.jsonc"`, or give an
explicit path. Built-in themes are `Swiftty Dark` and `Swiftty Light`; omitting
`theme` follows the system appearance. On macOS these use native system text,
background, selection and ANSI colors, including the system selection accent.
Other platforms use an Apple-colored light/dark palette. The terminal defaults
to 95% opacity over native glass; Reduce Transparency makes it fully opaque.

Programmatic embedders can still set renderer/session properties directly,
including font features, palette overrides, shader paths and command arguments.

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

These are Release measurements on Apple Silicon; lower times are better.
Physical iPad frame time and the centered onscreen comparison date from
2026-10-10; earlier probes are identified below. Later shared-surface device
results are in [spec.apple.md](spec.apple.md#shared-surface-device-validation--2026-11-01).

### Swiftty vs Ghostty

Parser and terminal-state throughput on an Apple M5 Max (18 CPU cores, 128 GiB),
measured 2026-11-25: Ghostty `167acf0` (upstream HEAD), Zig 0.17.1 ReleaseFast,
versus Swift 6.4.2 Release (`ea13282`). Each binary read the same ~100 MiB
files in 64 KiB chunks at 120×80. Times are median CPU time (user + sys) of
each process, including startup and file reads; relative throughput by wall
time, recorded alongside, is within 1% of these except on
`kitty-long-escape-codes` (4.5 points lower), `transmit-4k` (2.4 points lower)
and `ghostty-ascii` (1.1 points lower). Each input had two warmups and 20
rounds in a balanced (Williams) order, so every variant ran in each position
and after each other variant equally often. Intervals are paired bootstrap 95%
intervals. The 1-minute load average stayed between 1.3 and 2.9.

The inputs are ten Swiftty generators, four `ghostty-gen` generators, all six
of kitty's `kitten __benchmark__` payloads, built from kitty's source at
`fb99338` and repeated as the kitten sends them on the alternate screen, and
`transmit-4k`. kitty's Images payload is a 1024×1024 RGBA kitty graphics
transmission in 4096-byte chunks followed by its delete; `transmit-4k` repeats
a 3840×2160 RGBA transmission and delete (spec.graphics.md §21.3).

Ghostty's `terminal-stream` raises its 10,000-byte scrollback limit to two
215-row pages, up to 350 history rows at 120×80; Swiftty applies 10,000 bytes
literally (5 rows). "Matched" gives Swiftty 350 rows (672,000 bytes) and is the
like-for-like comparison. kitty's payloads use the alternate screen, so history
does not apply to them.

With matched history Swiftty was faster on 19 of 21 inputs, from 1.4% on
`utf8-cjk` to 2.1× on `kitty-unique-unicode`, and slower on `cat-source`
(92.5%) and `ascii` (88.9%); the nominal limit gives the same split, at 95.0%
and 91.2%. On those two, short lines of plain ASCII, most of the remaining
difference is per line: blanking the cells a reused row's previous line left
past the new one, and the line feed's bookkeeping. Cell size is not most of
it: a prototype with 8-byte cells, which dropped colours and links, was only
3–11% faster on the ASCII inputs.

Since the previous run, earlier on 2026-11-25
([samples](Benchmarks/Ghostty/compare-2026-11-25.json)), with the same inputs
and Ghostty build, Swiftty's matched times fell by 19.4% on `utf8-latin`,
17.1% on `kitty-long-escape-codes`, 14.9% on `ascii` and `ghostty-ascii`,
13.2% on `scroll`, 11.7% on `cat-source` and 9.0–9.6% on `transmit-4k`,
`compiler-log`, `kitty-images` and `osc-heavy`, and moved by −5.9% to +0.6%
elsewhere, except `kitty-unique-unicode` (+3.0%):

- Printable ASCII is stored with NEON (`Sources/CTerminalSIMD`): sixteen bytes
  are widened in vector registers and `vst4q` writes four cells per store.
  Swift's generic SIMD conversions compiled to calls there, and building each
  cell moved its byte through a general register.
- The escape-sequence payload scanners (OSC, DCS and APC, which carries kitty
  graphics) are NEON too: `pointwiseMin` and `any` compiled to calls.
- Runs of narrow scalars below U+0300 other than © and ® are stored eight at
  a time. The check runs out of line and is retried only after a long run,
  which costs text with combining marks about 3% (`kitty-unique-unicode`).
- A full-screen scroll moves a window over a row-map buffer eight screens
  long instead of shifting every screen row's entry; the scrollback ring no
  longer divides on each push.

On 5 November, against Ghostty `5dc28bb`, Swiftty led on all 19 inputs then
measured ([samples](Benchmarks/Ghostty/compare-2026-11-05.json)). Ghostty's
time has since fallen on 17 of them, by 5.4% (`kitty-long-escape-codes`) to
78.4% (`osc-heavy`, 1241 to 269 ms): bisecting its first-parent merges, most
of that is `dc8f59943` (new pages keep the capacity recent pages needed: OSC 8
input no longer reallocates pages) and `091beb992` (ASCII printed from the
input bytes, as Swiftty already did). Neither had a Swiftty counterpart to
port. In the round before this one, measured against the same Ghostty build
([before](Benchmarks/Ghostty/compare-2026-11-24.json),
[after](Benchmarks/Ghostty/compare-2026-11-25.json)), Swiftty's matched times
fell on `osc-heavy` (377.1 to 278.2 ms), `ghostty-ascii` (62.1 to 46.9),
`kitty-ascii` (166.6 to 133.9) and `compiler-log` (109.9 to 103.3), and moved
by −1.9% to +3.5% elsewhere:

- Soft wraps and bare line feeds no longer blank a recycled row before the
  next line overwrites it, on either screen, and tabs no longer force those
  pending clears; CR LF already deferred.
- OSC titles, directories and link targets compare bytes with `memcmp`, not
  generic `elementsEqual`; the link table indexes its hashes in an
  open-addressing table instead of `Dictionary`.
- OSC 133 ; B no longer copies the whole `TerminalState` to find the
  cursor's line, and clears the previous input-line flag without scanning
  the screen and history.
- An OSC's command prefix is copied in runs; the printable-ASCII scan finds a
  line's end from the vector mask instead of a scalar loop.

Relative throughput is `Ghostty time / Swiftty time`.

| Input                   |   Ghostty |   Swiftty | Relative (95% CI)     |   Matched | Relative (95% CI)     |
| ----------------------- | --------: | --------: | --------------------- | --------: | --------------------- |
| ascii                   |   66.7 ms |   73.1 ms | 91.2% (90.6–91.5%)    |   75.0 ms | 88.9% (88.2–89.1%)    |
| cat-source              |  117.1 ms |  123.2 ms | 95.0% (94.8–95.5%)    |  126.6 ms | 92.5% (92.2–92.7%)    |
| compiler-log            |  102.3 ms |   92.6 ms | 110.5% (109.9–110.9%) |   93.5 ms | 109.4% (109.0–109.7%) |
| csi-heavy               |  368.0 ms |  216.6 ms | 169.9% (169.2–170.4%) |  216.8 ms | 169.8% (169.1–170.6%) |
| osc-heavy               |  267.2 ms |  239.5 ms | 111.6% (110.9–112.6%) |  253.3 ms | 105.5% (104.7–106.1%) |
| scroll                  |  323.0 ms |  258.9 ms | 124.8% (123.4–125.3%) |  257.5 ms | 125.4% (123.6–126.2%) |
| unicode-joins           |  514.9 ms |  340.6 ms | 151.2% (150.8–151.9%) |  351.4 ms | 146.5% (146.3–146.9%) |
| utf8 (mixed scripts)    |  252.6 ms |  220.2 ms | 114.7% (114.3–114.9%) |  221.6 ms | 114.0% (113.6–114.3%) |
| utf8-latin              |  118.3 ms |   97.3 ms | 121.6% (120.9–122.2%) |   98.4 ms | 120.3% (119.7–120.9%) |
| utf8-cjk                |   89.7 ms |   87.8 ms | 102.2% (101.6–102.7%) |   88.4 ms | 101.4% (100.5–101.9%) |
| ghostty-ascii           |   40.6 ms |   39.4 ms | 103.1% (102.7–103.8%) |   39.9 ms | 101.7% (101.3–102.4%) |
| ghostty-osc             | 1368.6 ms | 1226.6 ms | 111.6% (111.2–111.9%) | 1229.1 ms | 111.3% (110.9–111.8%) |
| ghostty-styled          |  211.6 ms |  172.8 ms | 122.5% (122.1–122.7%) |  173.9 ms | 121.7% (121.6–121.8%) |
| ghostty-utf8            |  555.8 ms |  387.3 ms | 143.5% (143.2–144.0%) |  389.3 ms | 142.8% (142.6–143.3%) |
| kitty-ascii             |  142.9 ms |  126.4 ms | 113.0% (112.7–113.6%) |  126.7 ms | 112.8% (112.6–113.5%) |
| kitty-unicode           |   97.6 ms |   85.5 ms | 114.1% (113.6–114.6%) |   85.5 ms | 114.2% (113.8–114.5%) |
| kitty-unique-unicode    |  610.6 ms |  292.4 ms | 208.9% (207.9–210.0%) |  292.6 ms | 208.7% (207.9–210.0%) |
| kitty-csi               |  322.9 ms |  266.0 ms | 121.4% (120.4–122.0%) |  264.4 ms | 122.1% (121.7–122.6%) |
| kitty-images            |   30.4 ms |   26.5 ms | 114.8% (114.2–115.9%) |   26.5 ms | 114.9% (113.9–116.2%) |
| kitty-long-escape-codes |   13.1 ms |   10.4 ms | 126.2% (125.7–130.6%) |   10.4 ms | 126.2% (125.5–131.7%) |
| transmit-4k             |   36.4 ms |   33.2 ms | 109.5% (108.6–110.0%) |   33.3 ms | 109.2% (108.6–110.2%) |

Caveats:

- Upstream `ghostty-bench` logs warnings to stderr while timed. At `167acf0`
  a build with `log_level = .err` was 31.3% faster on `ghostty-utf8` and 3.7%
  on `ghostty-osc`, and within 3.2% on the rest. Against it, matched Swiftty
  is at 108.7% on `ghostty-utf8`, 107.3% on `ghostty-osc` and 104.1% on
  `osc-heavy`; the other inputs keep the split above.
- Final states are not compared. OSC 8 links follow Ghostty's rules: an `id=`
  parameter and the URI identify a link, every other OSC 8 opens a link of
  its own, and URIs are kept whole. Swiftty keeps them in one table for both
  screens, stores each distinct URI once, and labels at most 1,048,575 live
  links.
- `ghostty-gen +ascii` and `+osc` are unseeded and `cat-source` concatenates
  this repository's sources; compare input hashes across runs. This run
  reused the corpus of the two runs before it.
- Median peak RSS on text inputs: Swiftty 7.7–11.1 MiB, Ghostty 9.7–11.1 MiB.
  On graphics inputs Swiftty peaked at 12.3 MiB (`kitty-images`) and 39.8 MiB
  (`transmit-4k`), Ghostty at 87.6 and 105.9 MiB.

Raw samples, input and binary hashes, load averages and toolchain versions are
in [Benchmarks/Ghostty/compare-2026-11-25-2.json](Benchmarks/Ghostty/compare-2026-11-25-2.json).
To reproduce:

```sh
# In the Ghostty checkout:
zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
# In this repository (also builds swiftty-bench in Release):
mise run compare <ghostty-src> <corpus-dir> --generate
```

`--generate` writes the inputs (`ghostty-gen` runs `+ascii`, `+osc`,
`+styled --seed=42 --style-rate=0.3` and `+utf8 --seed=42`) and downloads
kitty's benchmark source at the pinned commit (`--no-kitty` skips it).
`--metric wall` switches the headline metric; `--ghostty-quiet <src>` adds the
log-suppressed build.

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
then-current core's 120×40 offscreen full redraw at p50 1.580 ms and p95
2.930 ms (20 warmups, 220 frames). Dense search highlights measured p95
3.030 ms (five warmups, 35 frames). GPU completion was awaited; both tests
passed.

### Onscreen probes

The current Swiftty AppKit view in a Release probe was compared with Ghostty
1.3.1 (15212) on the same M5 Max display. Both used Menlo 13, an 80×24 PTY,
blinking disabled and the same raw-PTY response script.

Three serial alternating pairs posted synthetic keys to trigger alternating
black/white backgrounds. The same independent ScreenCaptureKit observer detected
these changes through a 32×32 crop at the display center, requesting 120 capture
frames/s. Each run used 20 warmups and 100 measured responses; all 720 were
observed. Ranges span runs.

| Terminal      |              p50 |              p95 |
| ------------- | ---------------: | ---------------: |
| Swiftty       | 16.683–16.983 ms | 23.461–24.919 ms |
| Ghostty 1.3.1 | 18.574–21.319 ms | 24.665–25.661 ms |

Median paired p95 difference was −0.742 ms (Swiftty minus Ghostty). This
measures synthetic key-to-captured-pixel delivery, including capture overhead;
physical-keyboard, glyph-typing and photon-level latency have not been measured.

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
Newer hosted simulator and iPad counts are recorded in
[spec.apple.md](spec.apple.md#shared-surface-device-validation--2026-11-01).

The earlier macOS Debug/Release baseline passed 1,156 tests. Added keypad-mode
coverage and 86 AppKit checks passed in both configurations. The hosted
simulator passed 171 mobile tests. The physical iPad build tested then passed
169 correctness tests and two separate frame-time tests. Release builds passed
for visionOS and Mac Catalyst.

Coverage includes Unicode batching, recorded sessions, shader classification,
visibility/opacity recovery, animation suspension, momentum cancellation and
accessibility. Native probes verified drawable recovery and draw
suspension/restoration on both platforms. UI automation passed shell typing
and Find navigation, highlighting, query/terminal focus and accessory-bar
restoration, including narrow windows and resizing.

Physical keyboard, Find, VoiceOver, link navigation and browser-return redraw
checks passed on both devices; macOS also passed interactive `vim`/`less`,
resizing and scrolling. User checks passed blur and corrected static/animated
shaders on both devices. Scripted and hands-on USB shell checks with `vim`,
`less`, `tmux` and `top` passed on the physical iPad. The user reported typing
and scrolling equally responsive alongside Ghostty in the two-drawable Mac
build. Battery consumption has not been measured.
