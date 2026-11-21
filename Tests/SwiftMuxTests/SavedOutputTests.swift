import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Saved output (spec.durability.md §12.2, C1): the at-rest codec and the
/// worker's paged export (RS12, RS14).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SavedOutputTests {
  static func sample(rows: Int = 3) -> SavedOutput {
    SavedOutput(
      columns: 20,
      palette: (0 ..< 256).map { UInt32($0) },
      defaultForeground: 0xFFFFFF,
      defaultBackground: 0,
      styles: [
        .plain,
        SavedOutputStyle(
          foreground: 0x0100_0001,
          background: 0,
          underline: 0,
          flags: 1
        ),
      ],
      graphemes: [" ", "a", "漢", "👍🏽"],
      rows: (0 ..< rows)
        .map { index in
          SavedOutputRow(
            wrapped: index == 0,
            cells: [
              SavedOutputCell(grapheme: 1, width: 1, style: 1),
              SavedOutputCell(grapheme: 2, width: 2, style: 0),
              SavedOutputCell(grapheme: 3, width: 2, style: 0),
            ]
          )
        }
    )
  }

  @Test
  func codecRoundTripsAndRejectsMalformedInput() throws {
    let output = Self.sample()
    let data = try output.encoded()
    #expect(try SavedOutput(decoding: data) == output)
    #expect(output.text == "a漢👍🏽a漢👍🏽\na漢👍🏽\n")
    var truncated = data
    truncated.removeLast()
    #expect(throws: MuxError.self) { try SavedOutput(decoding: truncated) }
    var trailing = data
    trailing.append(0)
    #expect(throws: MuxError.self) { try SavedOutput(decoding: trailing) }
    // A cell naming a missing grapheme or style is refused before use.
    var bad = output
    bad.rows[0].cells[0].grapheme = 9
    #expect(throws: MuxError.self) {
      try SavedOutput(decoding: try bad.encoded())
    }
    var wide = output
    wide.rows[0].cells = Array(repeating: wide.rows[0].cells[1], count: 11)
    #expect(throws: MuxError.self) {
      try SavedOutput(decoding: try wide.encoded())
    }
    #expect(throws: MuxError.self) {
      try SavedOutput(decoding: Data("SMXO".utf8))
    }
  }

  private func worker() async throws -> (Harness, WorkspaceID) {
    let workspace = WorkspaceID()
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = workspace
    configuration.requiresGatewayBinding = true
    configuration.paneProcessFactory = { id, workspace, queue, limits in
      GuardianPTY(id: id, workspace: workspace, queue: queue, limits: limits)
    }
    let harness = try Harness(configuration: configuration)
    await withCheckedContinuation { continuation in
      harness.service.setGatewayPeer(getpid()) { continuation.resume() }
    }
    return (harness, workspace)
  }

  private func export(
    _ client: MuxConnection,
    pane: PaneID,
    since: UInt64?
  ) async throws -> (UInt64, SavedOutput?, pages: Int) {
    var bytes = Data()
    var offset = 0
    var pages = 0
    var revision: UInt64 = 0
    repeat {
      guard
        case let .savedOutputPage(page) = try await client.execute(
          .exportSavedOutput(
            pane: pane,
            ifChangedSince: offset == 0 ? since : nil,
            offset: offset
          )
        )
      else { throw MuxError(.invalidRequest, "missing page") }
      pages += 1
      revision = page.revision
      guard page.modified else { return (revision, nil, pages) }
      #expect(page.bytes.count <= SavedOutputPage.maxBytes)
      bytes.append(page.bytes)
      offset += page.bytes.count
      if offset >= page.total { break }
    } while true
    return (revision, try SavedOutput(decoding: bytes), pages)
  }

  private func waitForText(
    _ client: MuxConnection,
    pane: PaneID,
    contains marker: String
  ) async throws -> (UInt64, SavedOutput) {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      let (revision, output, _) = try await export(
        client,
        pane: pane,
        since: nil
      )
      if let output, output.text.contains(marker) { return (revision, output) }
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "output never appeared")
      }
      try await Task.sleep(for: .milliseconds(30))
    }
  }

  @Test
  func exportIsPagedBoundedAndReportsUnchangedOutput() async throws {
    let (harness, workspace) = try await worker()
    let gateway = try await harness.connect()
    defer { Task { await gateway.close() } }
    _ = try await gateway.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    let shown = try await gateway.attachAndShow(.id(workspace))
    let pane = shown.tabs[0].activePane
    // Lines with escapes the engine consumes: colour, an OSC 52 clipboard
    // write, an OSC 7501 status and an OSC 8 link. None survives as text.
    try await gateway.send(
      .text(
        "i=0; while [ $i -lt 2500 ]; do printf '\\033[31mline-%04d\\033[0m %s\\n' $i "
          + "'wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww'; "
          + "i=$((i+1)); done; printf '\\033]52;c;c2VjcmV0\\007\\033]8;;https://x.invalid\\007link\\033]8;;\\007 done-marker\\n'\r"
      ),
      to: pane
    )
    let (revision, output) = try await waitForText(
      gateway,
      pane: pane,
      contains: "done-marker"
    )
    #expect(output.rows.count == SavedOutput.maxRows)
    #expect(!output.text.contains("line-0000"))
    #expect(output.text.contains("line-2499"))
    #expect(!output.text.contains("c2VjcmV0"))
    #expect(!output.text.contains("x.invalid"))
    #expect(output.text.contains("link done-marker"))
    #expect(output.styles.contains { $0.foreground == 0x0100_0001 })
    // Unchanged since that revision: no bytes.
    let (again, unchanged, pages) = try await export(
      gateway,
      pane: pane,
      since: revision
    )
    #expect(again == revision && unchanged == nil && pages == 1)
    // Paging needs more than one record for this much output.
    let (_, _, paged) = try await export(gateway, pane: pane, since: nil)
    #expect(paged > 1)
    // The alternate screen is never exported.
    try await gateway.send(.text("printf '\\033[?1049h'; sleep 2\r"), to: pane)
    try await Task.sleep(for: .milliseconds(400))
    do {
      _ = try await export(gateway, pane: pane, since: nil)
      Issue.record("alternate screen exported")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
  }
}
