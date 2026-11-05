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
mise run test-internal # the same, with storage and terminal invariant checks
mise run bench      # Release microbenchmarks; bench-storage for storage scaling
mise run lint
mise run format     # format-check also validates documentation comments
```

Packaging and installation are under [SwiftMux](#swiftmux); the Ghostty
comparison is under [Measured results](#measured-results).

The native host runs tests serially because suites share AppKit state and use
blocking dispatch handoffs. Each manifest test bundle must exist and report a
complete run. A missing or failing bundle fails the command; later bundles still
run so their diagnostics are available. Completion is audited separately for
each bundle. Allocation budgets run only with optimized code;
`Scripts/test-native.sh -c release` checks them alongside the rest of the suite.

Use Xcode's Swift 6.4 toolchain, as CI does; `mise.toml` pins the other
tools but not Swift, because swift.org toolchains bundle a Swift Testing runtime
that conflicts with Xcode 27.2's and stops `Scripts/test-native.sh` from
finding tests. CI and release builds use the GitHub-hosted `xcode-27` runner
(Apple Silicon, macOS 27, Xcode 27 / Swift 6.4 or newer) and enforce
`Package.resolved`; the shared setup action selects the newest installed Xcode,
verifies the toolchain and installs ripgrep and tmux for native tests.
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

[spec.shell.md](spec.shell.md) defines the native `swsh` shell: batch
execution, scalar state and builtins, external and builtin pipelines, ordered
redirects, interactive editing/history, Darwin job control, literal `exec`,
functions, subshells, command substitution, native programmable completion,
app shell profiles, and bundled packaging. None of it aims at Bash
compatibility. The spec's
[acceptance matrix](spec.shell.md#failure-focused-verification-matrix) and
[implementation record](spec.shell.md#10-implementation-record) hold test
coverage, recorded run scope, benchmark provenance, deliberate language limits
and remaining gaps.

```sh
swift build --product swsh
swift run swsh -c "name='two words'; /usr/bin/printf '<%s>\\n' \$name"
swift test --filter SwshTests
python3 Scripts/test-swsh.py "$(swift build --show-bin-path)/swsh"
```

`Scripts/test-swsh.py` includes the failure-focused tests: nested child cleanup
and descriptor inventories, source-worker payload validation, function/subshell
interactions, and completion-provider contracts.

The batch CLI accepts `-c source`, one source-file path, or source on nonterminal
stdin. Source must be UTF-8 without NUL. Single quotes preserve all bytes between
them. Double quotes expand variables; a backslash escapes `$`, `"`, `\`, or a
newline there, and remains literal before other characters. Outside quotes a
backslash quotes the next character; backslash-newline continues a line. Unquoted
`#` starts a comment at a word boundary. `$NAME`, `${NAME}`, and `$?` expand to one
scalar argument, including an empty argument for an unset variable. Expansion
never splits values or interprets their wildcard bytes. Only source-authored,
unquoted `*` and `?` glob; unmatched patterns and ambiguous redirect targets are
errors. Matches sort by byte order.

Prefix `NAME=value` assignments see the pre-command state. Assignment-only
commands commit together; external-command prefixes form temporary environment
overlays. Builtin prefixes are errors. The fixed builtins are `cd`, `pwd`,
`export`, `unset`, `exit`, `exec`, `return`, `complete`, `:`, `true`, `false`,
`jobs`, `fg`, and `bg`.
`cd` uses a physical cwd and defaults to `HOME`; `pwd` accepts no options. `export NAME` exports the current
scalar (empty if unset); `export NAME=value` sets and exports it. `unset` removes
both value and export status. `exit` accepts one optional integer from 0–255,
defaulting to the last status. External commands resolve through `PATH`, or use
an explicit path containing `/`. There is no executable-format fallback.

`exec program args` replaces the current shell image through Darwin SETEXEC,
preserving its PID, cwd, process group, and inherited descriptors. In a pipeline
or background worker it replaces only that worker. This initial contract rejects
prefix assignments, redirections, and exec without a program. Main-shell exec
requires owned jobs to have finished first, so replacement cannot abandon their
supervisor. Failed lookup or replacement returns 127/126 and allows subsequent
commands; interactive failure restores the editor on the next prompt. Successful
replacement resets child signal dispositions/masks and closes private descriptors.

