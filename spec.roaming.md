# Minimal specification: Apple-platform SSH clients with a persistent macOS terminal

**Version:** 0.4 — combined proposal, Swiftty integration and design provenance\
**Research date:** 2026-10-10  
**First-party language:** Swift 6.4, Swift 6 language mode  
**Product platform scope:** iOS 27.x, iPadOS 27.x, native macOS 27.x, Mac Catalyst 27 on macOS 27.x, visionOS 27.x, tvOS 27.x, and a watchOS 27.x companion; Linux and Windows deferred  
**Required deployment minimums:** 27.0 for each included Apple platform; see §2.1 for component profiles  
**Swiftty integration:** Appendix A defines the Swiftty integration and supersedes terminal/frontend-specific choices in this base proposal. Appendix B records design provenance.  
**Protocol working name:** Remote Screen Transport, `RST/1`  
**Status:** Base proposal and integration design. [README.md](README.md) records implementation and verification status. [spec.inbox.md](spec.inbox.md) supersedes this proposal's service ownership, leases, retention and input-acknowledgment rules for the unified service. Historical source-review and document-revision statements below describe their recorded review times, not current implementation status.

## 1. Product decision

Build Apple-platform SSH clients with the feature profiles in §2.1, and a small, unprivileged macOS terminal helper. Full clients include SFTP; tvOS is terminal-focused and watchOS is a read-only iPhone companion. Reuse macOS OpenSSH for authentication, bootstrap, ordinary SSH, and SFTP. Do **not** implement another SSH server, port the complete tssh/tsshd products, or reproduce Mosh's implementation or wire protocol.

The roaming terminal has three essential properties:

1. **The host owns the shell.** A lost connection does not destroy its PTY or terminal emulator.
2. **The client receives current screen state.** Obsolete terminal output need not be replayed after an outage.
3. **Input remains ordered and deduplicated.** Reattachment must not resend a previously applied keystroke to the PTY.

Use **standard QUIC through Apple's Network framework** for this terminal connection. Implement the application-level screen and session rules independently; delegate encryption, congestion control, path validation, and packet-loss recovery to the transport implementation.

On full clients, keep **SFTP on a separate ordinary SSH connection**, with explicit restart/resume logic. Never send files through terminal snapshots. tvOS and watchOS omit SFTP in v1; these are explicit product profiles, not assertions that the OS can never support additional features.

### What this borrows from the paper

The Mosh paper describes a server-authoritative terminal, synchronization of replaceable display state, persistent sessions across network changes, and speculative local echo. This design adopts the first three ideas. It uses a new application protocol, complete snapshots, and standard QUIC instead of implementing SSP. Prediction is deliberately excluded from version 1. [S1]

**Consequently, v1 improves continuity and catch-up, not the round-trip delay of remote echo.** It must not advertise Mosh-equivalent typing latency.

“MUST” identifies a release requirement. Numeric limits below are proposed defaults and test targets, not measured results.

## 2. Minimum scope and exclusions

The following feature table describes the full-client profile. §2.1 narrows it for the tvOS terminal client and watchOS companion; those products remain in scope without claiming full-client parity.

| Included in v1 | Deliberately excluded |
|---|---|
| Explicit host, port, username, and credential profiles | Full OpenSSH configuration evaluation and tssh host-picker parity |
| SSH host-key verification; password and app-managed Ed25519 authentication | Agent forwarding, FIDO, Kerberos, broad encrypted-key import |
| Ordinary SSH shell/exec and clean stdout/stderr handling | Port forwarding, ProxyJump, connection multiplexing |
| Persistent shell, current-screen recovery, resize, detach, close | Shared terminal writers, collaboration, session cloning |
| Foreground network recovery and reattachment after client suspension | Indefinite background execution or background SFTP guarantees |
| SFTP directory browsing and regular-file upload/download/resume | Recursive transfers, synchronization, filesystem mounting |
| Plain SSH fallback when the helper or UDP is unavailable | Automatic conversion of a roaming session into a plain SSH session |
| Unicode text, common terminal attributes, alternate screen, keyboard/paste | Terminal graphics, remote clipboard writes, speculative echo |

A direct client may manage several saved sessions, but **only one roaming terminal is actively attached per client application at a time in the minimal UI**. Each server session permits one controlling client across all platforms. New platforms do not enable concurrent writers or automatic cross-device credential synchronization. [spec.ssh-identity.md](spec.ssh-identity.md) supersedes the device-only credential exclusion for iPhone, iPad, Mac Catalyst and visionOS: SSH identities stay device-only by default, and syncing one through iCloud Keychain, or syncing profiles and public metadata through CloudKit, is an explicit per-identity or per-setting opt-in. The watchOS companion does not attach to RST/1 or acquire a writer lease.

No Mosh, tssh, tsshd, trzsz, or ZMODEM interoperability is claimed. No additional file-transfer utility is required on macOS: Remote Login provides SSH and SFTP. [S2]

### 2.1 Product platform scope — mandatory

