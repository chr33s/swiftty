#if os(macOS)
import Darwin
import Foundation
@testable import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
@testable import TerminalHost
import Testing

/// spec.roaming.md §13: bytes per screen and client CPU, with and without
/// `screenDeltas` (both zlib-encoded), for 80×24 typing and 200×80
/// scrolling over the A3 impaired path. A report, not a gate: run with
/// `SWIFTTY_DELTA_REPORT=1`.
@Suite(
  .serialized,
  .timeLimit(.minutes(10)),
  .enabled(
    if: ProcessInfo.processInfo.environment["SWIFTTY_DELTA_REPORT"] != nil
  )
)
struct ScreenDeltaCostReport {
  enum Workload: String, CaseIterable, Sendable {
    case typing80x24
    case scrolling200x80

    var grid: GridSize {
      switch self {
      case .typing80x24: GridSize(columns: 80, rows: 24)
      case .scrolling200x80: GridSize(columns: 200, rows: 80)
      }
    }

    func run(_ rig: some RoamingTestRig) async throws {
      switch self {
      case .typing80x24:
        // A prompt-level line typed one key at a time, three times.
        for round in 1 ... 3 {
          for ch in "echo the quick brown fox jumps over the lazy dog \(round)"
          { try await rig.submit(.text(String(ch))) }
          try await rig.submit(.key(SemanticKey(.enter)))
          try await rig.shows("lazy dog \(round)")
        }
      case .scrolling200x80:
        try await rig.run("seq 1 3000; echo fast-$((2+3))")
        try await rig.shows("fast-5")
        try await rig.run(
          "i=0; while [ $i -lt 200 ]; do i=$((i+1)); "
            + "echo scrolled line $i of output; sleep 0.01; done; "
            + "echo slow-$((3+4))"
        )
        try await rig.shows("slow-7", timeout: .seconds(60))
      }
    }
  }

  struct Row: CustomStringConvertible {
    var workload: Workload
    var deltas: Bool
    var screens: Int
    var deltaScreens: Int
    var bytes: Int
    var cpuMicroseconds: Double

    var description: String {
      let perScreen = screens == 0 ? 0 : bytes / screens
      let cpu = screens == 0 ? 0 : cpuMicroseconds / Double(screens)
      return "\(workload.rawValue) deltas=\(deltas ? "on " : "off"): "
        + "\(screens) screens (\(deltaScreens) deltas), "
        + "\(bytes) bytes, \(perScreen) B/screen, "
        + String(format: "client CPU %.1f µs/screen", cpu)
    }
  }

  @Test(arguments: Workload.allCases)
  func report(workload: Workload) async throws {
    var rows: [Row] = []
    for deltas in [false, true] {
      try await withRegistry { registry in
        var profile = ImpairmentProfile.a3
        if !deltas { profile.stripFromAttach = [.screenDeltas] }
        let rig = ImpairedRoamingRig(
          registry: registry,
          seed: 0xD17A_0001,
          profile: profile,
          grid: workload.grid
        )
        rig.link.capturePayloads()
        try await rig.start(workload.grid)
        try await workload.run(rig)
        let delivered = rig.link.snapshots.filter {
          $0.fate == .delivered || $0.fate == .lateAfterCancel
        }
        rows.append(
          Row(
            workload: workload,
            deltas: deltas,
            screens: delivered.count,
            deltaScreens: delivered.filter(\.delta).count,
            bytes: delivered.reduce(0) { $0 + $1.bytes },
            cpuMicroseconds: Self.clientCPU(delivered.compactMap(\.payload))
          )
        )
        await rig.client.close(.detach)
      }
    }
    for row in rows { print("screenDeltas report: \(row)") }
    #expect(rows.allSatisfy { $0.screens > 0 })
    #expect(rows.last?.deltaScreens ?? 0 > 0)
  }

  /// Thread CPU for the client's per-record work, as `RoamingClient` does
  /// it off the actor: decode, validate, apply a delta to its base, and
  /// map to a presentation. Median of repeated replays, in microseconds.
  static func clientCPU(_ records: [[UInt8]]) -> Double {
    func cpuNow() -> Double {
      var t = timespec()
      clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
      return Double(t.tv_sec) * 1e6 + Double(t.tv_nsec) / 1e3
    }
    var samples: [Double] = []
    for _ in 0 ..< 15 {
      var bases: [UInt64: PaneFrame] = [:]
      let start = cpuNow()
      for record in records {
        switch RoamingClient.decodeRecord(record) {
        case let .screen(decoded)?:
          // RST/1 frames carry their revision in the record header.
          if let frame = decoded.paneFrame {
            bases[decoded.snapshot.screenRevision] = frame
          }
        case let .delta(delta, header)?:
          guard let base = bases[delta.baseRevision],
            let frame = try? FrameDeltaApplier.apply(
              delta,
              to: base,
              limits: SnapshotFrame.frameLimits
            ), let decoded = RoamingClient.screen(frame, header: header)
          else { continue }
          // RST/1 frames carry their revision in the record header.
          if let frame = decoded.paneFrame {
            bases[decoded.snapshot.screenRevision] = frame
          }
        case nil: continue
        }
      }
      samples.append(cpuNow() - start)
    }
    return samples.sorted()[samples.count / 2]
  }
}
#endif