Lists support newline, `;`, `&&`, and `||`. Pipelines stream through kernel pipes
and return the last stage's status, including 126/127 lookup failures. Signals map
to `128 + signal`. Redirects `<`, `>`, `>>`, `<&`, and `>&` apply left to right
after pipeline wiring; descriptor duplication accepts a number or `-` to close.
Parse/expansion errors return 2, redirect-open failures 1. Redirects also apply
to missing/inaccessible-command diagnostics; a redirect failure takes precedence
over the pending lookup status. Private launch payloads
are bounded to 8 MiB and validated against the exact executable hash. Shutdown
signals owned children, escalates external processes after two seconds, and fails after five seconds
if cleanup remains incomplete. Source workers retain their child-supervision lease
while reaping descendants; the parent avoids killing those reapers prematurely.
The lease closes on exec, so replacement programs remain subject to escalation. Batch mode keeps the inherited process group and
never signals that shared group during cleanup. Direct terminal sessions and mux
pane termination give the outer shell five seconds before forcing it to exit,
allowing shell-owned job cleanup to finish. Closing a mux frontend window still
detaches that frontend; explicitly ending a pane initiates shell shutdown.
For direct PTY hosts that create a session without assigning its controlling
terminal, interactive `swsh` claims the attached slave only when it is the session
leader and has no controlling terminal. Nested shells retain the foreground-wait
policy and cannot use this path to take another session’s terminal.

With terminal stdin, or explicit `-i`, `swsh` reads `~/.swshrc` once and starts
its editor. Ctrl-C cancels the edit, Ctrl-D at an empty prompt exits, Ctrl-U clears
the line, Ctrl-W removes the last word, and up/down arrows browse history.
Editor input uses a separate nonblocking terminal handle so Ctrl-C flushing
cannot leave a stale readiness event blocked in read. Idle batch source input
also checks shutdown while waiting for bytes. Bracketed paste inserts source
without submitting embedded newlines. Tab completes
simple unquoted command/path words; quoted or expanded words are left unchanged.
History uses a separate mode-0600 `~/.swsh_history` JSON-lines file, bounded to
1 MiB and 1,000 entries; individual submissions over 64 KiB are not persisted.

### Functions and programmable completion

- `name() { commands; }` defines or replaces a function, retaining its exact body
  source. Definitions are standalone, without redirects or `&`, and cannot replace
  fixed builtins. Lookup is explicit path, builtin, function, then PATH. A foreground
  standalone call runs in the current shell: assignments, exports, function definitions,
  completion registrations, and `cd` persist. Prefix assignments to functions are
  rejected. `$1` through `$9` and `$#` are scalar parameters; nested calls restore the
  caller's parameters. `return [0..255]` ends only the current function, defaulting
  to the last status. `exit` retains its shell-exit meaning. Function recursion and
  parsed compound nesting are limited to 16 levels, including the top parser level.
- Function redirections use supervised descriptor handoff and explicitly scoped I/O;
  they do not replace the shell process's standard descriptors. State still persists.
  Parent function redirects support destinations 0, 1, and 2; other destinations
  require a subshell or pipeline worker so they have a real process FD namespace.
  `exec` inside a redirected function is rejected until descriptor replacement and
  failure restoration have a separate proof. Pipeline/background function calls run
  in source workers and cannot mutate parent state.
- `( commands )` runs an isolated logical snapshot in a fresh source worker, preserving
  the inherited cwd and ordered redirects. It supports pipelines, background execution,
  nesting, and function lookup. The worker joins its outer job's process group; its
  children inherit that group. It has its own sole reaper and retires its children on
  exit. Terminal stop/continue signals therefore reach the compound job. No Swift
  code runs between fork and exec. Worker nesting is bounded at 128 processes.
- `$( commands )`, also inside double quotes, starts a separately supervised expansion
  job. Each selected command expands assignments, words, and redirects once before
  launch; short-circuited commands do not expand. Output is drained while the worker
  runs, preserves arbitrary non-NUL bytes, removes trailing LF bytes, and contributes
  one scalar without splitting or value-origin globbing. Empty output is an empty
  scalar. A nonzero worker status, stopped substitution, NUL, or output above 1 MiB
  is an expansion error (status 2); a stopped/oversized producer is aborted and reaped.
  Completed substitution effects cannot be rolled back if a later expansion fails.
