import SwiftMuxGuardian
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyEngine
import Synchronization
import TestSupport
import Testing

@Suite
struct EngineIdentityTests {
  func replies(
    _ input: String,
    configure: (inout TerminalState) -> Void
  ) -> String {
    var state = TerminalState(columns: 20, rows: 4)
    configure(&state)
    var parser = Parser()
    parser.consume(Array(input.utf8).span, into: &state)
    return String(decoding: state.output, as: UTF8.self)
  }

  @Test
  func identityFollowsConfiguration() {
    let out = replies("\u{1B}[>q\u{1B}P+q544e\u{1B}\\") {
      $0.terminalVersion = "swmux 0.2"
      $0.terminfoName = "swmux-256color"
    }
    #expect(out.contains("\u{1B}P>|swmux 0.2\u{1B}\\"))
    // XTGETTCAP TN = hex("swmux-256color")
    let hex = "swmux-256color".utf8.map { String(format: "%02X", $0) }.joined()
    #expect(out.uppercased().contains(hex))
  }

  @Test
  func disabledKeyboardProtocolIsNotOffered() {
    let off = replies("\u{1B}[>1u\u{1B}[?u") {
      $0.keyboardProtocolEnabled = false
    }
    #expect(off.isEmpty)
    let on = replies("\u{1B}[>1u\u{1B}[?u") { _ in }
    #expect(on == "\u{1B}[?1u")
  }

  @Test
  func clipboardCapabilityCanBeWithheld() {
    let hexMs = "Ms".utf8.map { String(format: "%02x", $0) }.joined()
    let off = replies("\u{1B}P+q\(hexMs)\u{1B}\\") {
      $0.clipboardWritesAdvertised = false
    }
    #expect(off.hasPrefix("\u{1B}P0+r"))
  }

  enum ReplyTerminator: CaseIterable, Sendable {
    case bell, string
    var sequence: String { self == .bell ? "\u{07}" : "\u{1B}\\" }
  }

  @Test(arguments: ReplyTerminator.allCases)
  func backgroundQueryKeepsItsTerminatorAcrossReadBoundaries(
    terminator: ReplyTerminator
  ) {
    let suffix = terminator.sequence
    let query = Array("\u{1B}]11;?\(suffix)".utf8)
    let expected = Array("\u{1B}]11;rgb:1212/3434/5656\(suffix)".utf8)
    // Every partition includes the one-byte and unsplit read cases.
    for mask in 0 ..< (1 << (query.count - 1)) {
      var state = TerminalState(columns: 20, rows: 4)
      var palette = state.palette
      palette.background = 0x12_34_56
      state.setDefaultPalette(palette)
      var parser = Parser()
      var replies: [UInt8] = []
      var start = 0
      for end in 1 ... query.count {
        if end != query.count, mask & (1 << (end - 1)) == 0 { continue }
        let chunk = Array(query[start ..< end])
        var offset = 0
        while offset < chunk.count {
          let consumed = chunk.withUnsafeBufferPointer {
            parser.consumePrefix(
              UnsafeBufferPointer(rebasing: $0[offset...]),
              into: &state,
              replyLimit: 1
            )
          }
          #expect(consumed > 0)
          guard consumed > 0 else { return }
          offset += consumed
          replies.append(contentsOf: state.output)
          state.output.removeAll(keepingCapacity: true)
        }
        start = end
      }
      #expect(replies == expected)
    }
  }
}

