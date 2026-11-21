import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

/// Model-based planned replacement (spec.durability.md §7): each seed picks
/// one fault and where it strikes. The guardian's outcome must match a
/// reference model, and the invariants hold whatever the outcome: one
/// outcome, the shell retained unless ended, a usable workspace when a
/// worker owns it, the old worker retired exactly when released.
@Suite(.serialized, .timeLimit(.minutes(4)))
struct MigrationModelTests {
  typealias Event = GuardianWorkerConnection.MigrationEvent

  enum Point: CaseIterable, Sendable {
    case welcome, freeze, export, importChunk, activate

    func matches(_ event: Event) -> Bool {
      switch (self, event) {
      case (.welcome, .welcome), (.freeze, .freeze), (.export, .export),
        (.importChunk, .importChunk), (.activate, .activate):
        true
      default: false
      }
    }
  }

  enum Fault: Sendable, CustomStringConvertible {
    case none
    case candidateLost(Point)
    case candidateHangs(Point)
    case corruptCheckpoint
    case oldWorkerDies(Point)
    case endBeforeRelease(Point)
    case oldNeverResumes

    var description: String {
      switch self {
      case .none: "none"
      case let .candidateLost(p): "candidate lost at \(p)"
      case let .candidateHangs(p): "candidate hangs at \(p)"
      case .corruptCheckpoint: "corrupt checkpoint"
      case let .oldWorkerDies(p): "old worker dies at \(p)"
      case let .endBeforeRelease(p): "End at \(p)"
      case .oldNeverResumes: "candidate hangs, old worker never resumes"
      }
    }

    /// The reference model.
    var expected: GuardianMigrationOutcome {
      switch self {
      case .none: .released
      case .candidateLost, .candidateHangs, .corruptCheckpoint: .resumed
      case .oldWorkerDies, .oldNeverResumes: .unavailable
      case .endBeforeRelease: .ended
      }
    }
  }

  /// SplitMix64: one seed, one scenario; `MIGRATION_SEED` replays one.
  struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func pick<T>(_ values: [T]) -> T {
      values[Int(next() % UInt64(values.count))]
    }
  }

  static func scenario(_ seed: UInt64) -> Fault {
    var g = Generator(state: seed)
    let candidatePoints: [Point] = [.welcome, .importChunk, .activate]
    let oldPoints: [Point] = [.freeze, .export, .importChunk]
    // Every fault kind recurs every seven seeds; where it strikes is random.
    switch seed % 7 {
    case 0: return .none
    case 1: return .candidateLost(g.pick(candidatePoints))
    case 2: return .candidateHangs(g.pick([.importChunk, .activate]))
    case 3: return .corruptCheckpoint
    case 4: return .oldWorkerDies(g.pick(oldPoints))
    case 5: return .endBeforeRelease(g.pick([.importChunk, .activate]))
    default: return .oldNeverResumes
    }
  }

  static var seeds: [UInt64] {
    if let value = ProcessInfo.processInfo.environment["MIGRATION_SEED"],
      let seed = UInt64(value)
    {
      return [seed]
    }
    return Array(0 ..< 21)
  }

  @Test(arguments: seeds)
  func outcomesMatchTheModel(seed: UInt64) async throws {
    let fault = Self.scenario(seed)
    let label = "seed \(seed): \(fault)"
    let rig = try MigrationTests.Rig(frozenTimeout: 0.6)
    defer { rig.close() }
    let oldFault: MigrationTests.Fault? = {
      switch fault {
      case let .oldWorkerDies(point) where point != .importChunk:
        return { [rig] event, forward in
          if point.matches(event) {
            DispatchQueue.global().async { rig.old.close() }
            return
          }
          forward(event)
        }
      case .oldNeverResumes:
        return { event, forward in
          if case .aborted = event { return }
          forward(event)
        }
      default: return nil
      }
    }()
    let started = try await MigrationTests.startForModel(
      rig,
      oldFault: oldFault
    )
    let workspace = rig.workspace
    let candidate: MigrationTests.Fault = { [rig] event, forward in
      switch fault {
      case let .candidateLost(point) where point.matches(event):
        DispatchQueue.global().async { rig.latestCandidate?.close() }
      case let .candidateHangs(point) where point.matches(event): break
      case .oldNeverResumes:
        if case .importChunk = event { break } else { forward(event) }
      case .corruptCheckpoint:
        if case let .importChunk(id, offset, total, bytes) = event {
          var bytes = bytes
          bytes[bytes.count / 2] ^= 0x5A
          forward(.importChunk(id, offset: offset, total: total, bytes: bytes))
        } else {
          forward(event)
        }
      case let .oldWorkerDies(point) where point == .importChunk:
        if point.matches(event) {
          DispatchQueue.global().async { rig.old.close() }
        } else {
          forward(event)
        }
      case let .endBeforeRelease(point) where point.matches(event):
        rig.guardian.endWorkspace(workspace)
      default: forward(event)
      }
    }
    let status = try await started.runtime.migrateWorkspace(
      .id(workspace),
      started: rig.candidate(fault: candidate)
    )
    // One recorded outcome, matching the model.
    #expect(status.phase == .finished, "\(label)")
    #expect(status.outcome == fault.expected, "\(label): \(status)")
    #expect(
      rig.retired.withLock { $0 } == (status.outcome == .released),
      "\(label)"
    )
    switch status.outcome {
    case .ended?:
      try await MigrationTests.waitFor("shell ended") {
        kill(started.shell, 0) != 0
      }
    case .unavailable?:
      // No unsupported recovery: processes retained, nothing promoted.
      #expect(kill(started.shell, 0) == 0, "\(label)")
      #expect(!rig.available, "\(label)")
    default:
      #expect(kill(started.shell, 0) == 0, "\(label)")
      await started.client.close()
      try await MigrationTests.expectUsableForModel(
        rig,
        started,
        tag: "m\(seed)"
      )
    }
    await started.client.close()
    await started.runtime.close()
  }
}