- Source workers receive exact body bytes and a value snapshot through the existing
  bounded, unlinked, exact-build payload file. They bypass startup/history/editor
  initialization and evaluate that body directly, without replaying already-expanded
  caller words. `exec` replaces the worker only and still refuses live owned jobs.
- `complete command candidate ...` registers literal candidates (zero candidates
  suppresses fallback). `complete --function command provider` registers an existing
  function. The provider runs in an isolated worker with `$1` equal to the current
  unquoted token and `$2` equal to the input line. It prints one full candidate per
  LF-delimited line. Candidates are prefix-filtered, deduplicated, UTF-8 checked,
  and escaped before insertion; they are never parsed as executable source. Providers
  get `/dev/null` stdin/stderr, no terminal handoff, a one-second execution deadline,
  a 1 MiB output limit, and bounded job cleanup. Failure offers no completion and
  preserves the shell's status/state. Timeout terminates only the provider job.
  Quoted/escaped/expanded input remains outside the initial editor completion contract.

```sh
greet() { /usr/bin/printf 'Hello, %s\n' $1; }
greet 'two words'
value=$(greet world)
(cd /; pwd) | /bin/cat
complete greet Alice Bob
names() { /usr/bin/printf 'Alice\nBob\n'; }
complete --function greet names
```

Pipeline and background builtins run in fresh process workers. Their variable and
directory changes do not affect the parent, and worker `exit` ends only that stage.
They receive expanded arguments and only the logical values the builtin reads;
they do not load startup files, initialize history, or recursively launch workers.
Job-control builtins (`jobs`, `fg`, `bg`) require the main session and are rejected
as worker stages before any pipeline child starts. Standalone stateful builtins
run in the parent with explicit I/O descriptors. A supervised private helper
opens their redirects and transfers the resulting descriptors over a local socket;
it never executes the builtin. The parent commits state only after setup succeeds,
including for assignment-only commands with redirects. FIFO setup can be cancelled
with Ctrl-C or session shutdown. Setup shares the parent shell’s terminal-stop
policy; it is not a separately stoppable user job. `exec` still rejects redirects.

`&` schedules pipelines. `jobs` displays live jobs; `fg` and `bg` accept
an optional numeric job ID (with or without `%`) and default to the newest live job.
Ctrl-Z returns a prompt once every live pipeline stage stops. A stop ends that
submission: commands after it are not replayed by `fg`. Foreground resume restores
the job's saved terminal modes before SIGCONT; background resume leaves editor
modes alone. OSC 7 and OSC 133 are passive display metadata emitted only through
the controlling-terminal handle; `SWSH_TERMINAL_METADATA=0` disables them.

Implementation and review checks cover Swift 6.4.1 and Apple Swift 6.4.2 with
Xcode 27.2 and macOS SDK 27.2.

Isolated PTY fault probes cover later-stage spawn failure, shutdown immediately
before group release, failed job-mode restoration before resume, and a simulated
missed cleanup deadline. A missed deadline remains a failure on repeated shutdown
calls. Batch stress checks cover completed-job retention, descriptor counts, and
reaping across background jobs and pipelines with synthetic lookup failures.

A session actor owns a dedicated serial executor; one synchronous command driver
mutates language state. An awaited async `defer` shields only bounded shutdown
and terminal restoration. Cleanup yields between nonblocking reaping checks and
shares the launch-abort state machine and its original deadlines. Isolated tests
cancel before and during cleanup, cancel a caller while its foreground job runs,
reject a second evaluator during cleanup, and inject final terminal-restoration
failure. Cleanup finishes before the caller receives its status, and restoration
failure overrides a requested successful exit with status 1.

Run `python3 Scripts/measure-swsh.py --output /tmp/swsh-measurements.json` for
release measurements. It builds a separate instrumented executable for allocation
counts and per-process peak RSS, keeping timing measurements uninstrumented.
The [2 November language-growth baseline](Benchmarks/Swsh/baseline-2026-11-02.json)
records 360 timing samples and allocation/RSS observations before the subsequent
nested-cleanup and stop/resume hardening,
including function calls, subshells, and command substitutions. Its hashes identify
exactly what was measured.

