# Outstanding work

Reviewed against the working tree, regression tests and recorded review evidence
on 2026-11-05. This is the consolidated backlog from `fixme.md`, `handover.md`
and `todo.tests.md`; completed fixes and duplicate review narratives are omitted.
Source candidates are not reproduced defects. Historical failures remain open
until causal evidence establishes a fix; a passing rerun alone does not close them.
Evidence paths below identify original local artifacts, which may not be retained
on another machine. Test symbols are preferred to historical line numbers.
Pass 527 confirmed that the referenced pass 474 OSC, pass 470 launcher and
pass 334 QUIC logs are absent locally. Saved review summaries preserve those
observations, but are not substitutes for fresh causal traces. On 2026-11-05
none of the `/tmp` or `/private/tmp` review logs, platform reports or
`.xcresult` bundles cited below exist locally; the paths are kept as
provenance only. The pass 520–530 evidence also predates the work merged since
2026-10-27 (scrollback compression, host-side history scrolling, the mobile
keyboard lift and custom keyboard, JavaScript automation, JSONC config and
`swsh`) and does not cover it.

## Unresolved runtime failures

On 2026-10-27 every test below (and `TerminalParityTests`, which timed out
once under a full parallel run) was repeated 25–40 times with
`swift test --maximum-repetitions … --repeat-until fail` without a failure.
That does not close any item; it only shows they do not recur on demand.
`e7bad3d3` made the `TerminalParityTests` prompt cases wait for a title marker
printed after the last loop iteration, since a slow runner could act mid-loop;
that the race caused the earlier timeout is plausible but not established.

- [ ] **OSC background reply:** investigate `ProfileTests.themeUpdatesReportedDefaultColours`
  in `Tests/SwiftMuxTests/ProfileTests.swift`. Pass 474 observed `reply=''` after
  the unchanged five-second Bash read instead of `1212/3434/5656`.
  Preserve `/tmp/swiftty-review-pass474-native-all.log`. Bounded pane I/O and child
  read-status diagnostics now exist; pass 475 recorded all 24 reply bytes written
  and read, and parser coverage checks all 192 BEL/ST partitions. These do not
  identify the original loss. Capture ordered query, engine reply, accepted write,
  child read status and termios evidence on recurrence. Bash can discard a partial
  value on delimiter timeout; the PTY late-exit probe does not explain this failure.
- [ ] **Launcher report:** investigate `ReviewTests.hugeScrollsAreRefusedNotFatal`
  in `Tests/SwiftMuxTests/ReviewTests.swift`. Pass 470 failed during workspace
  creation, before scrolling, with `launchFailed: launcher: failed (/bin/sh)`
  after 0.004 seconds. Preserve `/tmp/swiftty-review-pass470-native-all-verified.log`.
  Report-write/validation fixes and bounded child-status/report-byte diagnostics
  in `PaneLauncher.swift` are implemented; the historical cause remains unknown.
  Capture those diagnostics on recurrence.
- [ ] **Oversized XPC record:** investigate `ConnectionTests.channelRejectsOversizedRecords`
  in `Tests/SwiftMuxTests/ConnectionTests.swift` and channel/listener ownership in
  `Sources/SwiftMuxProtocol/SMXChannel.swift`. Pass 313 repeated pass 164: two
  accepted channels, two 8-byte records, and one `record exceeds 16842752 bytes`
  close. This does not establish delivery after closure on one channel.
  Preserve `/private/tmp/swiftty-review-pass313-full.log`. Bounded per-channel
  traces and normal/held-client-callback cases exist, and `finish` cancels the
  native connection. Capture sender timing, reconnection and event-handler
  lifetimes; asynchronous XPC cancellation alone does not explain the recurrence.
  Excluded on 2026-11-05 (macOS 27.2, standalone raw-XPC probe): a third send
  delayed 50 ms past the listener-side cancellation does not reconnect an
  endpoint-created connection or reach a second accepted channel, with client
  callbacks held or not. Late-send reconnection therefore does not account for
  the second channel on 27.2; it is untested on earlier releases.
