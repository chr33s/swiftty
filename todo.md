# Outstanding work

Open items only; completed fixes, passing validation runs and closed defects are
omitted. Source candidates are not reproduced defects. Historical failures remain
open until causal evidence establishes a fix; a passing rerun alone does not close
them. The review logs, platform reports and `.xcresult` bundles from the original
observations are not retained, so each item asks for a fresh causal trace. Test
symbols are preferred to historical line numbers.

## Unresolved runtime failures

None of these recurs on demand: on 2026-10-27 each was repeated 25–40 times with
`swift test --maximum-repetitions … --repeat-until fail` without a failure.

- [ ] **OSC background reply:** investigate `ProfileTests.themeUpdatesReportedDefaultColours`
  in `Tests/SwiftMuxTests/ProfileTests.swift`. Observed `reply=''` after the
  unchanged five-second Bash read instead of `1212/3434/5656`. Capture ordered
  query, engine reply, accepted write, child read status and termios evidence on
  recurrence. Bash can discard a partial value on delimiter timeout; the PTY
  late-exit probe does not explain this failure.
- [ ] **Launcher report:** investigate `ReviewTests.hugeScrollsAreRefusedNotFatal`
  in `Tests/SwiftMuxTests/ReviewTests.swift`. Failed during workspace creation,
  before scrolling, with `launchFailed: launcher: failed (/bin/sh)` after 0.004
  seconds. Capture the child-status/report-byte diagnostics in
  `PaneLauncher.swift` on recurrence.
- [ ] **Oversized XPC record:** investigate `ConnectionTests.channelRejectsOversizedRecords`
  in `Tests/SwiftMuxTests/ConnectionTests.swift` and channel/listener ownership in
  `Sources/SwiftMuxXPC/SMXChannel.swift`. Observed twice: two accepted channels,
  two 8-byte records, and one `record exceeds 16842752 bytes` close. This does
  not establish delivery after closure on one channel. Capture sender timing,
  reconnection and event-handler lifetimes; asynchronous XPC cancellation alone
  does not explain it, and late-send reconnection is excluded on macOS 27.2
  (untested on earlier releases).