The [historical pre-review baseline](Benchmarks/Swsh/baseline-2026-11-01.json) contains raw samples,
source/binary hashes, dependency revisions, and exact compiler/SDK/host metadata.
On the recorded Apple M5 Max with 128 GiB RAM, 30 warm-cache timing samples gave:

| Workload | Median |
| --- | ---: |
| CLI startup and `:` exit | 4.38 ms |
| Private builtin worker startup, prewritten payload | 3.94 ms |
| Interactive first prompt, including PTY fixture setup | 9.41 ms |
| 16 MiB binary stream through three external pipeline stages | 147.6 MiB/s |
| 16 MiB stderr stream | 1,059.0 MiB/s |

After subtracting the median empty invocation, the measured amortized cost was
12.1 µs per parent builtin, 1.88 ms per builtin pipeline worker, and 3.30 ms per
parent-redirect helper. The worker figure includes two-stage concurrency and is
not an individual worker's startup latency. Instrumented runs observed a median
1,265 allocations across all threads and 6.66 MiB peak RSS for an empty invocation;
builtin workers observed 1,320 allocations and 6.52 MiB each. The report retains
initial-thread counts separately. Counts exclude allocations before the measurement
constructor and after its destructor, and RSS is
per process rather than the concurrent process-tree total. The measurements are
local observations, not regression thresholds or proof of an ownership-feature
speedup.

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
mise run package-swiftmux [identity]     # Swiftty.app with the bundled agent (SMAppService)
mise run install [--roaming]             # package, install to /Applications, register the agent (+ swifttyd)
Scripts/install-ios.sh --team TEAM       # iOS/iPadOS app on iPhones and iPads connected by USB
mise run uninstall [--purge] [-y]        # remove the app, agent and swifttyd
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

Host setup (spec.inbox.md §1): `swiftmux-agent` serves remote clients from
the same process as the native app when a roaming configuration exists at
`~/Library/Application Support/SwiftMux/roaming/config.json` (or
`--roaming-config PATH`, or `$SWIFTMUX_ROAMING_CONFIG`) with an explicit
`bindAddress`, `advertisedHost` and UDP `port` (51222 by default), plus an
optional `stateDirectory`. A relative state directory is resolved against the
directory of the selected configuration file, so the agent and SSH helper select
the same control socket independently of their working directories. A missing
default configuration disables roaming. A missing explicitly selected file, or
an unreadable or invalid configuration, exits with status 78 before the agent
starts its service. `--no-roaming` ignores the file; the last roaming option wins.
`--idle-exit SECONDS|never` sets the local idle exit, which roaming disables.
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
Developer ID. `.github/workflows/release-mac.yml` runs on the GitHub-hosted
`xcode-27` runner for a pushed `v<version>` tag (or manually, as a
`mac-v<version>-<build>` prerelease): `Scripts/package-swiftmux.sh` builds and
signs it, then `Scripts/release-mac-github.sh` notarizes it (`Scripts/notarize.sh`,
shared with the package and install scripts) and uploads a zip and SHA-256 to
the release, or to an existing draft for the tag. The workflow imports
the Developer ID certificate and private key into a temporary keychain from the
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

`SWIFTTY_INTERNAL_CHECKS` (`mise run test-internal`) validates row ownership,
ring bounds, blank extents, grapheme references, and wide-cell structure at
completed parser batches and storage bounds after mutations. Checks and their
scratch storage are absent from normal builds. Storage benchmarks vary size and
ring layout, exclude setup from timing, and report consumed results alongside
nanoseconds per operation; run them in Release without internal checks.

## JavaScript automation (macOS)

At launch, Swiftty provisions `~/.config/swiftty/config.js`, `jsconfig.json`
and `swiftty.d.ts`. The declaration file updates with the app; existing scripts
and editor configuration are preserved. Open this directory in a JavaScript /
TypeScript-aware editor for completion and inline type checks. Node.js and npm
are not required by the application.