/// Reads a terminal reply inside the pane: raw mode, send the query, read
/// until `terminator`, print it escaped.
func probe(_ query: String, until terminator: String) -> LaunchSpec {
  var spec = shellLaunch()
  spec.command = [
    "/bin/bash", "-c",
    """
    trace() { if [ -n "$SWIFTTY_PROFILE_PROBE_LOG" ]; then printf '%s\\n' "$1" >> "$SWIFTTY_PROFILE_PROBE_LOG"; fi; }
    trace raw.begin
    stty raw -echo; trace "raw.status=$?"
    printf '\(query)'; trace "query.status=$?"
    IFS= read -r -s -d \(terminator) -t 5 r; trace "read.status=$?"
    if [ -n "$SWIFTTY_PROFILE_PROBE_LOG" ]; then printf 'read.reply=%q\\n' "$r" >> "$SWIFTTY_PROFILE_PROBE_LOG"; fi
    stty sane; trace "sane.status=$?"
    printf 'reply=%q\\n' "$r"; exec cat
    """,
  ]
  return spec
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InnerProfileTests {
  private func reply(
    _ h: Harness,
    _ c: MuxConnection,
    _ initialSpec: LaunchSpec,
    trace: ProfileIOTrace,
    name: String
  ) async throws -> String {
    var spec = initialSpec
    spec.environment["SWIFTTY_PROFILE_PROBE_LOG"] = trace.childLog(name).path
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    for _ in 0 ..< 200 {
      if let line = await h.service.screenLines(pane)?
        .first(where: { $0.hasPrefix("reply=") })
      {
        return line
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    return ""
  }

  @Test
  func programsSeeOneConsistentIdentity() async throws {
    try await withProfile("identity") { h, c, trace in
      let version = try await reply(
        h,
        c,
        probe("\\033[>q", until: "'\\\\'"),
        trace: trace,
        name: "version"
      )
      #expect(version.contains("swmux"))
      #expect(!version.contains("swiftty"))
      trace.expectDeliveredReply(containing: "swmux")
      // The kitty query gets no reply; the DA1 that follows does.
      let kitty = try await reply(
        h,
        c,
        probe("\\033[?u\\033[c", until: "c"),
        trace: trace,
        name: "kitty"
      )
      #expect(!kitty.contains("u"))
      #expect(kitty.contains("?"))
      trace.expectDeliveredReply(containing: "[?")
    }
  }

  @Test
  func themeUpdatesReportedDefaultColours() async throws {
    try await withProfile("theme") { h, c, trace in
      var colors = [UInt32](repeating: 0, count: 256)
      colors[1] = 0xAB_CD_EF
      try await c.execute(
        .setTheme(
          MuxTheme(
            palette: FramePalette(
              colors: colors,
              foreground: 0xEE_EE_EE,
              background: 0x12_34_56,
              cursor: 0xFF_FFFF
            ),
            dark: true
          )
        )
      )
      let bg = try await reply(
        h,
        c,
        probe("\\033]11;?\\007", until: "$'\\a'"),
        trace: trace,
        name: "theme"
      )
      #expect(bg.contains("1212/3434/5656"))
      trace.expectDeliveredReply(containing: "1212/3434/5656")
    }
  }

  private func withProfile(
    _ name: String,
    _ body: (Harness, MuxConnection, ProfileIOTrace) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("profile-probe-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let trace = ProfileIOTrace(directory: directory)
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.observePaneIO = { pane, event in trace.record(pane, event) }
    let harness = try Harness(configuration: configuration)
    let connection = try await harness.connect(.control)
    try await RuntimeFixture.withCleanup {
      try await body(harness, connection, trace)
    } cleanup: {
      trace.writeArtifact(name)
      await connection.close()
      await withCheckedContinuation { continuation in
        harness.service.prepareToExit { continuation.resume() }
      }
    }
  }

}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct BarrierAndTruncationTests {
  @Test
  func barrierRefusesMutationsButAllowsStatusAndEnding() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: "b", launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await c.execute(.quiesce(true))
    for command: MuxCommand in [
      .renameWorkspace(.id(ws.id), name: "x"),
      .split(pane: pane, axis: .leftRight, launch: nil),
      .newTab(name: nil, launch: nil), .renameTab(ws.tabs[0].id, name: "t"),
      .toggleZoom(ws.tabs[0].id),
    ] {
      do {
        try await c.execute(command)
        Issue.record("admitted at barrier: \(command)")
      } catch let e as MuxError { #expect(e.code == .quiescing) }
    }
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "unexpected reply")
    }
    try await c.execute(.endPane(pane))
  }

  @Test
  func forcedTerminationIsReportedAsTruncated() async throws {
    let h = try Harness()
    let c = try await h.connect()
    do {
      var stubborn = shellLaunch()
      stubborn.command = [
        "/bin/sh", "-c", "trap '' HUP; while :; do sleep 1; done",
      ]
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(launch: stubborn))
        )
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      let pane = ws.tabs[0].activePane
      try await c.attachAndShow(.id(ws.id))
      try await Task.sleep(for: .milliseconds(200))
      // A second tab keeps the workspace (and the attachment) alive.
      try await c.execute(.newTab(name: nil, launch: shellLaunch()))
      try await c.execute(.endPane(pane))
      var truncated: Bool?
      let deadline = ContinuousClock.now + .seconds(8)
      while truncated == nil, ContinuousClock.now < deadline {
        let event = try await withTimeout(deadline - ContinuousClock.now) {
          try await c.nextEvent()
        }
        guard let event else {
          throw MuxError(.connectionLost, "closed before forced exit")
        }
        if case let .paneExited(id, _, t) = event, id == pane { truncated = t }
      }
      #expect(truncated == true)
      try await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
    } catch {
      _ = try? await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
      throw error
    }
  }
}