- [ ] **QUIC connection loss without cancellation:** on 2026-11-04 CI run
  41798355339 (release, macOS 27.0.1 runner) failed
  `QUICTransportTests.retiredSnapshotStreamIsReleased(cancel: false, bodyLength: 4194304)`
  with `.closed` after 60 s, before diagnostics existed. No stream was
  cancelled, so the 27.0.x reset abort below does not explain it.
  `withConnectionDiagnostics` (`e7bad3d3`) now records both ends' termination
  and lifecycle; capture that on recurrence. Retain full native payloads,
  stream credit, flow-control settings and deadlines. Production:
  `Sources/AppleTransport/QUICRSTConnection.swift`.
  Closed as an OS defect on 2026-11-05: the historical group aborts of passes
  317, 334 and 341 (cancellation, then `.closed` with control errors POSIX
  53/57). CI run 41803777888 captured the same signature on macOS 27.0.1 in
  `a reset partial stream is never delivered`, and this Mac ran 27.0/27.0.1
  from 2026-09-15 to 2026-10-31, covering those passes. The host runtime is
  documented as 27.2+ in [the roaming spec](spec.roaming.md#4-macos-deployment-and-session-lifetime)
  with no production mitigation; the test is enabled only on 27.2+, where 12
  repetitions of all 41 `QUICTransportTests` passed on 2026-11-05. Reopen if
  the 53/57 signature appears on 27.2 or later.
- [ ] **Rejected QUIC stream:** investigate
  `QUICTransportTests.rejectedSnapshotStreamIsReleased`. A valid replacement failed
  with `.closed` after the client read 65,536 bytes and released the rejected
  stream; client control failed with POSIX 57 and the server group with POSIX 22
  (`EINVAL`). The original trace lacks a peer application reason and complete
  lifecycle ordering. Keep this inbound-rejection case distinct from the outbound
  cancellation hypothesis.
- [ ] **QUIC cancellation result:** retain the 2026-10-15 failure of
  `QUICTransportTests.snapshot streams deliver complete payloads and drop a canceled one`:
  `.closed` instead of `.canceled`, one issue in a 594-test Integration run.
  No stage diagnostics were captured; the following focused pass does not close it.
- [ ] **SSH setup delay:** investigate the channel-rejection case of
  `SSHShellControllerTests.failedSetupClosesItsAuthenticatedConnection` in
  `Tests/IntegrationTests/App/SSHShellControllerTests.swift`. Failed-phase polling
  timed out while the model remained `sshBootstrap` rather than `sessionLost`;
  auth/channel cleanup assertions reported no further issue. Capture native setup
  and parent-connection progress on recurrence without extending the deadline.
## Source review and harness follow-ups

- [ ] Continue review of current source/app files; historical inventory hashes
  are not current coverage or proof of convergence. Geometry and physical-history
  reviews remain deferred under the recorded scope exclusions.
- [ ] Finish the QUIC snapshot admission/retirement review against the current
  FIN-and-delayed-retirement implementation in
  `Sources/AppleTransport/QUICRSTConnection.swift`.
## Platform and release validation

- [ ] Verify paired phone/watch continuity, signing and actual Handoff, plus
  physical backup/restore or migration. Backup-exclusion flags, simulator builds,
  publisher recovery, preview ownership and refresh-timeout tests do not establish
  those device behaviors.
- [ ] Complete platform runtime/UI, physical-device,
  signed CloudKit/Keychain propagation and deployment gates from
  [the roaming release matrix](spec.roaming.md#24-release-validation-matrix) and
  [the identity acceptance matrix](spec.ssh-identity.md).
  The macOS native Release suite reported a pass in pass 528 (2,726 tests across
  ten bundles, ten explicit skips; `/private/tmp/swiftty-review-pass528-native-release.log`).
  Pass 529 corrected its 22 unchecked QUIC polling results, preserving the
  five-second deadline and predicates. A temporary always-false condition passed
  before the change and failed afterward; it was removed before the final
  optimized transport run (56 reported tests, seven suites, one OpenSSH skip;
  `/private/tmp/swiftty-review-pass529-transport-release.log`). Pass 530 added
  native completed-history eviction cases with a held reader; all 13 retirement,
  cancellation and rejection cases passed with full payloads and unchanged
  deadlines (`/private/tmp/swiftty-review-pass530-retirement-final.log`). These
  healthy comparisons do not close the historical transport failures. All four
  real OpenSSH Release tests passed separately in pass 520. Preserve exact
  toolchain/platform evidence and distinguish disabled checks from executed tests;
  GitHub `Swift checks` passed on `ceb4c95c` and `Release Swiftty.app` built on
  2026-11-05, but the `xcode-27` runner (macOS 27.0.1) skips the OS-gated reset
  test above, so CI does not execute it;
  the five SessionRecorder fixture generators are not tests to blindly enable.
  Unsigned Release builds for iOS, Catalyst, visionOS, tvOS and watchOS passed
  and were audited in pass 521: OS 27.0 product minimums, unchanged source hashes,
  no app-source warnings and the watch dependency boundary. Evidence: `report.json`
  and `product-audit.json` in `/private/tmp/swiftty-review-pass520-platforms-b25duvc3`.
  These used Xcode Swift 6.4; native SwiftPM validation used mise Swift 6.4.1.
  The two original roaming UI tests passed on isolated iPhone and iPad OS 27.0 simulators
  in Release, with zero skips or failures. Results: `/tmp/rstr.uGlOD2/result.xcresult`
  (iPhone) and `/tmp/rstr.Z5W4LK/result.xcresult` (iPad). Dependency revisions matched
  the committed pins; fixtures and owned simulators were cleaned up. These cover
  SSH trust/rejection, shell commands, background/foreground recovery, SFTP
  browsing/dismissal and detach/resume. In pass 522, the roaming runtime test
  passed on fresh tvOS and visionOS 27.0 simulators with matching Release host
  and client builds, zero failures/skips/runtime warnings, unchanged source
  hashes and matching dependency pins. Results: `/tmp/rsts.esha8gze/result.xcresult`
  (tvOS) and `/tmp/rsts.871sb49q/result.xcresult` (visionOS). This verifies real
  QUIC, shell state and background/foreground reattachment through a local control
  socket and headless presentation sink; full app UI and SSH bootstrap are
  separate gates. The harness now accepts `--configuration debug|release`
  (default `debug`); all 21 harness tests passed.
  Pass 523 verified nested SFTP trust rejection and password cancellation twice
  each, browser dismissal, and subsequent root SSH sign-in/command output on
  iPhone and iPad in Release. The two regression methods are in
  `Tests/AppUITests/RoamingAppUITests.swift`. Pasted-code matching/mismatched-key
  flows also passed after correcting their host-list assertions to navigate back
  from Settings. Results: `/tmp/rstr.jS3XUH/result.xcresult` (four iPhone cases),
  `/tmp/rstr.R7EVUh/result.xcresult` (both iPad SFTP cases passed; matching-code
  assertion failed before its navigation fix), and `/tmp/rstr.lr5VLz/result.xcresult`
  (both corrected iPad pairing cases passed). Final executed cases had no skips
  or failures. UI sources pass
  strict-concurrency typechecking with warnings as errors; source hashes and
  dependency pins matched during the final runs. All owned fixtures/simulators
  were cleaned up. Pass 524 corrected missing orientation metadata in the
  generated UI test app: its built phone/iPad arrays match the shipping product,
  all eight wrapper tests passed, and both iPad pairing cases passed again with
  zero runtime warnings (`/tmp/rstr.R7TllH/result.xcresult`). The earlier two
  orientation warnings remain recorded in `/tmp/rstr.lr5VLz/result.xcresult`.
  This verifies metadata and the executed workflows, not an orientation/layout
  matrix. Nearby discovery/permission denial, camera/physical scanning,
  other platform UI/runtime, device, signing and propagation gates remain.

## Terminal feature follow-ups

The Ghostty [`a60e9e2`](https://github.com/ghostty-org/ghostty/tree/a60e9e2a57f73e1eef2bd1cf2995a467f69e7fb0/src)
parity checks for OSC 133 click options, DECRQCRA/XTCHECKSUM, the kitty
clipboard (OSC 5522, mode 5522), kitty drag-and-drop (OSC 72) and the extended
input modes are implemented in the engine and covered by the
`PromptClickTests`, `RectangleChecksumTests`, `KittyClipboardTests`,
`KittyDragAndDropTests` and `ExtendedInputModeTests` suites.
`rectangle-checksum-report` enables DECRQCRA. Clipboard reads that were not
handed over by a paste event prompt the user on macOS and iOS, and macOS,
iOS/iPadOS and visionOS take drops for registered programs. Keypad keys cross
SMX/2 (`ServiceFeatures.keypadKeys`) and RST/1 (`Attached.features`), with
main-keyboard fallbacks for older peers. SwiftMux panes forward kitty
clipboard requests to the macOS app (`kittyClipboard`) and take drops
(`dropTargets`). Remaining:

- [ ] Exercise the clipboard permission prompts and drag-and-drop by hand in
  the macOS app (mux panes) and the UIKit apps. Service tests cover the SMX
  round trips and paste events, and an app test covers an unprompted listing
  read; the prompts and native drags themselves are untested. Computer use was
  not available to drive them on 2026-10-27.

Not applicable on Apple platforms, so intentionally unsupported: the
primary selection (kitty clipboard `loc=primary` answers ENOSYS; macOS and
UIKit have no system primary selection) and NumLock reporting (Apple
keyboards have no NumLock, and neither AppKit nor UIKit exposes a NumLock
state; `numericPad` only marks keypad keys).