| Product component | Platform and deployment minimum | Required v1 capability profile |
|---|---|---|
| iPhone client | iOS 27.0 | Full client: SSH shell/exec, roaming terminal, SFTP |
| iPad client | iPadOS 27.0 | Full client: SSH shell/exec, roaming terminal, SFTP |
| Mac client | Mac Catalyst 27.0, running on macOS 27.x | Full remote client using the UIKit-derived frontend; no app-local PTY (local shells are Swiftty.app's, Appendix A) |
| Spatial client | visionOS 27.0 | Full remote client in a native window; immersive presentation deferred |
| Television client | tvOS 27.0 | SSH shell/exec and roaming terminal; keyboard/focus-oriented UI; no SFTP in v1 |
| Watch companion | watchOS 27.0 with paired iOS 27.x app | Read-only, timestamped session status and optional bounded text preview; no direct SSH, QUIC, SFTP, or shell input |
| `rst-host` helper and per-user agent | macOS 27.0 | The sole persistent server implementation for every direct client |

These are **product requirements, not claims of completed platform ports**. Mac Catalyst and visionOS are first-class full-client targets. tvOS and watchOS are in-scope products with the explicit smaller profiles above. All profiles need implementation and platform-specific validation before release.

Earlier OS releases remain out of scope. **Linux and Windows clients are deferred for now**: no application targets, transport/backend ports, renderer ports, CI jobs, packaging, or release claims for either platform are required. The persistent server remains macOS-only. Other unnamed platforms, including Android, web, and DriverKit, are not implicitly included.

The supported major runtime is 27.x for each Apple OS family. Mac Catalyst is a separate application target/SDK environment on macOS, not an additional host operating system. Future major releases require explicit validation before a support claim; deployment minimums are not runtime upper-version locks.

### 2.2 Platform packaging and deployment

Every first-party app, relevant package, test host, and helper MUST set the applicable deployment minimum to 27.0. For a platform-neutral shared model package, the relevant manifest fragment is:

```swift
// swift-tools-version: 6.4
// Relevant Package initializer arguments; not a complete manifest.
platforms: [
    .iOS("27.0"),
    .macOS("27.0"),
    .macCatalyst("27.0"),
    .visionOS("27.0"),
    .tvOS("27.0"),
    .watchOS("27.0"),
],
swiftLanguageModes: [.v6]
```

The iOS declaration covers both iPhone and iPad. Declare only the relevant minimums in component-specific packages: the host package declares macOS, and the companion package needs iOS/watchOS. SwiftPM platform declarations express deployment minimums, not proof that a dependency or all its APIs compile for each target. Use separate target dependencies and conditional compilation to enforce actual component boundaries. [S17]

Align Xcode deployment settings with these requirements for iOS/iPadOS, native macOS, Mac Catalyst, visionOS, tvOS, and watchOS. Build Mac Catalyst as a distinct destination; an ordinary macOS or iPad build does not validate it. The watch target MUST NOT pull in Swiftty's renderer, SSH, QUIC, or PTY targets. An iPhone bridge may depend on the watch companion's small message-model target without exposing credentials.

Pin the actual Swift 6.4 toolchain, Xcode/SDK versions, and dependency revisions after successful resolution. The 27.0 minimums are product decisions, not inferred Swift 6.4 requirements. No package edit establishes runtime compatibility. If an included platform fails a dependency/API gate, track that gap as in-scope work rather than silently declaring the platform supported or removing it from scope.

First-party code may use APIs available at its 27.0 baseline without older-OS fallback paths. APIs introduced in later 27.x releases require availability handling unless the baseline is revised. Capability checks, security policy, and per-platform lifecycle handling remain mandatory.

### 2.3 Platform-specific behavior

**Mac Catalyst:** adapt UIKit menus, keyboard shortcuts, pointer input, file selection, focus, and window lifecycle for Mac use. It is a remote-client product only in v1. `rst-host` remains a separate native macOS executable; a Catalyst app MUST NOT be treated as the launchd agent or reuse the native Mac local-process backend by accident.

**visionOS:** provide a windowed terminal with text/keyboard input, accessible focus, window sizing, and SFTP import/export using platform-supported document access. Do not reinterpret gaze or gestures as shell commands. Immersive scenes, spatial terminal geometry, and multiple active roaming sessions are excluded from the minimal profile.

**tvOS:** provide saved-host selection, explicit trust/authentication prompts, ordinary SSH, and roaming recovery. The remote/focus UI navigates application controls; tested keyboard/text input provides terminal input. Do not assume touch, clipboard, iPhone keyboard notifications, or document-picker APIs exist with identical semantics. Disable unavailable clipboard/paste actions, SFTP, and local-process actions rather than presenting nonfunctional controls. No durable local file workflow is promised in v1.

**watchOS:** provide a SwiftUI companion for an explicitly selected iPhone session, not a standalone terminal. Use a small, independently versioned companion message model over WatchConnectivity. It may show cached status and, only after explicit opt-in, a bounded text preview; every update carries its capture time and stale/unavailable status. `WCSession` supports latest-state application context and reachable-peer messages; delivery is asynchronous and does not establish a continuous live connection. [S18]

The watch MUST NOT receive SSH credentials, TLS private keys, RST attachment capabilities, or a remote command/keystroke execution interface. It MUST NOT open a second RST attachment, steal the iPhone's writer lease, trigger an SSH login, or keep either app alive in the background. Refresh requests return the latest iPhone-observed state, not a claim that the Mac was just polled. Unreachable or stale state is displayed honestly. At most one refresh is pending; use a maximum 16 KiB decoded companion payload, at most one optional text preview, and no output-history queue. This is a proposed product bound, not a claimed WatchConnectivity system limit.

Use application-context updates only for nonsensitive status metadata. Deliver an opted-in text preview only in a bounded immediate foreground request/reply; never place preview text in application context, queued background transfers, or a durable output cache. Sensitive text previews are disabled by default, kept in memory only, removed when the companion becomes inactive/backgrounded or locked, and omitted from complications and notifications. A phone-side opt-out clears cached companion data when communication is available. Status cannot be represented as continuously current while the phone is suspended. No new host-side protocol or server observer role is introduced for the watch.

### 2.4 Release validation matrix

All included products require distinct build and device/runtime evidence. Test iPhone/iPad, visionOS, tvOS, and watchOS simulator destinations where supported, and physical iPhone, iPad, spatial-device, Apple TV, and paired Apple Watch/iPhone configurations. Test native macOS, Mac Catalyst, and the headless helper separately on Mac hardware. Simulator success alone is not runtime support.

For each advertised platform, cover the 27.0 baseline and the selected shipping 27.x runtime, recording exact toolchain, SDK, runtime, entitlements, dependency revisions, and exercised features. Run SSH/RST tests on every direct client and SFTP tests on every full client; use companion-specific tests rather than direct-network tests on watchOS. Cellular handover applies only to devices with cellular capability; other clients require applicable path-switch, sleep/suspend, and reconnect tests.

Platforms may be implemented in stages, but all rows above remain in product scope. Do not claim the complete platform family is released until every included profile passes its applicable gates. Linux/Windows porting and older-OS CI are not part of these gates.

**macOS integration evidence, 2026-10-27:** `Scripts/test-real-ssh.sh` passed all
four real-OpenSSH tests with both the default Network.framework transport and
`RST_REAL_SSH_POSIX=1`, using Swift 6.4.1, the macOS 27.0 SDK and macOS 27.0.1
(26A434). The debug tests cover host-key decisions, an ordinary SSH shell,
SSH bootstrap followed by QUIC attachment, and SFTP upload/download. The SFTP
test now cancels at a partial checkpoint and proves continuation on a new client
without restarting, retaining its 1,000,003-byte payload and default request
window. Both event streams passed the completion audit and fixture cleanup
succeeded. This is Mac integration evidence; Release, other platform profiles,
physical-device behavior and the full acceptance matrix remain separate gates.

### 2.5 Xcode security build settings

The XcodeGen targets `MobileClient`, `CatalystClient`, `VisionClient`, `TVClient`
and `WatchCompanion` use `Apps/project.yml` as the source of build settings; the
generated `.xcodeproj` is gitignored. Base entitlements live in
`Apps/<Target>/<Target>.entitlements` and are merged by
`Scripts/configure-links.sh` into `Apps/Config/Generated/`. The following records
the Xcode 27 configuration and compatibility findings from 2026-10-21; revalidate
toolchain limitations when upgrading Xcode.

**Enabled configuration:**

- Set `ENABLE_ENHANCED_SECURITY` in project-level `settings.base`, inherited by
  all five targets. It enables pointer authentication (arm64 + arm64e), security
  compiler warnings, `GCC_WARN_SHADOW`, typed allocator support and libc++ hardening,
  subject to the target overrides below.
- `Scripts/configure-arm64e-packages.sh`, invoked by XcodeGen's `postGenCommand`,
  sets `iOSPackagesShouldBuildARM64e` in the generated workspace's
  `WorkspaceSettings.xcsettings`. Shared app logic lives in Swift packages, so
  app-wrapper slices alone do not provide pointer-authentication coverage. The
  inspected Xcode 27 frameworks recognize this key, with no `macOS…` or
  `visionOS…` variants; device packages build as arm64e for iOS, visionOS and
  watchOS, while Catalyst and tvOS packages remain arm64.
- Set project-level `EXCLUDED_ARCHS[sdk=*simulator*]` to `x86_64`. With the package
  flag enabled, simulator packages build for arm64 only; an x86_64 app slice fails
  to resolve those modules. The configured macOS 27 host baseline is Apple silicon.
- MobileClient, CatalystClient and VisionClient enable
  `com.apple.security.hardened-process`, its `enhanced-security-version-string`
  set to `2`, `hardened-heap`, `dyld-ro`, and `platform-restrictions-string` set to
  `2`. They also enable `checked-allocations` and `checked-allocations.soft-mode`
  under that entitlement prefix. Soft mode produces simulated crash reports
  without terminating; disable it only after reports are clean on A19 / M5 or
  later hardware.
- XcodeGen's default presets already provide `GCC_WARN_ABOUT_RETURN_TYPE=YES_ERROR`,
  `GCC_WARN_UNINITIALIZED_AUTOS=YES_AGGRESSIVE`,
  `GCC_WARN_64_TO_32_BIT_CONVERSION` and `CLANG_WARN_EMPTY_BODY`. They are not
  duplicated in `project.yml`. The app targets compile only Swift, so these
  C/Objective-C warnings and analyzer settings have little effect there.

**Compatibility overrides:** CatalystClient and TVClient set
`ENABLE_POINTER_AUTHENTICATION=NO` and
`ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE=NO`. Generic device builds on
2026-10-21 could not import `RoamingApp` into an arm64e app slice because Xcode 27
did not produce matching package slices. Other Enhanced Security settings remain
enabled, including Catalyst's hardened-process entitlements. Remove these
overrides only after matching package builds are supported and validated.

MobileClient and the local package's iOS Swift targets
also pass `-Xfrontend -no-sign-class-ro`. Xcode 27.2 builds third-party packages
at their own older deployment targets, producing unsigned Objective-C
`class_ro_t` pointers; mixing those objects with our OS 27 defaults causes
archive linker warnings. This override aligns that metadata ABI while retaining
the other arm64e pointer-authentication protections. visionOS and watchOS keep
their default class-metadata signing. Remove this override when all linked dependencies use
the signed metadata ABI.

**Deferred decisions:**

- MobileClient's `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` and
  `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow`
  remain disabled. The recorded hardware requirement is A20 Pro or later, with
  no soft mode. Most app code is Swift, where integer overflow already traps;
  the C surface is mainly swift-nio shims and system zlib. Revisit after one or
  two releases of clean memory-tagging soft-mode reports, first in TestFlight.
- TVClient and WatchCompanion inherit the project build setting but have no
  Enhanced Security entitlements: the capability's recorded platform scope is
  iOS, macOS, visionOS and DriverKit. Revisit if platform support changes.
- Native SwiftPM app/helper signing is a separate boundary; see
  [native packaging security](spec.multiplexer.md#native-packaging-security).
  Package C warnings and annotation-based bounds safety are specified in
  [the core build policy](spec.md#swiftpm-c-security-settings).

## 3. Components and dependency boundary

```text
                         macOS: existing OpenSSH
                    +--> SSH authentication / helper bootstrap
                    |
Direct Apple client +--> SSH exec / ordinary shell
                    |
                    +--> separate SSH connection --> SFTP (full clients)
                    |
                    +--> QUIC + RST/1 --> rst-host user agent
                                             |
                                      authoritative terminal
                                             |
                                           PTY
                                             |
                                      user's login shell
```

The watchOS companion reads bounded cached state from the paired iPhone application through WatchConnectivity; it has no connection to this host diagram.

`rst-host` is a provisional executable name. It has two modes: a long-running `serve` mode and a short-lived `bootstrap --stdio` mode invoked through SSH. It is **not** an SSH daemon.

| Layer | Proposed implementation |
|---|---|
| SSH client | SwiftNIO SSH, SwiftNIO, and an Apple-compatible transport adapter |
| Roaming transport | Network framework QUIC: connection group plus independent streams |
| Cryptographic utilities | CryptoKit / Swift Crypto; Security framework for credentials and identities |
| TLS certificate construction | `swift-certificates`, if needed for the host identity |
| Terminal engine | Swiftty core behind a project-owned adapter, as specified in Appendix A |
| Direct-client presentation | Swiftty-compatible renderer with native AppKit/UIKit-derived frontends and per-platform adapters |
| watchOS presentation | Separate SwiftUI status/preview view and WatchConnectivity bridge; no terminal renderer |
| Host process and PTY | Swift wrappers around Darwin process, termios, and PTY APIs |
| Snapshot compression | Platform zlib, with independently framed snapshots |

SwiftNIO SSH supplies SSH building blocks, not a complete SSH/SFTP application. Host trust, client policies, and the SFTP request layer remain explicit work. [S3]

Swiftty replaces the earlier SwiftTerm choice; Appendix A's pinned source review and required snapshot import/export boundary are authoritative. A platform declaration or an existing UIKit view does not establish a complete Catalyst, visionOS, or tvOS port. Do not add a second terminal engine. [S19] The earlier SwiftTerm source [S4] remains historical background, not an implementation dependency.

Swift Crypto explicitly supports non-Swift backing implementations; these are permitted. Apple system networking, Security, zlib, and other reviewed upstream native code are also permitted. There is no requirement for transitive source-language purity. [S5]

All first-party application, helper, session, and protocol logic MUST be Swift 6.4. Pin one resolved dependency graph; do not combine arbitrary latest branches. The mandatory OS 27.0 minimums in §2.1 are product choices, not inferred Swift 6.4 requirements. Appendix A uses the same support matrix. [S6]

## 4. macOS deployment and session lifetime

Install one signed helper and a per-user launchd agent. The agent runs as the same account used for SSH, never as root. The initial deployment assumes that account's user agent is loaded; the installer MUST validate this. User logout and agent restart are outside session-survival guarantees.

Stage a complete replacement app beside the destination and validate its bundle, required executables, signature and expected signing team before retiring the previous app. The staged copy's team must agree with the source metadata used for the restart decision. Publish with an atomic exchange for replacement or an exclusive rename for a first install. Copy, validation and publication failures must preserve the previous installed app, and a concurrent first-install destination must not be overwritten. Settle owned copy/verification workers and attempt private staging cleanup on handled interruption, reporting cleanup failures. Keep existing signing-team and explicit agent-restart checks; registration and roaming setup follow publication as separate steps.

The helper exposes a local Unix-domain control socket in an owner-only directory. Validate peer UID and socket ownership. `bootstrap --stdio` communicates with this socket; arbitrary remote users cannot select another UID.

A configurable control-socket name must be one nonempty NUL-free filename component, excluding dot/parent components and separators, so it stays inside the verified directory. Reject empty/NUL client socket paths before lookup or connection, and enforce native UTF-8 path capacity including its terminator before copying into the Unix address.

Use one monotonic elapsed budget for the client control exchange across connection setup, every partial request write, and the full response prefix/body. Partial progress and retries must not restart it. Wait on nonblocking sockets only within the remaining budget and reject completion after expiry. Keep socket ownership until synchronous I/O settles, check frame lengths before body allocation, and translate elapsed transport failure to the helper's unavailable response.

Resolve a file-loaded relative state directory against the selected configuration file's parent, and retain its absolute path in the loaded configuration. Agent and bootstrap helper must therefore select the same control socket regardless of their working directories. Directly constructed relative configurations use the shared default roaming directory. Reject empty or NUL-containing paths when decoding configuration and before opening its file.

Load the agent's selected configuration before initializing its service. Only an absent default configuration permits local-only startup; missing explicit environment or command-line selections, unreadable files and invalid configurations must report failure and exit with status 78. An explicit `--no-roaming` disables loading, and the last roaming command-line option wins.

The agent owns one configurable QUIC/UDP listener and up to eight sessions. A deployment may choose a private-range port such as UDP 51222; that is a project default, not an assigned service port. Bind-address and firewall configuration must be explicit.

Each session owns a PTY, shell process group, terminal emulator, input ledger, and latest presentation state. Start the configured account shell with a genuine controlling terminal and correct process-group semantics. Do not confuse an SSH exec channel with the PTY that must survive it.

The shell starts only after the first successful application attachment. Unattached reservations expire after 60 seconds. Once started, loss of SSH bootstrap, QUIC, or any client process MUST NOT send SIGHUP to the shell.

Continue reading and parsing PTY output while detached. Do not accumulate a network replay log or unbounded scrollback. Retain emulator state, the current screen, and bounded diagnostic metadata.

Default detached retention is 24 hours since the last authenticated client activity. On expiry or explicit termination, close the PTY, terminate the owned process group with bounded escalation, and revoke credentials. A shell exit retains its final screen and status for five minutes.

**Limits:** the Mac must remain powered and reachable to make progress. Sleep pauses execution/network access; reboot, logout, helper crash, and helper restart can lose sessions. No disk checkpoint of an executing shell is promised. Detached child jobs that escape the shell's process group are not a job-supervision feature of this product.

## 5. SSH bootstrap, identity, and authorization

### 5.1 Establish trust through SSH

The client MUST verify the SSH host key before sending credentials. An unknown key requires an explicit trust decision; a changed key blocks automatic reconnection. Trust is scoped to the configured host identity and port, not merely a resolved IP address.

Open a no-PTY SSH exec channel running the fixed installed helper path with the fixed argument `bootstrap --stdio`. Supply structured requests through stdin. Never interpolate passwords, paths, tokens, or session identifiers into a shell command.

The bootstrap request contains the operation (`create`, `resume`, `list`, or `terminate`), session identifier where applicable, supported protocol version, and initial grid size. Launching arbitrary server commands through this API is excluded.

Responses use a bounded, length-prefixed JSON envelope. Diagnostic text belongs on stderr; unexpected stdout is a protocol error. Reject malformed lengths and unsupported versions before creating a shell.

### 5.2 Bootstrap response

A successful create/resume response contains:

```text
protocol                  "RST/1"
serverInstanceID          random identifier for this agent lifetime
sessionID                 random 128-bit identifier
writerID                  identity of the permitted input sequence
endpoint                  approved host/address and UDP port
serverCertificateDER      certificate trusted through this SSH exchange
serverCertificateSHA256   exact certificate fingerprint
applicationToken          random 256-bit bearer capability
tokenExpiresAt            bounded validity, maximum 8 hours
initialGrid               columns and rows
limits                    negotiated protocol bounds
```

The certificate authenticates the QUIC server, while the application token authorizes access to the particular user's session. These are separate checks.

Validate every advertised limit before accepting a grant. Grid and framing bounds must be positive; input and paste budgets may be zero to disable those capacities. Use the smaller of each advertised bound and the client's local hard cap. The granted initial grid must fit those bounds, and the control budget must fit the capability-bearing `Attach` record. Clamp subsequent view-grid proposals to the negotiated dimensions; refuse individual input operations that exceed the paste, generated-input or encoded control-record bounds. Enforce snapshot encoded and decoded byte limits from the header before buffering the body or decompressing, and validate its dimensions before presentation.

A refreshed grant updates these limits without dropping accepted input. Preserve the input sequence and retained operations even when the new pending-byte budget is smaller than their total; refuse new input until acknowledgments free enough room. Reconcile with `Attached` before replay. If an unapplied operation cannot fit the new per-operation bounds, fail that attachment with a protocol error and retain the operation rather than transmitting it beyond the limit or silently discarding it.

The client MUST validate the exact SSH-delivered certificate and TLS proof of possession before sending the token. A self-issued certificate is acceptable **only as an explicitly SSH-authenticated, connection-scoped trust anchor**; accepting arbitrary self-signed certificates is forbidden. Configure a scoped trust policy, expected certificate identity, and validity checks. Certificate replacement requires fresh SSH authentication. [S7]

The helper's certificate/private key is agent-owned and independent of the SSH host private key. Never export the SSH host private key. Certificate construction and Security identity integration require a build-and-device spike. [S8]

Persist the helper identity in an owner-only directory. Validate the opened directory and file descriptors, refuse final-component symlinks and nonregular identity files, and anchor child reads and atomic replacements to that directory. The raw P-256 key must contain exactly 32 bytes; certificate DER is capped locally at 64 KiB. Check size before reading, enforce the cap while reading if a file grows, and refuse oversized generated certificates before replacing persisted identity.

### 5.3 Application attachment

Use ALPN `rst/1`. Wait for the authenticated TLS handshake, then send `Attach(sessionID, serverInstanceID, writerID, applicationToken)` on the control stream. Reject all other application messages before successful attachment.

The server validates the capability, expiry, instance, and session, then assigns a monotonically increasing `attachmentEpoch`. A successful attachment atomically fences the previous connection: subsequent input from its epoch is rejected.

Keep the token only in client memory in v1. Warm reconnects can reuse it until expiry. After app termination or token expiry, use SSH to resume the retained session and issue fresh credentials; revoke the previous capability.

Disable application 0-RTT. No attach, input, resize, or close operation may execute as TLS early data. QUIC/TLS resumption and application session resumption are different mechanisms. [S9]

Store SSH private keys in Keychain. Tokens, credentials, terminal contents, and input MUST NOT appear in logs, argv, analytics, crash annotations, or unprotected saved state.

## 6. The authoritative terminal

The server terminal engine is the only parser of the persistent PTY's output. It retains hidden emulator state, including inactive buffers and modes. The client receives only the presentation needed to draw the selected viewport.

A full `ScreenSnapshot` contains:

```text
sessionID, attachmentEpoch, screenRevision, resizeRevision
columns, rows, activeBuffer
cursor: row, column, visible, shape
screen flags: reverseVideo
bounded title
row wrap flags
style table: resolved colors and supported text attributes
cells: grapheme text, display width/continuation, style index
lastFullyAppliedInputSequence   // informational; not proof of visible echo
```

The server supplies cell widths. The direct-client renderer MUST NOT independently reflow rows or recalculate character width. Combining marks and wide-cell continuations must survive serialization.

Use full owned snapshots, not borrowed emulator buffers. Apply a snapshot atomically only after complete decoding and validation. A snapshot with an older revision or attachment epoch cannot overwrite a newer screen.

Terminal-generated replies, such as cursor-position reports, return to the host PTY locally. The direct-client renderer MUST NOT generate duplicate replies or interpret the snapshot as incoming ANSI output.

The supported terminal profile includes cursor movement, erase, scroll regions, SGR attributes, color, alternate screen, cursor/keypad modes, and bracketed paste. Advertise only a terminal profile that passes the compatibility corpus; do not advertise graphics or clipboard features that were disabled.

The client sends semantic text, keys, and paste requests. The server encodes them using its current keyboard and paste modes. IME composition remains local until text is committed. Mouse reporting is deferred.

Version 1 exposes the current viewport and, where the platform profile permits it, local selection/copy. It does not promise complete historical scrollback, byte-exact terminal recording, or delivery of transient bells/titles. Users needing complete command output can redirect it into a file and retrieve it through SFTP on a full client.

## 7. RST/1 transport and framing

### 7.1 Why QUIC

QUIC provides independently ordered streams and connection migration; TLS integration and congestion recovery are standardized separately. This proposal uses those facilities rather than designing a new encrypted datagram transport. Platform migration behavior still needs device tests: retained-session reattachment remains required even when migration fails. [S10, S9, S11]

Use one bidirectional stream for control and input. Send each screen snapshot on a new server-initiated unidirectional stream. QUIC DATAGRAM, application-level packet retransmission, FEC, and custom congestion control are excluded from v1.

A snapshot stream is reliable while useful, but may be canceled when superseded. Loss within that stream can delay its completion; independent streams do not remove shared congestion or all latency. This is intentionally simpler than a generic state-delta protocol.

Snapshot bytes and control records in the same direction also share connection-level
flow-control credit. A peer withholding reads can exhaust that credit and delay
newer snapshots and control records. Delayed-reader tests must verify bounded work
and prompt recovery after reads resume; independent ordering does not guarantee
progress beyond the advertised connection limit. [S10, §4]

### 7.2 Record format

Control records are `UInt32BE(length)` followed by a UTF-8 JSON object. The length excludes its own four bytes. Every object has a `type` field. Binary data uses base64; 64-bit counters use decimal strings. Reject unknown message types in version 1 and ignore unknown optional object fields.

A snapshot stream contains exactly one record followed by FIN:

```text
UInt8       encoding: 0 = plain UTF-8 JSON, 1 = RFC 1950 zlib
UInt32BE    decodedLength
UInt32BE    encodedLength
Byte[]      encoded snapshot JSON
```

A sender that abandons a snapshot before writing its record ends the stream with an empty FIN instead; the receiver releases that stream without delivering anything.

Compression is independent per snapshot, without a cross-snapshot dictionary. Bound lengths before allocation and during decompression. RFC 1950 is the required framing, not an unspecified “deflate” variant. [S12]

| Message | Purpose |
|---|---|
| `Attach` / `Attached` | Authorize one connection and return epoch plus input progress |
| `Input` / `InputAck` | Submit an ordered operation and acknowledge completed PTY application |
| `ScreenAck` | Report the highest fully decoded and accepted screen revision |
| `Ping` / `Pong` | Application liveness and round-trip sampling |
| `Detach` / `Detached` | Stop this attachment without destroying the shell |
| `Terminate` / `Terminated` | Explicitly destroy the owned session |
| `SessionExited` | Report shell exit status and final screen revision |
| `Viewport` | With `historyViewport`: move this attachment's own history window |
| `Error` | Bounded typed failure; never a stack trace or secret-bearing diagnostic |

`Attached` includes `attachmentEpoch`, `writerID`, `lastFullyAppliedInputSequence`, any admitted partial-operation identifier, and current resize revision. Every subsequent control record is scoped to that epoch. It may also carry `features`, a list of additive behaviours the host accepts; peers ignore names they do not know, and an absent list means none. `keypadKeys` admits numeric keypad key names (`kp:one`, `kp:enter`, `kp:pageUp`, …, matching the client's keypad keys). Without it, clients send the main-keyboard key a keypad key types and drop Keypad Begin, which has none. `historyViewport` admits `Viewport` (`attachmentEpoch`, signed `lines`, at most ±1,000,000; positive reveals older output). The host moves that attachment's own window through the primary screen's history, clamped to the retained rows and anchored to an absolute row so it stays put while output arrives, and exports it in place of the live screen with the cursor hidden. The host's own view never moves; the alternate screen has no window; input returns the window to live output, as does moving past the newest line. Clients send `Viewport` only to hosts that advertise the feature, so older hosts never see it.

### 7.3 Bounded snapshot scheduling

Retain at most **two in-flight snapshot streams and one latest unsent snapshot reference**:

- One in-flight snapshot is protected from cancellation merely because output changes. This guarantees a frame can finish during continuous output.
- The second is replaceable. Newer state may supersede it, with cancellations rate-limited to ten per second.
- Acknowledgment of revision R retires all streams older than R. Promote a surviving newer stream to protected status, or create one from current state.

The client displays only the newest complete revision. Partial snapshots are never visible. If transport credit is exhausted, replace the unsent reference rather than adding a queue entry.

The host rejects a `ScreenAck` beyond the highest revision submitted for sending
on that attachment, before advancing acknowledgment state or retiring streams.
Captured screens still waiting for encoding are outside this bound. A valid
acknowledgment may precede completion of its transport send; zero, duplicate and
older acknowledgments remain harmless. An impossible acknowledgment closes the
attachment with `malformed` while retaining the session for reattachment.

Incoming snapshots retain their native stream credit until their delivery callback
finishes. This bounds queued and active snapshot deliveries together to four.
Keep every admitted complete payload until decoding: arrival order across streams
does not establish revision order, so evicting the earliest arrival could discard
the newest screen while a control callback is still running.

The host runs one snapshot encoder at a time, sharing two active work slots with
transport sends. A canceled send retains its slot until the transport call returns,
including across attachment replacement. Waiting captures are limited to the
current attachment's scheduler-owned streams; superseded captures are discarded
before encoding, and stale encoding results cannot start a send. This bounds work
even when encoding or transport completion is delayed.

The QUIC transport also caps unfinished native snapshot sends, including stream
creation, at eight per connection. Cancelling a caller does not return this
admission slot while its native write remains pending; the native completion
returns it. A send abandoned before submission releases its slot immediately.
Replacing a snapshot records the old stream's pending retirement atomically, so
a completion racing replacement cannot leave the stream waiting for a callback
that already ran.

Capture at most 30 times/second, only while attached and dirty. Lower cadence under backpressure. All send paths must respect QUIC flow control, and control/input processing must not wait for compression or rendering.

After an outage, discard old transport streams and send a full snapshot of **current** state. Do not replay missed screens. Deltas, baseline caches, and snapshot-fragment protocols are deferred until measurements justify their complexity.

## 8. Reliable input across reattachment

Each input operation is identified by `(sessionID, writerID, sequence)`. Sequence numbers start at one and increase without gaps. `Input` includes the active attachment epoch and one operation:

```text
committedText(text)
key(name, modifiers)
paste(text)
resize(columns, rows, resizeRevision)
```

The client retains unacknowledged operations in a bounded memory queue. QUIC guarantees ordering within a live stream, but it does not establish whether an operation was applied before a lost connection. The application ledger handles that boundary.

The host MUST implement these rules:

1. Admit only the next sequence for the authorized writer, or an identical retry. Reject conflicts and gaps.
2. Serialize operations with other PTY writes. Encode an operation once using the current terminal modes, then retain those exact generated bytes until completed.
3. Track partial writes. Advance the applied sequence and send `InputAck` only when all generated bytes have been accepted by the PTY, or the resize operation has completed.
4. Ignore retries of fully applied sequences; continue an admitted partial operation without writing its prefix again.

The acknowledgment means **accepted by the host PTY**, not “executed by the shell,” “visible on screen,” or “durably committed.” Do not infer prediction correctness from it.

A warm reconnect retains `writerID` and queries server progress before retrying the remaining operations. Retries use the new attachment epoch but the original operation identifiers.

A cold app restart has no input replay queue. Fresh SSH authorization creates a new writer identity after previously admitted operations have completed; it does not re-create lost client input. If an admitted write cannot finish, report pending input and refuse writer takeover rather than guessing or silently discarding a partly delivered paste.

No exactly-once command-execution guarantee is made. Deduplication lasts only while the same server session and input ledger survive. A lost server process is a lost session, never an instruction to restart or replay commands.

Disable new remote input when offline or reconnecting. Do not queue new offline commands, insert input into the authoritative screen locally, or enable keyboard autocorrection/smart punctuation for shell input. Previously submitted operations may still take effect after connectivity returns; show their pending state explicitly.

## 9. Apple-client lifecycle and network recovery

This section applies to direct SSH/RST clients. The watchOS companion follows §2.3 instead and never opens these connections.

`NWPathMonitor` is a reachability hint, not evidence that the peer is alive or that an existing connection must be replaced. Combine path changes with connection viability, application acknowledgments, and foreground state. [S13]

The client state machine is:

```text
idle -> SSH bootstrap -> attaching -> active
active -> suspect -> reconnecting -> attaching -> active
active -> background-detached -> attaching -> active
any -> session-exited / session-lost / user-closed
```

On applicable Wi-Fi/cellular or other network-path changes, allow the transport to migrate. If it fails, create a fresh QUIC connection, verify the pinned identity, and attach to the same session. Run at most one reconnect attempt at a time. Use jittered backoff: 0.5, 1, 2, 4, 8, then 15 seconds maximum.

While foregrounded, send an application heartbeat every 20 seconds when otherwise idle. On pending input or a path-change probe, mark the connection stale after `max(2 seconds, 4 × measured RTT)` without response. Idle screen silence alone is not a failure.

When a mobile/spatial/TV scene becomes backgrounded or unavailable, stop accepting input, checkpoint nonsecret session metadata and any supported SFTP progress, and attempt a bounded detach. Do not depend on detach arriving: server retention also handles abrupt loss.

Use available background time only for bounded cleanup, then stop networking. No audio, VoIP, location, or background-task workaround is part of this design. iOS may suspend or terminate the process; Apple's background mechanisms provide limited or scheduled runtime, not an indefinitely running terminal. [S14]

For the Mac Catalyst client, loss of window focus alone MUST NOT be treated as process suspension. Honor explicit disconnect, termination, sleep, and network-loss events; preserve the host session and prevent stale input. Each platform adapter maps its actual lifecycle events into the common state machine and validates them on that platform. No Apple client receives an indefinite-background-execution guarantee.

On foreground return or recovery from sleep, reconnect as needed and obtain a complete current screen before enabling input. On cold launch, reauthenticate with SSH and resume by session ID. Distinguish “temporarily unreachable” from an authenticated “session no longer exists.” A client attaches only to a workspace the user chose or explicitly created; a remembered session ID is a convenience for resuming, never permission to create a replacement ([spec.connection-setup.md](spec.connection-setup.md) §1.3).

Remembered workspace choices belong to the saved host UUID, its account scope
(or local-only scope), normalized hostname, port and remote username. Host/key
renames and credential rotation preserve that choice. A different account or
endpoint has a separate choice, including across cold launches; returning to
the original owner restores its choice. A retained terminal's status and close
callbacks update only its captured owner. The visible resume indicators track
the currently selected hosts. These identifiers remain nonsecret and never
replace fresh SSH authorization.

Legacy UUID-only choices lack verifiable ownership and are not automatically
adopted. Keep them separate; users can select the existing workspace again from
the authenticated workspace chooser. Likewise, binding a formerly local host to
an account does not silently adopt its earlier choice. Pending create, resume
and reveal intents belong to the individual terminal screen and are discarded
when that screen closes, even if its lazy backend never started.

If UDP is blocked, offer ordinary SSH. This opens a **different** shell; the retained roaming shell remains available until expiry. Same-session RST tunneling through an SSH channel is a later extension, not a hidden v1 promise.

## 10. SFTP: independent, resumable file operations

Required on the iOS/iPadOS, native macOS, Mac Catalyst, and visionOS full clients only. tvOS and watchOS deliberately omit SFTP in v1.

Implement the SFTP v3 subset over an SSH `sftp` subsystem channel: initialization, directory listing, stat, open, read, write, close, and rename for completing an upload. SFTP requests use explicit offsets and request identifiers; reconnecting creates a new subsystem and new handles. [S15, S16]

Apply the same local packet and field caps to outgoing encoding as incoming decoding. Validate before queueing a request or allocating its encoded packet; bound extension counts/bytes and include all headers and attributes in the total packet budget. Supplied UID/GID and access/modification-time fields must be complete pairs rather than silently omitted.

Directory listing must make bounded progress: reject empty NAME replies, permit at most two excluded dot entries, and limit retained visible entries. A negative listing capacity is refused before opening a handle. Close the directory handle on success or failure; a per-request timeout alone does not bound repeated successful replies.

Limit the UI to regular files, directory navigation, upload, download, cancel, and resume. Reject recursive directory transfer and unexpected special files. Do not invoke a remote shell to quote or manipulate filenames.

Keep directory rows associated with their displayed path: clear old rows when listing starts and reject superseded list results, including repeated refreshes of the same path. Upload preparation belongs to its presentation; cancellation or dismissal must prevent late manifests, overwrite prompts and uploads from appearing in a reopened browser. Join owned preparation and discard any late staged file or staging result whose checkpoint cannot be saved.

Transfer checkpoints are nonsecret JSON capped at 64 KiB per file. Validate regular-file type and size on the opened descriptor before reading, enforce the read cap if the file grows, and reject invalid progress or oversized encoding before replacing a checkpoint.

The complete checkpoint envelope records the saved host UUID, owning account
scope, configured SSH endpoint and remote username. A fresh browser loads only
matching transfers; a changed account, endpoint or username cannot resume,
remove or export the old target's files. Key rotation and display-name changes
do not change the remote file owner. Returning to the original account/endpoint
restores its saved transfers. Existing authenticated transfers keep their captured
owner while running, including across account changes.
Resuming or removing a transfer acquires its latest durable checkpoint together
with exclusive use. Another browser's cached progress cannot replace a newer
checkpoint or repeat a completed transfer, and removal uses the current temporary
paths after a restart.

Older checkpoints without ownership remain on disk and require explicit review
and confirmation before assignment to a host/account. The same review is offered
when a previously local host becomes cloud-bound. Incomplete recovered transfers
restart with fresh staging/temporary paths and no inherited overwrite approval;
old remote temporary files are left untouched. Completed downloads remain locally
exportable after confirmation. Assignment itself never starts a connection or
transfer. Cancelled, superseded or changed-account reviews cannot publish a late
staged copy, and a running transfer cannot be claimed by another browser. The
owner and reviewed checkpoint are rechecked before durable replacement; malformed
or newer owned envelopes cannot downgrade to legacy records.
Removing a download unlinks only its named local file and removes an empty
containing directory; it never recursively removes sibling files or a directory
which has replaced the downloaded file.

For upload, first stage an immutable local source in app-controlled storage. Create a uniquely named remote temporary file beside the destination. Use positioned writes, never append mode. Track the highest contiguous acknowledged offset, not the highest offset submitted.

For download, write into a local temporary file. Persist only its contiguous verified prefix and the associated remote identity metadata. Publish to a user-selected destination through the applicable platform document/file-access API after successful completion; do not assume a file-provider URL remains accessible indefinitely.

After reconnect, discard all old handles. Check metadata and compare SHA-256 of the complete retained prefix, reading it back through SFTP as necessary. Matching size/mtime alone is insufficient. On mismatch, restart into a new temporary file or require user intervention.

Before reporting completion, verify the entire staged content against the source, check close results, then rename/publish it. In v1, existing destinations require an explicit decision; do not silently overwrite them. Uncertain rename outcomes must be inspected before retrying.

This conservative read-back strategy may be expensive but needs no custom macOS checksum service. Supported transfers require a stable regular-file source; arbitrary concurrent modification is not supported. A successful SFTP write acknowledgment is not a power-loss durability guarantee.

Start with eight outstanding 32 KiB reads/writes and a bounded queue. Pause or reduce bulk work when terminal input is stalled. Separate connections avoid sharing the terminal's application stream, but still compete on the same network bottleneck.

Suspension-bound lifecycle transitions pause SFTP. Resume when permitted execution returns; no continuous suspended-app file-transfer guarantee is made. A Mac window losing focus alone does not pause a transfer; follow the actual lifecycle policy in §9.

Local hashing and upload staging must observe cancellation before queued execution and between bounded hash reads. Keep descriptor ownership until the queued job and its cleanup settle, and remove unpublished staging on cancellation. In-flight filesystem calls may finish before cancellation is observed; this does not promise a fixed settlement deadline.

## 11. Swift structure and ownership rules

```text
Sources/
  SessionCore/       IDs, policies, lifecycle, input ledger, transfer manifests
  SSHClient/         authentication, host trust, exec, SFTP codec/client
  ScreenProtocol/    RST messages, validation, snapshots, bounded scheduler
  AppleTransport/    QUIC, TLS identity policy, Network callbacks
  TerminalHost/      Swiftty adapter, macOS PTY ownership, semantic input
  TerminalSurface/   shared direct-client frame/input abstraction
  CompanionModel/    bounded watch/iPhone status DTOs; no SSH/RST secrets
Apps/
  MobileClient/      iOS/iPadOS full client and iPhone companion bridge
  CatalystClient/    UIKit-derived full remote client
  VisionClient/      windowed visionOS full remote client
  TVClient/          tvOS SSH/roaming terminal; no SFTP
  WatchCompanion/    watchOS SwiftUI status/preview; WatchConnectivity only
  rst-host/          native macOS bootstrap CLI, user agent, session registry
Tests/
  ProtocolTests/     generated fixtures, bounds, state-machine properties
  IntegrationTests/  OpenSSH, real PTY, two-endpoint network harness
```

Set `// swift-tools-version: 6.4` and Swift 6 language mode. Keep shared libraries non-main-actor-isolated by default. Only UI state/rendering belongs on `MainActor`. Keep the watch companion model independent of Swiftty, NIO, Network QUIC, and Darwin PTY code. Use per-target dependencies; platform-neutral source does not require Linux or Windows products.

Use one serialized owner for each terminal and input ledger. Keep NIO handlers on their event loop; cross isolation boundaries with immutable `Sendable` values. Do not transport raw file descriptors, mutable terminal buffers, or UI objects as casually unchecked-sendable state.

PTY and file operations require nonblocking I/O or bounded dedicated executors. A child task is not, by itself, a safe place for blocking system calls. Compression and screen capture cannot monopolize the UI or network executor.

Bound byte counts as well as message counts. Do not wrap networking in an unbounded `AsyncStream` and call it backpressure. Coalesce screen notifications; never coalesce or drop input operations.

Scope connection tasks to an attachment, but scope the host PTY task to the server session. Canceling one attachment must not cancel the shell. All close/cleanup paths are idempotent and deadline-bounded. Swift 6.4's async cleanup features may be used, but cannot substitute for deadlines. [S6]

### Production attachment ownership

`Apps/Shared/LiveTerminalSurface.swift` uses `RoamingScreenBackend` as the single
production binding for frames, semantic input, connection status, geometry and
explicit close. The application-owned `ClientSlot` and duplicate input pump are
removed. Interactive SSH trust, saved-host/credential selection, scene observation,
user prompts and ordered application lifecycle intent remain in the application.
The reusable attachment owns bounded ordering, mailbox/display delivery and its
client identity; do not add a third wrapper around parallel implementations.

Capture a semantic-input callback when input is submitted, not when a queued
operation eventually drains. An old operation must never follow a replacement
attachment. Each pump refers weakly to its original client, so it cannot redirect
input or retain a closed client through client → sink → display → pump. Close
fences the pump before awaiting lifecycle work. Retries retain workspace identity,
never create a replacement shell or replay uncertain input into another session,
and preserve existing trust/reconnect guarantees. Ordinary SSH fallback remains a
visibly separate connection-scoped shell. The same workspace and writer authority
serve native SMX and roaming RST attachments; see [architecture ownership](spec.md#architecture-and-ownership).

Implemented and validated 2026-11-01: `RoamingFrameNotificationTests` covers queued
input across attachment replacement for public and bounded submission, and client
release while a display retains its callback. Final admission/lifetime coverage
passed 10 tests; the full native integration bundle passed 790 tests in each
Debug/Release run. The shipping MobileClient Release build also passed for arm64
and arm64e. Overall evidence is in [spec.md](spec.md#shared-surface-implementation-and-validation--2026-11-01)
and [spec.apple.md A08](spec.apple.md#a08--memory-and-performance-txt-04-perf-01-appendix-a).
These checks do not replace the remaining platform-wide release matrix in §2.4.

## 12. Resource and security limits

| Resource | Proposed v1 limit |
|---|---|
| Host sessions / active writers | 8 per account / 1 per session |
| Grid | 200 columns × 80 rows maximum |
| Control record | 64 KiB decoded JSON |
| Snapshot | 4 MiB encoded and 4 MiB decoded maximum |
| In-flight snapshots | 2, plus one replaceable unsent reference |
| Client/server pending input | 64 KiB generated/pending data each; admission must account for expansion |
| Paste operation | 32 KiB committed UTF-8 maximum |
| Cell grapheme | 64 UTF-8 bytes; over-limit display uses a documented placeholder |
| Terminal title | 1 KiB; no executable interpretation |
| SFTP outstanding data | 8 × 32 KiB initially, full-client profile only |
| Watch companion payload | 16 KiB decoded maximum; one pending refresh; optional text preview off by default |
| Detached retention / token lifetime | 24 hours / maximum 8 hours |

Reject unsupported sizes explicitly. The renderer's style-table and cell counts must match grid bounds. Validate integer arithmetic before allocation. Enforce decoder nesting, compression-output, terminal-control-string, and malformed UTF-8 limits.

Disable terminal graphics, remote clipboard changes, remote URL opening, and filesystem actions carried by escape sequences. A server screen is untrusted presentation content even after SSH authentication.

Rate-limit unauthenticated handshakes and attachment attempts. Do not create PTYs on the basis of UDP packets alone. Rely on QUIC's address-validation and amplification protections, and independently cap application resources. [S10]

Do not expose a broad root service, silently alter firewall policy, auto-install unsigned helper code, or transmit application capabilities before peer authentication. Keep raw terminal capture opt-in and off by default. Hide the terminal in the app-switcher preview.

Internet reachability is a deployment prerequisite, not solved by this protocol. NAT traversal, public relays, and a VPN service are out of scope. A pre-existing reachable LAN/VPN or appropriately configured public endpoint is acceptable.

## 13. Acceptance tests

All tests below are release gates for their applicable platform profile unless labeled a target. A0/A17/A18 enforce the profile matrix; A1–A13 and terminal-related A16 apply to direct clients, while A14–A15 apply to full clients. Watch-only verification uses the companion tests rather than claiming direct SSH/RST support. Generate fixtures independently; no Mosh source, tests, packet captures, or protocol schemas are required.

| ID | Test | Required result |
|---|---|---|
| A0 | Verify the Apple OS 27 build and runtime matrix | All applicable deployment targets are 27.0; separately validate iOS/iPadOS, native macOS, Mac Catalyst, visionOS, tvOS, watchOS companion, and macOS helper under §2.4; record exact compiler, SDK, runtime, entitlements, and dependencies; no Linux/Windows builds required |
| A1 | Close the bootstrap SSH connection after attaching | The same host PTY and shell PID remain alive |
| A2 | Switch real iOS devices between Wi-Fi and cellular 50 times | Same retained session; no duplicate applied input; usable current screen after recovery |
| A3 | Inject loss, duplication, and reordering; kill connections at every input acknowledgment boundary | Applied input sequence matches the test oracle, without duplicated byte prefixes |
| A4 | Force partial PTY writes, output backpressure, and a blocked paste | Retries preserve exact unwritten suffix; no premature acknowledgment or silent discard |
| A5 | Produce continuous output through a 60-second outage | Host keeps draining output; recovery sends current state, not the outage history; memory remains bounded |
| A6 | Continuously mutate screen faster than delivery | Protected snapshots still finish; no cancellation starvation or old-frame regression |
| A7 | Resize repeatedly during alternate-screen use and reconnect | Correct final dimensions, cursor, buffer, and revision ordering |
| A8 | Run shell editing, `vim`, `less`, `top`, Unicode, combining marks, and wide characters | Server snapshot and client cell model agree for the supported profile |
| A9 | Trigger terminal queries and malicious clipboard/graphics/control sequences | Replies occur once on the host; unsupported side effects are blocked and buffers remain bounded |
| A10 | Background/unavailable-scene tests for mobile/spatial/TV clients; sleep and separate relaunch tests for the Catalyst Mac client | Warm or SSH-authorized cold reattachment to the same retained shell; losing Mac window focus alone does not detach; no claim of continued execution while suspended |
| A11 | Present wrong SSH key, wrong TLS pin, expired capability, old attachment epoch, or early input | Fail closed; no shell input accepted |
| A12 | Restart helper or reboot Mac | Client reports session loss; it never replays commands into a new shell automatically |
| A13 | Block UDP while leaving SSH reachable | Honest ordinary-SSH fallback; old roaming session is not presented as resumed |
| A14 | Interrupt SFTP after arbitrary requests; alter prefix; lose rename response | Correct resume or explicit restart/conflict; never falsely report a completed verified file |
| A15 | Concurrent file transfer and interactive typing | Bounded queues; bulk transfer can yield; no deadlock or cross-stream application blockage |
| A16 | Fuzz bootstrap, message decoder, decompressor, terminal parser, input state machine, and companion payload decoder | No unbounded allocation, crash, unauthorized operation, or invalid state transition |
| A17 | Exercise platform-specific profiles | Catalyst desktop input/file access, visionOS window/input/accessibility, and tvOS focus/keyboard/trust prompts pass; tvOS exposes no SFTP; no direct client has a local PTY; all direct clients use identical RST semantics |
| A18 | Pair physical Apple Watch and iPhone; force unreachable/stale state, lifecycle changes, malformed previews, and opt-out | Companion remains read-only; timestamps stay honest; no network credentials or RST lease exposed; bounds enforced; preview privacy honored; phone is not kept alive or logged in by watch refresh |
| A19 | Attempt attachment from two client platforms | The existing one-writer policy is enforced; rejected or replaced attachment cannot replay stale input; watch refresh creates no attachment |

**Recovery target, not a measured claim:** after a path becomes usable, warm reattachment plus an 80×24 current screen should complete within 3 seconds at p95 under 200 ms RTT, 5% independent loss, 2% reordering, and 1 Mbit/s available bandwidth. Test at least 100 recoveries. Exclude time during which neither endpoint has a usable path, but include handshake and application attachment.

Measure typing latency, data usage, CPU, wakeups, and memory separately. Do not reuse historical Mosh measurements as product benchmarks. Standard remote echo remains the v1 behavior.

## 14. Implementation gates and independent-development record

**Gate 0 — prove the Apple OS 27 platform boundary.** Resolve Swift 6.4 dependencies with the 27.0 deployment targets in §2.1; establish separate build paths for every included profile and pass applicable A0 checks. Demonstrate SSH host verification, no-PTY bootstrap, an independent host PTY, a pinned QUIC connection, multiple snapshot streams with cancellation, and terminal snapshot extraction through the adapter selected in Appendix A. Verify certificate/Keychain integration on every direct-client platform, including physical-device runs and the Mac Catalyst destination. Verify the separate watch/iPhone companion path without adding SSH/QUIC to the watch target. Do not add older-platform compatibility work. If a required Network API is unsuitable on the supported 27.x systems, revise this specification before replacing it with custom UDP security.

**Gate 1 — first vertical slice.** One configured host, one shell, full snapshot display, semantic keyboard input, resize, and explicit detach/reattach. Match server/client cell models. No prediction, deltas, or feature expansion.

**Gate 2 — client continuity correctness.** Input ledger, epoch fencing, partial writes, snapshot bounds, real handover where applicable, each client lifecycle/cold launch, and loss reporting. Pass applicable A0–A13, A16, and A19.

**Gate 3 — feature-profile completion.** Add the bounded SFTP subset on full clients, safe resume/publication, ordinary-SSH fallback UX on direct clients, and transfer interaction tests. Complete tvOS focus/input and the bounded read-only watch companion; pass A14–A18 where applicable. Freeze per-profile capabilities and dependency pins. Linux and Windows clients have no implementation gate in this revision.

Maintain the design-provenance record (Appendix B) citing the paper and public standards. Implement RST message formats, state machines, and fixtures in this project. Do not translate Mosh files, reuse its protobuf definitions, reproduce its prediction algorithm, or target its wire compatibility. Retain notices and audit licenses for all reused upstream libraries. This specification is not a formal clean-room certification or legal clearance.

**Version 1 is complete when every included platform meets its §2.1 profile: direct clients authenticate with SSH and recover the same retained shell/current screen; full clients safely resume regular-file transfers; the watch companion provides bounded, read-only, honestly timestamped status. No Mosh, tssh, tsshd, or trzsz installation is required.**

---

## Revision record

**2026-11-01 — Shared attachment implementation:** Record `RoamingScreenBackend`
as the production frame/input/lifecycle binding, with submission-time callback
identity and closed-client lifetime fencing. Incorporate the shared architecture
requirements into the owning specs; RST/1, trust and retention semantics are unchanged.

**v0.4 — 2026-10-10:** Fold the Swiftty integration addendum (Appendix A) and the design-provenance record (Appendix B) into this document. No requirement changes.

**v0.3 — 2026-10-10:** Expand the Apple-platform scope to include full Mac Catalyst and visionOS clients, a tvOS terminal-focused client, and a read-only watchOS/iPhone companion, all with 27.0 deployment minimums. Defer Linux and Windows clients per the latest instruction; require no non-Apple backend, renderer, CI, or packaging work. Keep the server native macOS-only, align platform profiles and acceptance gates, and reconcile the base terminal dependency with the Swiftty integration (now Appendix A). RST/1 wire semantics, host trust, input deduplication, and session retention are unchanged. No implementation builds or device tests were performed.

**v0.2 — 2026-10-10:** Restrict product support to iOS 27.x, iPadOS 27.x, and macOS 27.x; make 27.0 deployment minimums mandatory; remove older-platform compatibility work; add platform gate A0; align the Swiftty integration (now Appendix A). SSH/SFTP, RST/1, security, session-retention, and background-execution requirements are unchanged. No implementation or runtime validation was performed for this document update.

## Sources and evidence boundaries

Sources establish existing platform/protocol behavior. RST names, schemas, limits, scheduling, product scope, and acceptance targets are original design decisions in this proposal. Repository `main` pages describe inspected capabilities, not a tested dependency lockfile.

**[S1]** Keith Winstein and Hari Balakrishnan, *Mosh: An Interactive Remote Shell for Mobile Clients*, supplied draft; especially §§2–3.  
`https://mosh.org/mosh-paper-draft.pdf`

**[S2]** Apple Support, *Allow a remote computer to access your Mac*.  
`https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac`

**[S3]** Apple, SwiftNIO SSH README: supported features and client-building responsibilities.  
`https://github.com/apple/swift-nio-ssh`

**[S4]** SwiftTerm, *Building a Portable Terminal Host*: owned snapshots, rendering cells, semantic input, and terminal replies. Inspected document blob: `28c6e0b4671734716821db75117ca889302e7ce3` (a file-content identifier, not a package revision).  
`https://github.com/migueldeicaza/SwiftTerm/blob/main/Sources/SwiftTerm/Documentation.docc/PortableHosting.md`

**[S5]** Apple, Swift Crypto README: platform implementations and non-Swift backends.  
`https://github.com/apple/swift-crypto`

**[S6]** Swift.org, *Swift 6.4 Released*, September 15, 2026.  
`https://www.swift.org/blog/swift-6.4-released/`

**[S7]** Apple, Network framework *Security Options*: verification callbacks, TLS settings, and identity configuration.  
`https://developer.apple.com/documentation/network/security-options`

**[S8]** Apple, Security *Identities*, and `swift-certificates` README.  
`https://developer.apple.com/documentation/security/identities`  
`https://github.com/apple/swift-certificates`

**[S9]** RFC 9001, *Using TLS to Secure QUIC*, particularly the early-data and replay discussion.  
`https://www.rfc-editor.org/rfc/rfc9001`

**[S10]** RFC 9000, *QUIC: A UDP-Based Multiplexed and Secure Transport*, particularly streams, validation, and migration; Apple WWDC21, *Accelerate networking with HTTP/3 and QUIC*.  
`https://www.rfc-editor.org/rfc/rfc9000`  
`https://developer.apple.com/videos/play/wwdc2021/10094/`

**[S11]** RFC 9002, *QUIC Loss Detection and Congestion Control*.  
`https://www.rfc-editor.org/rfc/rfc9002`

**[S12]** RFC 1950, *ZLIB Compressed Data Format Specification version 3.3*.  
`https://www.rfc-editor.org/rfc/rfc1950`

**[S13]** Apple, `NWPathMonitor`.  
`https://developer.apple.com/documentation/network/nwpathmonitor`

**[S14]** Apple, *Choosing Background Strategies for Your App*.  
`https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app`

**[S15]** *SSH File Transfer Protocol*, `draft-ietf-secsh-filexfer-02`: the historical SFTP version 3 specification, not a final RFC.  
`https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02`

**[S16]** RFC 4254, *The Secure Shell (SSH) Connection Protocol*: session channels, subsystems, and channel lifecycle.  
`https://www.rfc-editor.org/rfc/rfc4254`


**[S17]** Swift Package Manager, `SupportedPlatform`: deployment minimums for iOS, macOS, Mac Catalyst, visionOS, tvOS, and watchOS. Consulted for this scope edit; not build validation.  
`https://docs.swift.org/latest/documentation/packagedescription/supportedplatform/`

**[S18]** Apple, `WCSession` and reachability callbacks: latest-state context, reachable-peer messaging, activation, and asynchronous delivery. The companion profile and its bounds are product decisions, not claims of a live transport guarantee.  
`https://developer.apple.com/documentation/WatchConnectivity/WCSession`  
`https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/sessionreachabilitydidchange(_:)`

**[S19]** Appendix A (Swiftty integration), pinned review of `chr33s/swiftty` at `32a57d8945db68a397a58ae3cbe75e63372ea242`; source references R1–R7 there. Existing declarations do not establish the new product ports.  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Package.swift`

---

## Appendix A. Swiftty integration

Formerly the companion Swiftty integration addendum (v0.3, 2026-10-10). It defines the Swiftty integration and supersedes terminal/frontend-specific choices in the main proposal. Section references of the form §A.n are to this appendix; plain §n references are to the main specification. Its source references R1–R12 are listed in §A.12.

**Repository inspected:** `chr33s/swiftty` at `32a57d8945db68a397a58ae3cbe75e63372ea242` (2026-10-07). **Validation at review time:** repository/source review only.

### A.1 Decision

Use **Swiftty as the terminal engine and presentation foundation** for the proposed SSH/SFTP and persistent-terminal product. It replaces the earlier proposal's SwiftTerm adapter and custom UIKit cell renderer for direct terminal clients. The watch companion uses a separate SwiftUI status/preview view, not Swiftty's renderer. Do not include two terminal engines by default.

This is a good architectural fit, but not a drop-in networking feature. Swiftty already has a terminal core, native macOS frontend, native iOS/iPadOS frontend, and an external byte-stream interface. The project still needs SSH/SFTP, RST/1, persistent host-session ownership, and a validated remote-snapshot interface. [R1–R4]

The product comprises:

| Product | v1 profile |
|---|---|
| iOS 27 / iPadOS 27 | Full SSH, SFTP, and roaming-terminal client |
| Mac Catalyst 27 on macOS 27 | Full remote client using a UIKit-derived frontend; no local PTY |
| visionOS 27 | Full remote client in a native window |
| tvOS 27 | SSH and roaming terminal; focus/keyboard UI; no SFTP |
| watchOS 27 + paired iPhone | Read-only status and optional bounded text preview over WatchConnectivity; no direct SSH/RST/SFTP |
| Native macOS 27 `rst-host` | Separate unprivileged helper retaining shells independently of clients |

The Mac can be a client, a server, or both. Its GUI app is not required to remain open for helper-owned sessions. The server remains native-macOS-only. Linux and Windows clients are deferred for now, with no port, build, test, or packaging requirements. Other unnamed platforms are not implicitly included.

These are product-scope requirements. Only the previously inspected source capabilities below are established; the added platform ports have not been implemented or validated.

### A.2 Verified integration points

| Area | Evidence in inspected source | Consequence |
|---|---|---|
| Shared terminal core | `SwifttyCore` library product; parser, terminal state, input encoding, snapshots | Reuse for ordinary SSH parsing and authoritative host emulation |
| iOS/iPadOS frontend | `SwifttyMobile`; public `TerminalUIView: MTKView` | Extend the existing frontend rather than starting a new mobile renderer |
| macOS frontend | `swiftty` executable using AppKit | Extend the application, or extract the AppKit frontend into a library for a new app |
| External byte transport | `TerminalSession.receive(_:)`, `onWrite`, `onTerminalReply` | Suitable connection boundary for conventional SSH, with bounded buffering and resize propagation added |
| Snapshot production | `TerminalSession.snapshot()` and `RenderSnapshot` | Provides data to map into RST/1, not a network serialization contract |
| Mobile app wiring | Reference app defaults to `DemoSource`; callers may inject a session | Networking and connection management remain application work |
| Platform declarations | macOS/iOS/Mac Catalyst/visionOS `27.0` in the inspected `Package.swift` | Those declarations align with four requested SDK families but do not prove app compatibility; tvOS is new direct-client integration work; watchOS uses a separate companion target without Swiftty |
| Swift settings | Manifest tools version 6.2; README pins Swift 6.4.0; experimental `Lifetimes` enabled | Resolve and validate the actual Swift 6.4 dependency/toolchain graph |

Sources: [R1–R6]. README performance and broad compatibility claims are not independently validated by this review.

### A.3 The three terminal paths

#### A. Local macOS shell

```text
macOS native view
    <-> local session adapter
    <-> Swiftty TerminalSession + local PTY
    <-> local shell
```

This uses Swiftty's existing macOS-only process path. An app-local session need not survive app termination; persistent remote sessions are owned by the helper instead. Swiftty's current `TerminalSession` deinitialization hangs up its owned PTY process, so object lifetime must not accidentally follow a remote connection. [R3]

#### B. Ordinary SSH on direct-client platforms

```text
SSH shell channel output
    -> bounded byte adapter
    -> TerminalSession.receive
    -> local parser and terminal state
    -> RenderSnapshot
    -> native view / MetalRenderer

native key, text, and paste input
    -> TerminalSession.send
    -> onWrite
    -> bounded SSH channel writer
```

Only terminal-session bytes enter this parser. SFTP data, SSH control messages, and nonterminal exec output use separate paths. Terminal replies also return over the relevant SSH session channel. Propagate view size changes to both the local emulator and the remote SSH PTY.

`receive(_:)` enqueues work and returns immediately. It is not a backpressure acknowledgment. Add a bounded adapter and an explicit parse-completion mechanism or equivalent serialized consumption; otherwise an asynchronous networking producer could fill the dispatch queue. [R3]

#### C. Roaming terminal on direct-client platforms

```text
macOS helper:
  persistent PTY output
    -> Swiftty authoritative parser/state
    -> owned ScreenSnapshot export
    -> RST/1 over QUIC

client:
  complete validated ScreenSnapshot
    -> RemoteScreenStore
    -> Swiftty-compatible render snapshot
    -> native view / MetalRenderer

client semantic input
    -> RST/1 input ledger
    -> server-side InputEncoder + tracked PTY writer
```

The roaming client is a presentation endpoint, not a second parser of the remote shell's output. Do not convert screen snapshots into synthetic ANSI, feed them to `receive`, or attempt to reconstruct hidden terminal state from the visible grid.

The host alone owns terminal mode negotiation, inactive buffers, query replies, and encoding of semantic input. This preserves the main specification's model and allows missed display updates to be discarded.

#### D. Read-only watch companion

```text
iPhone application
    -> latest observed, bounded session status / opt-in text preview
    -> WatchConnectivity
    -> SwiftUI watch view with capture time and stale/unavailable state
```

The watch does not enter either terminal backend, receive a full RST frame, encode terminal input, or open a host attachment. Refresh returns the latest iPhone-observed state. Keep the companion model and view independent of Swiftty/Metal, NIO/SSH, QUIC, and Darwin process targets. A paired/reachable phone is required for immediate updates; cached data remains explicitly stale when updates are unavailable. [R12]

### A.4 Required Swiftty adapter work

#### A.4.1 Frontend session interface

The inspected mobile view stores a concrete `TerminalSession` and installs its callbacks. This is useful for byte-stream terminals, but does not directly accept a remote screen store. [R4]

Use the project-owned `TerminalSurfaceBackend` abstraction with these responsibilities:

| Responsibility | Contract |
|---|---|
| Frame access | Return an immutable owned presentation frame |
| Invalidation | Notify the view that a newer frame exists without queuing every historical frame |
| Input submission | Accept semantic committed text, key, and paste events before terminal-byte encoding |
| Grid proposal | Submit requested columns/rows; keep authoritative resize revision distinct from local view geometry |
| Selection/copy | Operate on the displayed frame without mutating the host terminal |
| Capabilities | State whether scrollback, search, mouse reporting, and local PTY actions are supported |
| Lifecycle | Distinguish temporary attachment failure from actual session exit |

`LocalPTYBackend` serves native macOS, and `SSHStreamBackend`/`RoamingScreenBackend`
serve direct-client platforms. These are implemented package types. The public
direct-session embedding API remains supported; no universal public backend ABI
or replacement of every RST presentation session with a new frame type is required.
Use a separate read-only companion store, not a terminal backend, on watchOS.

Adapt the native AppKit view, UIKit-derived full-client views, and tvOS frontend, including their supported keyboard, selection, accessibility, search, and resizing extensions. Changing only the view initializer is insufficient: operations that currently reach into local terminal state need backend-specific behavior.

For RST/1 v1, selection/copy is current-viewport-only where the platform profile provides it. Disable unavailable history search, remote scrollback, mouse reporting, clipboard, and local-process actions rather than implying local emulator features automatically work remotely. iPad, Catalyst, and visionOS windows do not expand the one-active-roaming-terminal-per-client scope; a host session still has one writer across all platforms. The watch acquires no writer lease. Capability metadata must also gate SFTP/file access, semantic text input, and companion-only behavior.

#### A.4.2 Export semantic screen data, not memory layout

`RenderSnapshot` contains retained pooled storage, raw pointers, borrowed spans, cells with side-table references, and local rendering metadata. Its construction initializer and `SnapshotStorage` are internal to SwifttyCore. It is not an externally constructible network DTO. [R5]

Add an export adapter that produces the existing RST/1 `ScreenSnapshot` representation:

- Copy complete grapheme text, cell widths/continuations, and row-wrap information.
- Resolve palette, underline-color, and other internal table references into bounded semantic style values.
- Preserve cursor shape, visibility/blink as supported by the negotiated presentation profile, reverse-video state, dimensions, and revision identifiers.
- Copy only protocol-supported attributes; define the downgrade for unsupported attributes instead of silently advertising them.
- Exclude pointers, Swift object layout, GPU state, local glyph-atlas coordinates, local selection, and search highlights.

Do not send raw `Cell` memory, use a Swift ABI layout as a wire format, or retain borrowed spans across asynchronous work. Acquire an owned snapshot, copy the protocol representation while its storage is valid, and release the snapshot promptly. Network stalls must not retain the renderer's entire snapshot pool.

#### A.4.3 Import snapshots through a validated public boundary

Add a supported `SwifttyCore` builder/factory for an owned presentation frame, or generalize the renderer behind an equivalent project-owned frame adapter. Prefer one small public snapshot-import API over exposing mutable raw storage.

Validation precedes allocation and rendering: dimensions, cell/style counts, grapheme limits, valid widths and continuations, cursor bounds, colors, compression limits, attachment epoch, and screen/resize revisions.

A frame import replaces the entire visible state atomically. Preserve host row/cell layout; the client may change font size and request a resize, but must not independently reflow the authoritative frame.

Initially mark every imported frame as fully damaged. Swiftty's existing damage metadata describes changes relative to its own previous snapshot, which may not be the frame a remote client actually displayed. Dropped, superseded, or skipped frames invalidate that assumption. Later optimization may diff the new full frame against the last installed client frame.

Keep a client-local monotonically increasing render generation in addition to wire revisions. Fence stale attachments and invalidate renderer caches on session/geometry changes. A reconnect must not accidentally look like an unchanged frame because a local sequence counter repeats.

#### A.4.4 Intercept input before `onWrite`

Swiftty's `send` uses local terminal modes and keyboard flags to encode input, then calls the transport writer. That is appropriate for ordinary SSH, but too late for the proposed roaming protocol. [R3]

In roaming mode, route committed text, keys, and paste directly from the frontend input abstraction to RST/1. The host encodes each admitted operation once using authoritative modes and retains those exact bytes for partial-write recovery.

IME preedit remains a local overlay. Send only committed text. Predictive remote echo remains excluded. Software keyboard composition, hardware shortcuts, and paste all enter the same ordered semantic input path. Local copy and app commands remain local.

### A.5 Host I/O and lifetime changes

The helper can reuse Swiftty's parser/state and input encoder, but cannot treat a return from `TerminalSession.send` as proof that the PTY accepted the input. `send` is asynchronous; PTY output can remain in `pendingWrite`, and the current API has no per-operation completion acknowledgment. [R3, R7]

The preferred host integration uses an explicitly tracked PTY writer and the terminal core in externally fed mode, or adds equivalent completion/error hooks to Swiftty's PTY path. In either case:

1. One serialized owner coordinates terminal state, the input ledger, and PTY writes.
2. Every admitted operation is encoded once and retains a byte offset through partial writes.
3. `InputAck` advances only after the whole operation is accepted by the PTY or its resize completes.
4. Terminal-generated replies join the same ordered writer without being mistaken for user input or echoed back to the client.
5. A warm retry cannot reapply an accepted prefix; an I/O error cannot be reported as success.
6. The helper's session registry owns the shell, emulator, and ledger across attachment changes.

Snapshot notifications must not synchronously call `snapshot` from the session's own queue: the current implementation uses `queue.sync`. Schedule capture outside that queue, or provide a queue-local export method. Compression and network sends stay off the terminal owner and UI executor. [R3]

Headless operation must not construct a native view or require a Metal device. The existing package groups renderer and engine in `SwifttyCore`; splitting model/PTY/render targets is optional modularization, not a prerequisite to the first integration spike.

### A.6 Platform and packaging decision

**All requested Apple product profiles are in scope, each at a 27.0 deployment minimum.** Full clients: iOS/iPadOS, native macOS, Mac Catalyst, and visionOS. tvOS is an SSH/roaming terminal client without SFTP. watchOS is a read-only iPhone companion, not a direct terminal. §§2.1–2.4 define the authoritative support and validation matrix.

**Linux and Windows clients are deferred for now.** No portable socket backend, alternative non-Apple renderer, CLI client, CI destination, or packaging task is required for them. Platform-neutral data structures are permitted but do not imply a non-Apple deliverable. Earlier OS versions remain unsupported, and future major OS releases require explicit validation.

#### A.6.1 Shared code and dependency boundaries

Use Swift 6.4 in Swift 6 language mode. Platform-neutral model packages may declare the full matrix:

```swift
platforms: [
    .iOS("27.0"), .macOS("27.0"), .macCatalyst("27.0"),
    .visionOS("27.0"), .tvOS("27.0"), .watchOS("27.0"),
],
swiftLanguageModes: [.v6]
```

Specialized packages declare the relevant minimums and use target-level dependency separation. The native host depends only on macOS code. The watch companion depends only on its bounded shared model and SwiftUI/WatchConnectivity presentation; it MUST NOT link the direct-client networking stack, Swiftty renderer, or host process code. Align actual Xcode target settings with the 27.0 baseline. SwiftPM platform declarations configure minimum versions; they do not prove target compatibility. [R11]

The inspected Swiftty manifest declares macOS, iOS, Mac Catalyst, and visionOS, but not tvOS/watchOS. This is a pinned source observation, not a claim about a newer repository revision. Catalyst/visionOS app behavior still needs API and device validation. tvOS needs dependency resolution, source/API guards or modularization, and a platform-specific frontend. A `canImport(UIKit)` check alone does not prove that a particular UIKit API is available on tvOS or visionOS. Do not add watchOS to Swiftty merely to build a status companion. [R2, R4]

Separate reusable model/input/snapshot code from platform-specific views or process wrappers where needed. A reviewed Swift package adaptation or small upstream patch for an included Apple target is in scope; adding another terminal engine is not. Pin a tested toolchain/SDK/dependency graph. No Linux/Windows backend is needed to justify that modularization.

#### A.6.2 Platform adapters

| Target | Required integration |
|---|---|
| iOS/iPadOS | Existing mobile frontend plus external SSH/RST backends, document access, touch/hardware keyboard, and lifecycle recovery |
| Mac Catalyst | Adapt the UIKit frontend for desktop menus, shortcuts, pointer/window behavior, document access, entitlement checks, and Mac sleep (IOKit power notifications)/quit handling; no local PTY or embedded launchd agent |
| visionOS | Windowed native frontend sharing rendering/frame logic; validate text/keyboard input, focus, accessibility, resizing, and document access; immersive scenes deferred |
| tvOS | Focus-first shell/roaming frontend; tested external keyboard/text entry; explicit trust prompts; disable touch-only, clipboard, SFTP, and local-process actions that the profile does not provide |
| watchOS | Independent SwiftUI status/optional text-preview UI through the paired iPhone; no Swiftty frame import, host credentials, direct networking, or command execution |

For a new native Mac app, extract the reusable AppKit frontend into a library target rather than depending on an executable target as the public embedding API. For an extension of the existing app, retain its target and add backend/profile management there. A Catalyst build is a distinct product destination and does not reuse the macOS-only PTY path by accident.

The watch companion follows the main spec's 16 KiB payload limit, one pending refresh, explicit capture times, stale-state UI, and opt-in preview privacy. Latest-state application context carries only nonsensitive status; preview text uses bounded immediate foreground replies, stays in memory, and is never queued for background delivery. It reads only what the iPhone already observed and does not trigger login or reattachment. No new RST message or host observer API is required. WatchConnectivity's latest-state and reachable-peer modes fit this bounded exchange, but are not a guarantee of live or continuous delivery. [R12]

#### A.6.3 Lifecycle, files, and release evidence

Keep per-platform input, file-access, and lifecycle adapters instead of assuming identical UIKit behavior. Losing a Mac window's focus is not a disconnect event; sleep, termination, and network loss still need recovery. Mobile/spatial/TV unavailable scenes follow their validated suspension policy. The watch never keeps the phone alive. SFTP applies only to full clients, with the same resume/integrity requirements and platform-specific document access.

The 27.0 baseline does not remove optional-capability or later-27.x availability checks. Before claiming support, pass each destination's build, simulator where applicable, physical hardware, input, trust, snapshot, and lifecycle gates. Test native Mac and Catalyst separately; test visionOS/tvOS and a paired watch/iPhone on physical devices. Record exact runtimes, entitlements, and dependency revisions. Upstream platform declarations and simulator tests alone are not release evidence.

Application configuration, credentials, lifecycle, SFTP, and RST/1 remain outside SwifttyCore. Keep the integration from expanding into full tssh configuration compatibility or a new SSH server. The macOS helper is the sole server target.

### A.7 Safety and independence

The inspected mobile view handles a clipboard event by writing to `UIPasteboard`. The earlier spec disables remote clipboard writes, so introduce a policy gate before wiring real remote sessions to that handler. Disable remote URL/file actions and any protocol-unnegotiated terminal side effects as well. Local user-initiated copy remains available on profiles that implement it. On tvOS and other restricted input surfaces, hide unsupported actions instead of bypassing policy. The watch preview is opt-in and carries no credentials or executable actions. [R4]

Authenticate and validate RST frames before import. A trusted SSH identity does not make malformed screen dimensions, grapheme references, or compressed payloads safe.

Maintain independent RST/1 messages, fixtures, and implementation provenance. Reusing Swiftty does not require adopting Mosh's code or wire protocol. This review is not a source-provenance or license audit. GitHub repository metadata reported no detected license; establish redistribution rights and third-party notices before release, rather than assuming public visibility is sufficient. [R9, R10]

### A.8 Scope retained from the main specification

Unchanged: SSH trust and bootstrap; session-specific QUIC authorization; application input deduplication; retained macOS PTYs; reconnect after network loss; separate resumable SFTP; bounded snapshot scheduling; no prediction; no Mosh/tsshd compatibility.

Also unchanged: clients do not acquire indefinite background execution; full-client SFTP follows actual process/scene lifecycle rather than Mac window focus; the Mac must be reachable; VPN/relay/NAT traversal is not supplied by a terminal renderer; host restart is session loss rather than an instruction to replay commands. Added platforms share these guarantees without claiming identical APIs or full feature parity on tvOS/watchOS.

The implementation should retain all acceptance tests in the main specification. This addendum does not relax its security, input-ordering, or memory-bound guarantees.

### A.9 Integration acceptance gates

Gates apply according to the capability matrix: direct-terminal gates exclude watchOS; SFTP gates require every full client; companion-specific gates apply to watchOS/iPhone. Every included platform needs its own applicable evidence before release.

| Gate | Required outcome |
|---|---|
| Platform build | Swift 6.4 and applicable 27.0 minimums; distinct iOS/iPadOS, native macOS, Catalyst, visionOS, tvOS, watch companion, and native helper builds/device tests; satisfy A0/§2.4; no Linux/Windows build requirement |
| Plain SSH | Bidirectional shell input/output, correct query replies, resize propagation, clean exit, bounded buffering |
| Snapshot round-trip | Export/import preserves cells, graphemes, widths, colors, wraps, cursor, and supported attributes |
| Frame loss | Skip arbitrary intermediate revisions; newest complete snapshot renders correctly with no stale rows |
| Input mapping | Software keyboard, hardware keys, IME commit, control keys, and bracketed paste work in shell/vim/less/tmux |
| Input acknowledgment | Inject short writes and disconnects; no duplicated accepted prefix and no premature acknowledgment |
| Resize races | Rotation, keyboard display, and window resizing cannot let stale frames restore old geometry |
| Session lifetime | Destroy a client view/connection and reattach to the same host shell; helper-owned session remains alive |
| Safety policy | Remote clipboard/URL actions disabled; malformed and oversized snapshots rejected before rendering |
| Resource behavior | Blocked network does not exhaust snapshot storage, UI queues, terminal queues, or input bounds |
| SFTP independence | On full clients only, transfer bytes bypass terminal parsing and interrupted transfer resumes under the original integrity rules; tvOS/watchOS expose no SFTP UI |
| Platform input and lifecycle | Catalyst desktop handling, visionOS window/focus/input, and tvOS focus/keyboard verified; Mac (Catalyst) focus loss alone does not detach; A17 passes |
| Watch companion | Physical paired-device testing, explicit stale/capture-time display, 16 KiB bounds, one pending refresh, opt-in preview, and no credentials/input/login/host attachment; A18 passes |
| Cross-platform ownership | One host writer across direct-client types; stale epochs cannot inject input; watch refresh acquires no lease; A19 passes |

### A.10 Minimal delivery order

**First:** establish the Swift 6.4/27.0 build graph and isolated targets for all included Apple profiles. Connect ordinary SSH to the existing iOS/iPadOS and native Mac frontends, then adapt Catalyst, windowed visionOS, and tvOS. Validate keyboard/focus, resize, trust, entitlements, and bounded network adapters. The watch remains a separate non-network-terminal target.

**Second:** implement an in-process export/import round-trip and a remote-screen backend. Validate the presentation boundary before adding QUIC.

**Third:** run the server emulator in `rst-host`, add tracked PTY writes and RST/1 attachment, then test actual loss and foreground recovery.

**Fourth:** complete SFTP UI/resume on full clients and the read-only watch/iPhone companion. Pass all per-profile release gates, including physical devices, cross-platform writer ownership, and preview privacy. No Linux/Windows port, new host protocol, or additional terminal engine is required. Staged implementation does not remove Catalyst, visionOS, tvOS, or watchOS from product scope.

### A.11 Revision record

**v0.3 — 2026-10-10:** Include full Mac Catalyst and windowed visionOS clients, a tvOS SSH/roaming client without SFTP, and a read-only watchOS/iPhone companion. Require 27.0 deployment minimums for every included Apple target and per-profile build/device validation. Defer Linux and Windows clients per the latest instruction, including their backend/renderer/CI/packaging work. Keep `rst-host` native-macOS-only; align with v0.3. This is a document revision, not a new repository review, implemented port, or runtime validation.

**v0.2 — 2026-10-10:** Adopt iOS 27.x, iPadOS 27.x, and macOS 27.x as the exclusive product OS families with mandatory 27.0 minimums. Remove earlier-OS compatibility work, exclude upstream-only platforms from product scope, and align build/release gates with v0.2. Swiftty adapter, SSH/SFTP, RST/1, safety, and session-lifetime requirements are unchanged. This revision is a document update, not a new repository review or tested implementation.

### A.12 Sources

All Swiftty source paths below refer to revision `32a57d8945db68a397a58ae3cbe75e63372ea242`.

**[R1] README — architecture, platforms, external transport, toolchain, tests.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/README.md`

**[R2] Package manifest — products, platform minimums, experimental feature.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Package.swift`

**[R3] TerminalSession — receive/send, callbacks, queue ownership, lifecycle.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Session/TerminalSession.swift`

**[R4] TerminalUIView — concrete session dependency, native input, clipboard event handler.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyMobile/TerminalUIView.swift`

**[R5] RenderSnapshot — pooled storage, spans, internal initializer, damage.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Renderer/RenderSnapshot.swift`

**[R6] Mobile reference app — DemoSource and injectable terminal session.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyMobile/SwifttyMobileApp.swift`

**[R7] TerminalSession PTY writer — pending writes and completion behavior.**  
`https://github.com/chr33s/swiftty/blob/32a57d8945db68a397a58ae3cbe75e63372ea242/Sources/SwifttyCore/Session/TerminalSession.swift#L435-L503`

**[R8] Apple — native MetalKit views on macOS and iOS.**  
`https://developer.apple.com/documentation/metal/using-metal-to-draw-a-view%27s-contents`

**[R9] Repository metadata — license detection status at review time.**  
`https://api.github.com/repos/chr33s/swiftty`

**[R10] GitHub documentation — licensing a repository.**  
`https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository`


**[R11] Swift Package Manager — supported platform deployment minimums.**  
`https://docs.swift.org/latest/documentation/packagedescription/supportedplatform/`

**[R12] Apple — WCSession and companion reachability.** Latest-state context and reachable-peer messaging support the proposed bounded read-only companion; neither establishes continuous background delivery.  
`https://developer.apple.com/documentation/WatchConnectivity/WCSession`  
`https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/sessionreachabilitydidchange(_:)`

---

## Appendix B. Design provenance

Required by §14. Records where the roaming design and its implementation come from. It is not a clean-room certification or legal clearance.

### B.1 Ideas adopted from published work

| Idea | Source | How it is used |
|---|---|---|
| Server-authoritative terminal | Winstein & Balakrishnan, *Mosh* paper draft, §§2–3 [S1] | The SwiftMux service keeps the only parser of the PTY output; `TerminalHost` exports its current screen |
| Synchronising replaceable display state instead of a byte log | [S1] | Complete `ScreenSnapshot`s; missed screens are never replayed |
| Session survives network changes | [S1] | `swiftmux-agent` owns the PTY; clients reattach to its workspace by session ID |
| Speculative local echo | [S1] | **Not adopted** in v1 |

No Mosh source, tests, protobuf definitions, packet captures, prediction
algorithm or wire format were consulted or reproduced. RST/1 is not compatible
with Mosh, tssh, tsshd or trzsz.

### B.2 Public standards relied on

- QUIC transport, streams, address validation and migration: RFC 9000 [S10]
- TLS for QUIC, early data and replay: RFC 9001 [S9]; 0-RTT is disabled
- QUIC loss detection and congestion control: RFC 9002 [S11] (delegated to
  Network framework)
- zlib framing: RFC 1950 [S12]; raw DEFLATE encoding through the Compression
  framework and strict decoding through system zlib, with the 2-byte header
  and Adler-32 trailer handled in `ScreenProtocol/Zlib.swift`
- SSH connection protocol, session channels and subsystems: RFC 4254 [S16]
- SFTP version 3: `draft-ietf-secsh-filexfer-02` [S15]

### B.3 Original to this project

RST/1 message names and JSON schemas (`ScreenProtocol/ControlMessage.swift`),
the snapshot record format (`Framing.swift`), the bounded two-stream snapshot
scheduler (`SnapshotScheduler.swift`), the input ledger and its admission rules
(`SessionCore/InputLedger.swift`), the bootstrap envelope and grant
(`Bootstrap.swift`), all limits (`SessionCore/Limits.swift`), and all test
fixtures. Fixtures are generated by the tests themselves.

### B.4 Reused libraries (audit notices before release)

| Library | Use | License to verify |
|---|---|---|
| swift-nio, swift-nio-ssh, swift-nio-transport-services | SSH client, test SSH server | Apache 2.0 |
| swift-crypto, swift-certificates | Ed25519, SHA-256, X.509 host certificate | Apache 2.0 |
| swift-collections, swift-atomics, swift-asn1 (transitive) | | Apache 2.0 |
| Apple Network, Security, Compression, WatchConnectivity frameworks | Platform | Apple SDK terms |

Exact revisions are pinned in `Package.resolved`. Swiftty itself has no
detected repository license (§A.7); establish redistribution rights and
third-party notices before any release.