private final class ProfileIOTrace: Sendable {
  struct Entry: Codable, Sendable {
    let elapsedSeconds: Double
    let pane: PaneID
    let phase: String
    let byteCount: Int
    let prefix: [UInt8]
    let error: Int32?
  }

  struct State: Sendable {
    var events: [Entry] = []
    var dropped = 0
  }

  let directory: URL
  private let start = ContinuousClock.now
  private let state = Mutex(State())

  init(directory: URL) { self.directory = directory }

  func childLog(_ name: String) -> URL {
    directory.appendingPathComponent(name + ".log")
  }

  func record(_ pane: PaneID, _ event: PaneIOObservation) {
    state.withLock { value in
      guard value.events.count < 512 else {
        value.dropped += 1;
        return
      }
      let duration = start.duration(to: .now).components
      value.events.append(
        Entry(
          elapsedSeconds: Double(duration.seconds) + Double(
            duration.attoseconds
          ) / 1e18,
          pane: pane,
          phase: event.phase.rawValue,
          byteCount: event.byteCount,
          prefix: event.prefix,
          error: event.error
        )
      )
    }
  }

  func expectDeliveredReply(containing needle: String) {
    let entries = state.withLock { $0.events }
    let generated = entries.filter {
      $0.phase == "replyGenerated"
        && String(decoding: $0.prefix, as: UTF8.self).contains(needle)
    }
    #expect(!generated.isEmpty)
    for reply in generated {
      let queued = entries.contains {
        $0.pane == reply.pane && $0.phase == "replyQueued"
          && $0.prefix == reply.prefix
          && $0.elapsedSeconds >= reply.elapsedSeconds
      }
      let written =
        entries.filter {
          $0.pane == reply.pane && $0.phase == "written"
            && $0.elapsedSeconds >= reply.elapsedSeconds
        }
        .flatMap(\.prefix)
      #expect(queued)
      let delivered = String(decoding: written, as: UTF8.self).contains(needle)
      #expect(delivered)
    }
    #expect(state.withLock { $0.dropped } == 0)
  }

  func writeArtifact(_ name: String) {
    guard
      let path = ProcessInfo.processInfo.environment[
        "SWIFTTY_PROFILE_TRACE_DIRECTORY"
      ]
    else { return }
    let frozen = state.withLock { $0 }
    do {
      let encoded = try JSONEncoder().encode(frozen.events)
      let events = try JSONSerialization.jsonObject(with: encoded)
      let logs = try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .reduce(into: [String: String]()) { result, file in
          result[file.lastPathComponent] = try String(
            contentsOf: file,
            encoding: .utf8
          )
        }
      let data = try JSONSerialization.data(
        withJSONObject: [
          "events": events, "dropped": frozen.dropped, "childLogs": logs,
        ],
        options: [.sortedKeys]
      )
      let destination = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true
      )
      try data.write(
        to: destination.appendingPathComponent(name + ".json"),
        options: .atomic
      )
    } catch { Issue.record("Profile evidence artifact: \(error)") }
  }
}
