#if os(macOS)
import Foundation
@testable import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwifttyEngine
@testable import TerminalHost
import Testing

/// A20 (spec.roaming.md §7.4, §13): `screenDeltas` between a real host
/// and a real `RoamingClient` over the A3 impaired path, with stream
/// cancellation and reattachment.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ImpairedScreenDeltaTests {
  static let seeds: [UInt64] = [0xA20_0001, 0xA20_0002, 0xA20_0003, 0xA20_0004]

  /// Repeats `request` until the newest installed screen satisfies
  /// `predicate`: a reattachment can drop a request (a history window
  /// belongs to its attachment).
  static func until(
    _ rig: some RoamingTestRig,
    _ what: String,
    request: () async throws -> Void,
    where predicate: @escaping (PresentationFrame) -> Bool
  ) async throws {
    for _ in 0 ..< 10 {
      try await rig.active()
      try await request()
      let shown = try? await hostEventually(what, timeout: .seconds(4)) {
        rig.installs.last.map(predicate) == true ? true : nil
      }
      if shown != nil { return }
    }
    Issue.record("\(rig.label): never showed \(what)")
    throw HostTestTimeout(what: what)
  }

  /// Scrolls toward older history until an installed screen satisfies
  /// `predicate`. Each step is shorter than the window and waits for the
  /// screen it caused, so every history row is shown at least once even
  /// when a reattachment resets the window to the tail (a history window
  /// belongs to its attachment) and shifts the alignment of later steps.
  static func scrollHistory(
    _ rig: some RoamingTestRig,
    _ what: String,
    step: Int,
    attempts: Int = 60,
    where predicate: @escaping (PresentationFrame) -> Bool
  ) async throws {
    func lines(_ frame: PresentationFrame?) -> [String] {
      frame.map { frame in (0 ..< frame.rows).map { frame.line($0) } } ?? []
    }
    let start = rig.installs.all.count
    for _ in 0 ..< attempts {
      try await rig.active()
      let before = lines(rig.installs.last)
      await rig.client.scrollViewport(by: step)
      // True: shown. False: this step's screen arrived without it.
      let shown = try? await hostEventually(what, timeout: .seconds(4)) {
        if rig.installs.all.dropFirst(start).contains(where: predicate) {
          return true
        }
        return lines(rig.installs.last) != before ? false : nil
      }
      if shown == true { return }
    }
    Issue.record("\(rig.label): never showed \(what)")
    throw HostTestTimeout(what: what)
  }

  /// Typing, scrolling, a progress bar, history moves, an alternate screen
  /// and resizes, with two forced kills at acknowledgement boundaries.
  static func workload(_ rig: some RoamingTestRig) async throws {
    // Typing, one key at a time.
    for ch in "echo key-$((6*7))" { try await rig.submit(.text(String(ch))) }
    try await rig.submit(.key(SemanticKey(.enter)))
    try await rig.shows("key-42")

    // Full-screen scrolling, fast then line by line. Lose the connection
    // just after the client acknowledges a screen.
    rig.loseConnection(at: .screenAck(afterForward: true))
    try await rig.run("seq 1 500; echo scroll-$((2+3))")
    try await rig.shows("scroll-5")
    try await rig.run(
      "i=0; while [ $i -lt 150 ]; do i=$((i+1)); echo line-$i; sleep 0.01; "
        + "done; echo slow-$((3+4))"
    )
    try await rig.shows("slow-7")

    // A carriage-return progress bar. Lose the connection just before the
    // client hears an input acknowledgement.
    rig.loseConnection(at: .inputAck(afterForward: false))
    try await rig.run(
      "i=0; while [ $i -lt 50 ]; do i=$((i+1)); printf '\\rprogress %d/50' "
        + "$i; sleep 0.01; done; echo; echo bar-$((4+5))"
    )
    try await rig.shows("bar-9")

    // History window moves: rows from history, then back to live.
    func showsHistory(_ frame: PresentationFrame) -> Bool {
      frame.rowKeys?.contains { $0[4] == 0 } == true
    }
    try await until(rig, "history window") {
      await rig.client.scrollViewport(by: 30)
    } where: {
      showsHistory($0)
    }
    try await scrollHistory(rig, "older history", step: 8) { frame in
      showsHistory(frame)
        && (0 ..< frame.rows).contains { frame.line($0) == "line-1" }
    }
    try await until(rig, "live output") {
      await rig.client.scrollViewport(by: -1000)
    } where: {
      $0.rowKeys?.allSatisfy { $0[4] == 1 } == true
    }

    // The alternate screen, resized while shown, then left.
    try await rig.run(
      "printf '\\033[?1049h\\033[2J\\033[HALT-%d' 77; read x; "
        + "printf '\\033[?1049l'; echo alt-$((5+6))"
    )
    try await rig.screen("alternate screen") { lines in
      lines.first?.hasPrefix("ALT-77") == true
    }
    #expect(rig.installs.last?.alternateScreen == true)
    try await until(rig, "alternate resize") {
      await rig.client.proposeGrid(columns: 48, rows: 10)
    } where: {
      $0.alternateScreen && $0.columns == 48 && $0.rows == 10
    }
    try await rig.submit(.key(SemanticKey(.enter)))
    try await rig.shows("alt-11")

    // Resizes on the primary screen.
    for (columns, rows) in [(70, 14), (60, 12)] {
      try await until(rig, "\(columns)x\(rows)") {
        await rig.client.proposeGrid(columns: columns, rows: rows)
      } where: {
        !$0.alternateScreen && $0.columns == columns && $0.rows == rows
      }
    }
    try await rig.run("echo end-$((6+7))")
    try await rig.shows("end-13")
  }

  @Test(arguments: seeds)
  func `every installed screen is the host's screen at that revision`(
    seed: UInt64
  ) async throws {
    try await withRegistry { registry in
      let grid = GridSize(columns: 60, rows: 12)
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: seed,
        profile: .a3Kills,
        grid: grid
      )
      try await rig.start(grid)
      try await Self.workload(rig)

      let link = rig.link
      let stats = await rig.client.deltaStatistics
      #expect(stats.applied > 0, "seed \(seed)")
      // Both forced kills happened, and the client reattached after each.
      #expect(link.killed.count >= 2, "seed \(seed)")
      #expect(link.connections >= 3, "seed \(seed)")
      // The impairments were exercised.
      let fates = link.snapshots.map(\.fate)
      #expect(fates.contains(.reset), "seed \(seed)")
      #expect(link.control.contains { $0.duplicate }, "seed \(seed)")
      // Every installed screen is the host's complete screen at a strictly
      // increasing revision: no partial, mixed or older screen is shown.
      let revisions = rig.expectInstallsMatchHost()
      #expect(
        revisions == revisions.sorted()
          && Set(revisions).count == revisions.count
      )
      await rig.client.close(.detach)
    }
  }

  @Test(arguments: seeds, [false, true])
  func `a missing base or checksum mismatch recovers through one full screen`(
    seed: UInt64,
    repeated: Bool
  ) async throws {
    try await withRegistry { registry in
      let grid = GridSize(columns: 60, rows: 12)
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: seed,
        profile: .a3,
        grid: grid
      )
      try await rig.start(grid)
      let link = rig.link
      // Every request repeated, as when several in-flight deltas are
      // refused: one full screen must still answer them all.
      if repeated { link.profile.duplicateRate = 1 }
      try await rig.run("echo ready-$((1+1))")
      try await rig.shows("ready-2")
      var typed = ""
      /// Types one key and waits for its echo and a quiet path.
      func key(_ ch: Character) async throws {
        typed.append(ch)
        let expected = "$ " + typed
        try await rig.submit(.text(String(ch)))
        try await rig.screen("echo of \(typed)") { $0.contains(expected) }
        try await Task.sleep(for: .milliseconds(300))
      }
      for (n, kind) in [ImpairedLink.Corruption.missingBase, .badChecksum]
        .enumerated()
      {
        try await key("a")
        let before = await rig.client.deltaStatistics
        let mark = link.snapshots.count
        link.corruptNextDelta(kind)
        try await key("b")
        try await hostEventually("corrupted delta delivered") {
          link.corrupted.count == n + 1 ? true : nil
        }
        try await key("c")
        try await key("d")
        let after = await rig.client.deltaStatistics
        let since = link.snapshots[mark...]
        let fulls = since.filter {
          !$0.delta && ($0.fate == .delivered || $0.fate == .lateAfterCancel)
        }
        // One refusal, answered by one complete screen, after which
        // deltas apply again.
        #expect(
          after.requestedFull - before.requestedFull == 1,
          "seed \(seed) \(kind): \(after) from \(before)"
        )
        #expect(
          fulls.count == 1,
          "seed \(seed) repeated \(repeated) \(kind): full screens \(fulls.map(\.revision)) in \(Array(since))"
        )
        let recovered = link.messages(.toHost)
          .filter { if case .requestFullScreen = $0 { true } else { false } }
        #expect(!recovered.isEmpty)
        #expect(after.applied > before.applied, "seed \(seed) \(kind)")
      }
      for _ in typed { try await rig.submit(.key(SemanticKey(.backspace))) }
      _ = rig.expectInstallsMatchHost()
      await rig.client.close(.detach)
    }
  }

  /// A base refused by the client's own retention, not injected: one
  /// `ScreenAck` reaches the host after the client's 2 s base lifetime,
  /// while a newer screen is already shown. The host's next delta names
  /// that aged base; the client refuses it once, full screens answer, and
  /// deltas resume.
  @Test
  func
    `a base aged out of the client's retention recovers through a full screen`()
    async throws
  {
    try await withRegistry { registry in
      let grid = GridSize(columns: 60, rows: 12)
      // No random impairment: the only cause of a refusal is the hold.
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: Self.seeds[0],
        profile: ImpairmentProfile(),
        grid: grid
      )
      try await rig.start(grid)
      let link = rig.link
      try await rig.run("echo ready-$((1+1))")
      try await rig.shows("ready-2")
      try await rig.run(
        "i=0; while [ $i -lt 12 ]; do i=$((i+1)); echo tick-$i; sleep 0.4; "
          + "done; echo done-$((1+2))"
      )
      try await rig.shows("tick-2")
      let before = await rig.client.deltaStatistics
      let mark = link.snapshots.count
      let hold = RoamingClient.frameBaseLifetime + .milliseconds(800)
      link.holdNextScreenAck(for: hold)
      try await rig.shows("done-3", timeout: .seconds(30))
      let after = await rig.client.deltaStatistics
      #expect(link.heldScreenAcks == 1)
      #expect(link.corrupted.isEmpty)
      #expect(
        after.requestedFull - before.requestedFull == 1,
        "\(after) from \(before); \(Array(link.snapshots[mark...]))"
      )
      let fulls = link.snapshots[mark...]
        .filter {
          !$0.delta && ($0.fate == .delivered || $0.fate == .lateAfterCancel)
        }
      // The host has no base until the replacement is acknowledged, so
      // output in that interval is also sent whole; then deltas resume.
      #expect(!fulls.isEmpty)
      let lastFull = try #require(fulls.last?.revision)
      #expect(
        link.snapshots[mark...]
          .contains {
            $0.delta && $0.revision > lastFull && $0.fate == .delivered
          },
        "full screens \(fulls.map(\.revision))"
      )
      #expect(after.applied > before.applied)
      _ = rig.expectInstallsMatchHost()
      await rig.client.close(.detach)
    }
  }

  enum MissingSide: String, CaseIterable, Sendable { case client, host }

  @Test(arguments: MissingSide.allCases, [seeds[0], seeds[1]])
  func `a peer without screenDeltas exchanges full screens only`(
    side: MissingSide,
    seed: UInt64
  ) async throws {
    try await withRegistry { registry in
      var profile = ImpairmentProfile.a3Kills
      // The client's list as the host sees it; for a host without the
      // feature, also the host's list as the client sees it.
      profile.stripFromAttach = [.screenDeltas]
      if side == .host { profile.stripFromAttached = [.screenDeltas] }
      let grid = GridSize(columns: 60, rows: 12)
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: seed,
        profile: profile,
        grid: grid
      )
      try await rig.start(grid)
      try await Self.workload(rig)
      let link = rig.link
      #expect(!link.snapshots.isEmpty)
      #expect(link.snapshots.allSatisfy { !$0.delta }, "seed \(seed) \(side)")
      let stats = await rig.client.deltaStatistics
      #expect(stats.applied == 0 && stats.requestedFull == 0)
      #expect(
        !link.messages(.toHost)
          .contains { if case .requestFullScreen = $0 { true } else { false } }
      )
      _ = rig.expectInstallsMatchHost()
      await rig.client.close(.detach)
    }
  }
}
#endif