- [ ] **QUIC connection loss without cancellation:** CI run 41798355339 (release,
  macOS 27.0.1) failed
  `QUICTransportTests.retiredSnapshotStreamIsReleased(cancel: false, bodyLength: 4194304)`
  with `.closed` after 60 s. The case does cancel a stream: `evictSentSnapshots`
  cancels stream 1 when stream 9 completes, bypassing delayed retirement. 60 s is
  the default QUIC idle timeout, and `sendSnapshot` has no deadline of its own,
  so the likeliest cause is a send stalled on stream or flow-control credit until
  idle close. The test now attaches the always-on lifecycle log, credit and
  configured QUIC limits on failure; compare client credit returns with the
  server's `remoteMaxStreams`/`opened` on recurrence. Production:
  `Sources/AppleTransport/QUICRSTConnection.swift`. A candidate cause was fixed
  on 2026-11-20: an inbound stream that failed before `.ready` or was refused
  never returned its credit, leaving the server one stream short for good
  ([spec.multiplexer.md §11](spec.multiplexer.md#follow-up-review-and-measurements--2026-11-20)).
  A leak cannot be confirmed as this run's cause without its log, so the item
  stays open until the failure is shown not to recur.
- [ ] **Rejected QUIC stream:** investigate
  `QUICTransportTests.rejectedSnapshotStreamIsReleased`. A valid replacement failed
  with `.closed` after the client read 65,536 bytes and released the rejected
  stream; client control failed with POSIX 57 and the server group with POSIX 22
  (`EINVAL`). The lifecycle log now records the peer's stream application code
  and orders group/control failures and deferred cancels on both sides; read it
  on recurrence. Keep this inbound-rejection case distinct from outbound
  cancellation.
- [ ] **QUIC cancellation result:**
  `QUICTransportTests.snapshot streams deliver complete payloads and drop a canceled one`
  returned `.closed` instead of `.canceled` once (2026-10-15, one issue in a
  594-test Integration run). Besides real termination, `.closed` on a live
  connection can only come from `NWConnection(from:)` returning nil, now logged
  as "stream creation failed"; the test attaches before/after diagnostics on
  failure.
- [ ] **SSH setup delay:** investigate the channel-rejection case of
  `SSHShellControllerTests.failedSetupClosesItsAuthenticatedConnection` in
  `Tests/IntegrationTests/App/SSHShellControllerTests.swift`. Failed-phase polling
  timed out while the model remained `sshBootstrap` rather than `sessionLost`.
  Capture native setup and parent-connection progress on recurrence without
  extending the deadline.
- [ ] **Native suite under load:** in the full native run recorded in
  [spec.multiplexer.md §11](spec.multiplexer.md#frames-deltas-and-live-selection--2026-11-19)
  (2026-11-19), two `AgentStartupTests` cases and one `ClipboardDropTests` case
  failed; each passed three of three runs alone. The failing case names and
  failure output were not recorded. Capture both on recurrence before treating
  them as load-sensitive timing. A full `Scripts/test-native.sh` run on
  2026-11-20 did not reproduce them; its only failures were four app tests
  that assumed one line per wheel unit after the default
  `mouse_scroll_multiplier` became 3 (fixed by pinning the multiplier).
- [ ] **swroam escape under load:** `RoamingTerminalClientTests.escapeKTerminatesTheSession`
  hit its 10 s timeout once in a parallel Roaming/Runtime/Handover/Migration run
  (2026-11-19) and passed five of five alone. It recurred in a full
  IntegrationTests run on 2026-11-20 (`RoamingTerminalTests.swift:263`, "the
  terminal client did not finish" after 10 s) and passed 15 of 15 alone.
- [ ] **Migration availability under load:** `MigrationTests.releaseKeepsTheShellItsStateAndItsScreen`
  once timed out waiting for an available workspace after release, in a
  parallel `SwiftMuxTests` run (2026-11-21), and did not recur in about 14
  later runs. `attach` now reports directory states, and the guardian
  inventory carries `lossReason`; capture both on recurrence.
- [ ] **Abandoned paste under load:** `ServiceTests.abandonedPasteClosesItsEnvelope`
  timed out waiting for its frame once in a parallel `SwiftMuxTests` run
  (2026-11-21) and passed five of five alone in about 3 s. Capture the paste
  envelope state and frame revisions on recurrence.
- [ ] **Clipboard and launcher reports under load:** in parallel
  `SwiftMuxTests` runs on 2026-11-21, `ClipboardDropTests` "controllers answer
  reads and programs receive the data" timed out once, and
  `PaneRegistrationTests.immediateRealLaunchesPreserveFinalOutputAndMetadata`
  once saw terminal bytes (`ESC[?2026h…`) in place of the launcher's success
  report. Neither touches planned replacement; capture the report bytes and
  the clipboard request order on recurrence.
- [ ] **Late encoding under load:** `HostSnapshotEncodingTests.lateEncodingCannotRetireOrDeliverIntoReplacementStream(fails: false)`
  failed once in the same 2026-11-20 full IntegrationTests run
  (`HostSnapshotEncodingTests.swift:194`, `streams.count == 1`: the
  replacement attachment's scheduler held more than one stream) and passed 15
  of 15 alone. Capture the stream list on recurrence.

## Source review and harness follow-ups

- [ ] Continue review of current source/app files. Geometry and physical-history
  reviews remain deferred under the recorded scope exclusions. Everything merged
  through 2026-11-21 (`70687e56`) has now had one pass; its fixes are recorded in
  [spec.multiplexer.md §11](spec.multiplexer.md#follow-up-review--2026-11-21).
- [ ] **Secure Enclave prompt and the connect deadline:** a Secure Enclave key
  that requires user presence signs on its connection's event loop, where the
  connect deadline is also scheduled. Since 2026-11-21 these connections use a
  one-loop group of their own, so other channels no longer stall, but a prompt
  longer than `connectTimeout` (20 s) still fails the connection after it
  returns, and the roaming start path prompts twice (probe, then bootstrap).
  Sign off the loop, or exclude prompt time from the deadline, and verify on a
  device (SE-02).
- [ ] **Real-installation qualification (UA8, signed UA4):** on a disposable
  Mac or account, transition an installed monolithic agent with a
  Developer ID-signed, notarized `SWIFTTY_DURABLE=1` package, reboot, and
  `swiftty --durable-sessions update` across two app versions, including a
  rollback ([spec.durability.md §13.73–§13.74](spec.durability.md)).
  Fixture-agent qualification (adoption, update, maintenance, restart,
  uninstall) passes.

## Platform and release validation

- [ ] Verify paired phone/watch continuity, signing and actual Handoff, plus
  physical backup/restore or migration. Backup-exclusion flags, simulator builds,
  publisher recovery, preview ownership and refresh-timeout tests do not establish
  those device behaviors.
- [ ] Complete the remaining gates from
  [the roaming release matrix](spec.roaming.md#24-release-validation-matrix) and
  [the identity acceptance matrix](spec.ssh-identity.md): nearby discovery and
  permission denial, camera/physical scanning, an orientation/layout matrix,
  full app UI and SSH bootstrap on tvOS and visionOS, physical devices, signing,
  and signed CloudKit/Keychain propagation. Preserve exact toolchain/platform
  evidence and distinguish disabled checks from executed tests.
- [ ] **Copy throughput over high-latency links:** since 2026-11-21 one
  copy chunk is in flight at a time (ping/pong fence, spec.roaming.md §7.5),
  which fixed typing over shaped QUIC: the echo arrives in 0.85 s and the input
  acknowledgement in 0.80 s, where they took 16–18 s and 1.3–2.2 s. A 2 MiB
  copy now takes 30 s instead of 17–18 s at 1 Mbit/s and 200 ms RTT, and one
  chunk per round trip caps fast long links (2 MiB in about 4.3 s at 100 ms
  RTT). Decide whether a two-chunk window, so typing waits behind up to two
  chunks, is an acceptable change to §7.5's one-chunk rule.
- [ ] **QUIC first-stream stall:** about 5–11% of shaped reconnects get a
  connection whose handshake completes but whose first stream data
  Network.framework holds until the connection closes (host lifecycle log:
  streams 0 and 4 arrive only at close). The client now abandons such an
  attempt after a short progress wait and retries at once (spec.roaming.md §9),
  so the recovery p95 is 2.3–2.8 s against the 3 s target, down from 16.5 s.
  The stall itself is unexplained. Reproduce it outside the app (two bare
  NWConnectionGroups under `Scripts/quic-shaper.sh`) and report it to Apple if
  it is Network.framework's.
- [ ] Rerun the whole shaped suite after any change to copy, attach or QUIC
  stream handling; it passed in full on 2026-11-21 with both fixes. Shaping
  needs root: `sudo Scripts/quic-shaper.sh up`, `Scripts/test-shaped-quic.sh`,
  then `sudo Scripts/quic-shaper.sh down`.
- [ ] Run the OS-gated QUIC tests in CI: the `xcode-27` runner (macOS 27.0.1)
  skips the stream-reset and migration tests. The `network-framework-27-2` CI job
  runs both on a self-hosted runner with `SWIFTTY_REQUIRE_OS_GATED=1`, which makes
  them run (and fail) rather than skip. It is inert until a macOS 27.2+ arm64
  runner labelled `macos-27-2` is registered and the repository variable
  `MACOS_27_2_RUNNER` is `true`. Both tests pass locally on 27.2.1 through that
  job's command.

## Terminal feature follow-ups

- [ ] Exercise the clipboard permission prompts and drag-and-drop by hand in
  the macOS app (mux panes) and the UIKit apps. Service tests cover the SMX
  round trips and paste events, and an app test covers an unprompted listing
  read; the prompts and native drags themselves are untested.
- [ ] Exercise live selection by hand: in a native mux pane, check that the
  overlay follows streaming output and that copying beyond the drawn frame works;
  in the macOS and iOS roaming apps, copy a selection that has been scrolled out
  of view.
- [ ] Use `swroam` interactively in several host terminals (Terminal.app,
  Ghostty, over `ssh`) across a Wi-Fi/Ethernet switch, sleep/wake, detach and
  `-r` resume, and a first-use host-key prompt. Automated coverage is the fake
  host over a real pty.
