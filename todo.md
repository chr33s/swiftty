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
  `Sources/AppleTransport/QUICRSTConnection.swift`.
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
  them as load-sensitive timing.
- [ ] **swroam escape under load:** `RoamingTerminalClientTests.escapeKTerminatesTheSession`
  hit its 10 s timeout once in a parallel Roaming/Runtime/Handover/Migration run
  (2026-11-19) and passed five of five alone.

## Source review and harness follow-ups

- [ ] Continue review of current source/app files. Geometry and physical-history
  reviews remain deferred under the recorded scope exclusions.
- [ ] Source candidate: an inbound QUIC stream that fails before `.ready`, or is
  refused in `adopt`/`classify`, may never return its stream credit
  (`QUICRSTConnection.swift`). Not reproduced deterministically.
- [ ] Review the changes merged since 2026-10-27, which the earlier review passes
  do not cover: scrollback compression, host-side history scrolling, the mobile
  keyboard lift and custom keyboard, JavaScript automation, JSONC config and
  `swsh`.
- [ ] Review the rest of the changes merged since 2026-11-14. The `SMXB/1`
  decoder, delta applier and baselines, `copySelection` and the `swroam` trust
  store and raw-mode paths were reviewed on 2026-11-19; the `RoamingKit`,
  `RoamingConnect` and `TTYKit` extractions and `PresentationSelection`
  remapping were not.
- [ ] Source candidates from that review, not reproduced: `swroam` leaves the
  terminal raw while stopped by an external `SIGTSTP` (Ctrl-Z itself goes to the
  remote session); `RoamingTerminalClient.run` returns without restoring raw mode
  if `outcome` is already set right after `tty.enter()`; `FrameValidator` accepts
  a negative `search.selected` from JSON that `SMXB/1` cannot encode.
- [ ] Performance candidate, not a defect: at 512×256, renderer import
  (2.1–2.3 ms p95 of about 4.9 ms) revalidates a frame that `SMXB/1` decode has
  already validated. Remove the second pass only if paired runs show a gain and a
  mutation test shows that invalid frames are still rejected.

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
- [ ] Finish [A20 and A22](spec.roaming.md#13-acceptance-tests). The in-process
  impaired link (`Tests/IntegrationTests/Host/ImpairedRSTLink.swift`) covers
  stream delay, reordering, reset and stale arrival, duplicated control records,
  kills at acknowledgement boundaries and mid-copy, and stripped features. Still
  open: packet-level loss and RTT over real QUIC at the recovery-target profile;
  a base refused naturally after the 2 s / 16-revision retention window rather
  than injected; and whether the Apple clients re-derive a selection after
  reconnecting, since row versions are per attachment.
- [ ] Report `screenDeltas` bytes per screen and client CPU, with and without
  deltas (both zlib-encoded), for 80×24 typing and 200×80 scrolling under the
  recovery-target network profile ([spec.roaming.md §13](spec.roaming.md#13-acceptance-tests)).
- [ ] Run the OS-gated QUIC reset test in CI: the `xcode-27` runner (macOS
  27.0.1) skips it, so it executes only locally on 27.2+.

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