The persistent SwiftMux service evaluates the script once before its first
pane starts. Script edits take effect in the next service process; closing and
reopening a window does not restart that service or reload JavaScript. The
ordinary configuration reload command below applies to the active terminal
configuration file; JavaScript reloads separately.

The global `swiftty` provides stdin/stdout filters, environment lookup, managed
pane writes/splits/closes, shortcuts, dock badges, tab labels, native notifications
and left/right status items. Status renderers run once when registered, on manual
refresh, and optionally at a polling interval. Native notifications use macOS
notification permission and require the packaged application.

Lifecycle hooks have separate protocol sources:

- `events.onCommandFinished`: OSC 133 completion, with the command text when
  available and `-1` for an unavailable exit status.
- `events.onDirectoryChanged`: OSC 7 directory changes.
- `events.onStatusChanged`: validated OSC 7501 reports, removals, resets and
  authoritative resync snapshots from the same journal as the attention inbox.
  Each event identifies its pane and terminal epoch. `currentPane` refers to
  the source pane during these callbacks.

```js
swiftty.events.onStatusChanged(change => {
  if (change.type === "report" && change.record.state === "blocked") {
    swiftty.ui.setTabIcon("⏳");
    swiftty.ui.notify(change.record.title || "Program needs attention",
      change.record.message || "Waiting for input");
  }
});
```

Filters operate on individual UTF-8 chunks, so a match spanning chunks requires
state in the script. Invalid/incomplete UTF-8, throwing filters and results over
host byte limits pass through unchanged. Streamed pastes filter their payload
while preserving the writer's paste framing and sanitization. Script errors are
logged; one failing event listener does not prevent the others from running.
Automation scripts can read JSONC data using the same parser as terminal
configuration: `swiftty.jsonc.read("automation.jsonc")` loads a file beside
`config.js`, and `swiftty.jsonc.parse(text)` parses a string. Comments and trailing
commas are supported, with source-position diagnostics. Reads are synchronous
and limited to 1 MiB; load settings at startup. Data uses JavaScript number
precision and is never executed. Callback functions remain in `config.js`.

See [the JavaScript specification](spec.javascript.md) for the API and OSC
7501 change semantics.

## Configuration

Swiftty supports JSONC configuration with `//` and `/* … */` comments and
trailing commas. File discovery checks, in order:

1. `swiftty --config <path>` (a missing explicit file is reported).
2. `$XDG_CONFIG_HOME/swiftty/config.jsonc`, or `~/.config/swiftty/config.jsonc`.
3. `~/.swiftty.jsonc`, then `~/.config/swiftty/config.json`.

Configuration files are complete JSONC documents: Ghostty-style files, includes,
repeated keys and `key = value` lines are not supported, and the Ghostty themes
directory is not searched. Existing extensionless or legacy files are ignored by
discovery and left on disk; convert their settings to the JSONC model. With no
JSONC file, defaults apply.

