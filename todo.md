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
  with `.closed` after 60 s. No stream was cancelled, so the 27.0.x reset abort
  does not explain it. Capture `withConnectionDiagnostics` output on recurrence;
  retain full native payloads, stream credit, flow-control settings and
  deadlines. Production: `Sources/AppleTransport/QUICRSTConnection.swift`.
- [ ] **Rejected QUIC stream:** investigate
  `QUICTransportTests.rejectedSnapshotStreamIsReleased`. A valid replacement failed
  with `.closed` after the client read 65,536 bytes and released the rejected
  stream; client control failed with POSIX 57 and the server group with POSIX 22
  (`EINVAL`). The trace lacks a peer application reason and complete lifecycle
  ordering. Keep this inbound-rejection case distinct from outbound cancellation.
- [ ] **QUIC cancellation result:**
  `QUICTransportTests.snapshot streams deliver complete payloads and drop a canceled one`
  returned `.closed` instead of `.canceled` once (2026-10-15, one issue in a
  594-test Integration run). No stage diagnostics were captured.
- [ ] **SSH setup delay:** investigate the channel-rejection case of
  `SSHShellControllerTests.failedSetupClosesItsAuthenticatedConnection` in
  `Tests/IntegrationTests/App/SSHShellControllerTests.swift`. Failed-phase polling
  timed out while the model remained `sshBootstrap` rather than `sessionLost`.
  Capture native setup and parent-connection progress on recurrence without
  extending the deadline.

## Source review and harness follow-ups

- [ ] Continue review of current source/app files. Geometry and physical-history
  reviews remain deferred under the recorded scope exclusions.
- [ ] Finish the QUIC snapshot admission/retirement review against the current
  FIN-and-delayed-retirement implementation in
  `Sources/AppleTransport/QUICRSTConnection.swift`.
- [ ] Review the changes merged since 2026-10-27, which the earlier review passes
  do not cover: scrollback compression, host-side history scrolling, the mobile
  keyboard lift and custom keyboard, JavaScript automation, JSONC config and
  `swsh`.

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
- [ ] Run the OS-gated QUIC reset test in CI: the `xcode-27` runner (macOS
  27.0.1) skips it, so it executes only locally on 27.2+.

## Terminal feature follow-ups

- [ ] Exercise the clipboard permission prompts and drag-and-drop by hand in
  the macOS app (mux panes) and the UIKit apps. Service tests cover the SMX
  round trips and paste events, and an app test covers an unprompted listing
  read; the prompts and native drags themselves are untested.