Settings (Cmd-,) edits the selected file, including an explicit `--config`
path, and lists configuration problems; it will not overwrite an invalid file.
Edit Configuration File (Opt-Cmd-,) opens it, creating a commented template on
demand; Shift-Cmd-, reloads it. iOS reads `Documents/config.jsonc`. Reduce
Motion, Reduce Transparency and Increase Contrast adjust presentation without
changing the file ([spec.apple.md](spec.apple.md)).

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/chr33s/swiftty/main/schema.json",
  "font": { "family": "Menlo", "size": 14, "line_height": 1.2, },
  "window": { "opacity": 0.95, "blur": true, "padding": 8, },
  "terminal": { "shell": null, "scrollback_limit": 10000, },
  "keybindings": [
    { "trigger": "cmd+k", "action": "clear_screen" },
    { "trigger": "cmd+t", "action": "new_tab" },
  ],
}
```

Each omitted section or setting uses its default. Optional `window.width` and
`window.height` set the initial content size in points. `scrollback_limit` counts
history rows; the terminal's existing byte budget also bounds storage. A shell
is an executable path, not a shell command. The optional `theme`,
`copy_on_select`, `mouse_hide_while_typing`, `cursor_style`, and
`cursor_style_blink` fields support Settings edits. Unknown keys, invalid types,
and invalid ranges are reported with the original file, line, and one-based
UTF-8 byte column (tabs count as one). Duplicate keys are rejected.

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

The dependency-free `SwifttyConfig` library provides `ConfigDiscovery`,
`ConfigLoader`, `JSONCSanitizer`, and mutable Codable models. `ConfigLoader.save`
validates and atomically writes pretty-printed, sorted JSON. Saving JSONC from
Settings or the library replaces comments with canonical JSON; symlinked
configuration files keep their links. `schema.json` provides editor completion;
the `$schema` URL resolves from the repository's main branch once published.

Themes use JSONC too. Place a file such as `Night.jsonc` in
`~/.config/swiftty/themes` and set `"theme": "Night.jsonc"`. Built-in themes are
`Swiftty Dark` and `Swiftty Light`; omitting `theme` follows the system appearance.
On macOS these use native system text, background, selection and ANSI colors,
including the system selection accent. Other platforms use an Apple-colored
light/dark palette. The terminal defaults to 95% opacity over native glass;
Reduce Transparency makes it fully opaque.
A theme can also be selected by an explicit path.

```jsonc
{
  "background": "#0C1021",
  "foreground": "#F8F8F8",
  "cursor": "#FFFFFF",
  "cursor_text": "#0C1021",
  "selection_background": "#253B76",
  "palette": { "1": "#BF392A", "2": "#61CE3C", },
}
```

Theme files must be regular UTF-8 files of at most 64 KiB; configuration files
are limited to 1 MiB. Invalid themes fall through to the next lookup directory
or built-in theme. Explicit unavailable themes use the standard palette.

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
2026-10-10; earlier probes are identified below.

### Swiftty vs Ghostty

Parser and terminal-state throughput on an Apple M5 Max (18 CPU cores, 128 GiB),
measured 2026-11-05: Ghostty `5dc28bb`, Zig 0.16.0 ReleaseFast, versus Swift
6.4.2 Release. Each binary read the same ~100 MiB files in 64 KiB chunks at
120×80. Times are median CPU time (user + sys) of each process, including
startup and file reads; relative throughput by wall time, recorded alongside,
is within 1% of these except on `kitty-long-escape-codes` (4.6%) and
`ghostty-ascii` (1.1%). Each input had two warmups and 20 rounds in a balanced
(Williams) order, so every variant ran in each position and after each other
variant equally often. Intervals are paired bootstrap 95% intervals.
The 1-minute load average stayed between 1.7 and 3.4.

The inputs are ten Swiftty generators, four `ghostty-gen` generators and five
of kitty's `kitten __benchmark__` payloads, built from kitty's source at
`fb99338` and repeated as the kitten sends them, on the alternate screen.
kitty's Images payload is omitted: Swiftty ignores APC strings, so it would
skip all of Ghostty's image work.

Ghostty's `terminal-stream` raises its 10,000-byte scrollback limit to two
215-row pages, up to 350 history rows at 120×80; Swiftty applies 10,000 bytes
literally (5 rows). "Matched" gives Swiftty 350 rows (672,000 bytes) and is the
like-for-like comparison. kitty's payloads use the alternate screen, so history
does not apply to them.

With matched history Swiftty was faster on all 19 inputs, from 3.0% on
`cat-source` to 3.5× on `ghostty-osc`. The nominal limit gives the same
count. On 4 November, before the UTF-8 decoder and cluster changes, mixed
`utf8` and `kitty-unique-unicode` were about 1.2% slower and `utf8-latin`
tied ([samples](Benchmarks/Ghostty/compare-2026-11-04.json)).

Relative throughput is `Ghostty time / Swiftty time`.

| Input                   |   Ghostty |   Swiftty | Relative (95% CI)     |   Matched | Relative (95% CI)     |
| ----------------------- | --------: | --------: | --------------------- | --------: | --------------------- |
| ascii                   |   99.9 ms |   88.7 ms | 112.6% (112.3–113.2%) |   90.8 ms | 110.0% (109.7–110.5%) |
| cat-source              |  149.5 ms |  139.7 ms | 107.0% (106.7–107.3%) |  145.1 ms | 103.0% (102.5–103.5%) |
| compiler-log            |  142.7 ms |  110.4 ms | 129.2% (128.6–131.2%) |  111.6 ms | 127.8% (127.2–129.7%) |
| csi-heavy               |  483.0 ms |  226.6 ms | 213.1% (211.6–214.6%) |  226.6 ms | 213.2% (212.0–214.4%) |
| osc-heavy               | 1241.2 ms |  367.7 ms | 337.6% (329.8–343.0%) |  378.4 ms | 328.0% (320.2–335.2%) |
| scroll                  |  414.8 ms |  305.8 ms | 135.6% (134.2–136.4%) |  306.9 ms | 135.2% (133.2–136.5%) |
| unicode-joins           |  667.7 ms |  347.6 ms | 192.1% (189.1–196.0%) |  361.6 ms | 184.7% (181.8–188.3%) |
| utf8 (mixed scripts)    |  340.4 ms |  223.2 ms | 152.5% (151.8–153.0%) |  224.2 ms | 151.8% (151.1–152.3%) |
| utf8-latin              |  132.5 ms |  123.3 ms | 107.5% (107.1–108.2%) |  124.6 ms | 106.4% (105.9–107.0%) |
| utf8-cjk                |  101.7 ms |   93.5 ms | 108.8% (108.1–109.5%) |   94.3 ms | 107.8% (107.5–108.4%) |
| ghostty-ascii           |   69.3 ms |   61.6 ms | 112.5% (111.4–113.1%) |   62.1 ms | 111.6% (110.3–112.5%) |
| ghostty-osc             | 4389.5 ms | 1238.2 ms | 354.5% (349.7–355.7%) | 1249.6 ms | 351.3% (346.4–353.4%) |
| ghostty-styled          |  421.7 ms |  184.4 ms | 228.7% (228.1–229.3%) |  185.2 ms | 227.7% (227.0–228.4%) |
| ghostty-utf8            |  766.4 ms |  385.8 ms | 198.7% (198.0–199.3%) |  388.4 ms | 197.3% (196.6–197.8%) |
| kitty-ascii             |  167.7 ms |  156.2 ms | 107.4% (106.7–108.0%) |  156.1 ms | 107.4% (106.9–107.9%) |
| kitty-unicode           |   97.4 ms |   85.2 ms | 114.4% (114.0–114.9%) |   85.0 ms | 114.6% (114.2–115.2%) |
| kitty-unique-unicode    |  586.4 ms |  283.3 ms | 207.0% (206.0–208.4%) |  283.3 ms | 207.0% (205.9–208.4%) |
| kitty-csi               |  426.0 ms |  273.7 ms | 155.7% (155.4–156.7%) |  273.1 ms | 156.0% (155.5–156.7%) |
| kitty-long-escape-codes |   13.9 ms |   12.3 ms | 113.3% (111.4–114.6%) |   12.3 ms | 112.6% (110.5–114.4%) |

Caveats:

- Upstream `ghostty-bench` logs warnings to stderr while timed. A build with
  `log_level = .err` was 23.1% faster on `ghostty-utf8`, 15.6% on `osc-heavy`,
  8.5% on `kitty-long-escape-codes` and 0.7–4.9% on the rest. Against it,
  nominal-limit Swiftty is at 161.4% on `ghostty-utf8` and 291.9% on
  `osc-heavy`, and stays ahead on every input, by at least 3.1%
  (`cat-source`). With matched history it is ahead on all but `cat-source`
  (99.2%).
- Final states are not compared. OSC 8 links follow Ghostty's rules: an `id=`
  parameter and the URI identify a link, every other OSC 8 opens a link of
  its own, and URIs are kept whole. Swiftty keeps them in one table for both
  screens, stores each distinct URI once, and labels at most 1,048,575 live
  links. Adopting these rules left `ghostty-osc` where it was (351.4% before)
  and made `osc-heavy` faster (252.5% before).
- `ghostty-gen +ascii` and `+osc` are unseeded and `cat-source` concatenates
  this repository's sources; compare input hashes across runs.
- Median peak RSS: Swiftty 7.7–10.4 MiB, Ghostty 9.5–11.2 MiB.

Raw samples, input and binary hashes, load averages and toolchain versions are
in [Benchmarks/Ghostty/compare-2026-11-05.json](Benchmarks/Ghostty/compare-2026-11-05.json).
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
