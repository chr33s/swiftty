import Foundation
import MuxAttention
import SwiftMuxProtocol
import Testing
import TestSupport

/// `AttentionInbox` planned-replacement checkpoints (spec.durability.md
/// §6): after random status traffic and acknowledgements, a restored
/// inbox reports the same items and checkpoints canonically.
struct AttentionCheckpointPropertyTests {
  enum Op: CustomStringConvertible {
    case report(pane: Int, path: Int, state: AttentionState, text: Int)
    case removed(pane: Int, paths: [Int])
    case sync(pane: Int, records: [Int])
    /// A terminal reset: the pane continues under a new epoch.
    case reset(pane: Int)
    case exited(pane: Int)
    case seen(item: Int)
    case snooze(item: Int, seconds: Int)
    case review(item: Int)
    case expire
    case wait(seconds: Int)
    case flush

    var description: String {
      switch self {
      case let .report(pane, path, state, text):
        "report(\(pane) \(paths[path]) \(state) \(text))"
      case let .removed(pane, paths): "removed(\(pane) \(paths))"
      case let .sync(pane, records): "sync(\(pane) \(records))"
      case let .reset(pane): "reset(\(pane))"
      case let .exited(pane): "exited(\(pane))"
      case let .seen(item): "seen(\(item))"
      case let .snooze(item, seconds): "snooze(\(item) \(seconds)s)"
      case let .review(item): "review(\(item))"
      case .expire: "expire"
      case let .wait(seconds): "wait(\(seconds)s)"
      case .flush: "flush"
      }
    }
  }

  static let paths = ["", "build", "build/test", "deploy", "x/y"]
  static let states: [AttentionState] = [
    .idle, .working, .done, .blocked, .error,
  ]
  static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  static func id<Tag>(_ n: Int) -> MuxID<Tag> {
    MuxID(String(format: "00000000-0000-0000-0000-%012X", n))!
  }

  /// Small bounds, so per-pane record eviction, resolved history and the
  /// text budget all take part.
  static var limits: MuxLimits {
    var limits = MuxLimits.standard
    limits.statusRecordsPerPane = 3
    limits.resolvedHistory = 6
    limits.statusTextBytes = 3_000
    return limits
  }

  static func record(
    path: Int,
    state: AttentionState,
    text: Int
  ) -> StatusRecord {
    StatusRecord(
      path: paths[path],
      state: state,
      kind: state == .blocked ? .question : nil,
      progress: text % 3 == 0 ? UInt8(text % 101) : nil,
      app: text % 4 == 0 ? "app\(text)" : nil,
      title: text % 5 == 0 ? "title 漢" : nil,
      message: text % 2 == 0 ? "message \(text) é" : nil
    )
  }

  static func generate(_ random: inout PropertyRandom) -> [Op] {
    random.array(count: random.int(in: 1 ... 60)) { random in
      let pane = random.int(3)
      switch random.int(100) {
      case ..<45:
        return .report(
          pane: pane,
          path: random.int(paths.count),
          state: random.element(of: states),
          text: random.int(1_000)
        )
      case ..<50:
        return .removed(
          pane: pane,
          paths: random.array(count: random.int(in: 1 ... 2)) {
            $0.int(paths.count)
          }
        )
      case ..<54:
        return .sync(
          pane: pane,
          records: random.array(count: random.int(in: 0 ... 3)) {
            $0.int(paths.count * states.count)
          }
        )
      case ..<57: return .reset(pane: pane)
      case ..<59: return .exited(pane: pane)
      case ..<67: return .seen(item: random.int(64))
      case ..<74:
        return .snooze(item: random.int(64), seconds: random.int(in: 0 ... 90))
      case ..<81: return .review(item: random.int(64))
      case ..<84: return .expire
      case ..<92: return .wait(seconds: random.int(in: 1 ... 60))
      default: return .flush
      }
    }
  }

  static func all(_ box: AttentionInbox, at now: Date) throws -> [AttentionItem]
  {
    var items: [AttentionItem] = []
    var cursor: String?
    repeat {
      let page = try box.page(
        InboxQuery(section: .all, cursor: cursor, limit: 100),
        at: now
      )
      items += page.items
      cursor = page.nextCursor
    } while cursor != nil
    return items
  }

  /// Runs `ops`, flushes, and returns the inbox with the clock.
  static func drive(_ ops: [Op]) throws -> (AttentionInbox, Date) {
    var box = AttentionInbox(serviceEpoch: id(9_000), limits: limits)
    let context = AttentionContext(workspace: id(9_001), tab: id(9_002))
    var epochs = [0, 1, 2].map { 100 + $0 }
    var now = t0
    for op in ops {
      func apply(_ pane: Int, _ changes: [StatusChange]) {
        box.apply(
          changes,
          pane: id(pane),
          epoch: id(epochs[pane]),
          context: context,
          at: now
        )
      }
      func ref(_ n: Int) throws -> AttentionReference? {
        let items = try all(box, at: now)
        guard !items.isEmpty else { return nil }
        let item = items[n % items.count]
        return AttentionReference(
          source: item.source,
          occurrence: item.occurrence
        )
      }
      switch op {
      case let .report(pane, path, state, text):
        apply(pane, [.report(record(path: path, state: state, text: text))])
      case let .removed(pane, indexes):
        apply(pane, [.removed(indexes.map { paths[$0] })])
      case let .sync(pane, records):
        var listed: [String: StatusRecord] = [:]
        for n in records {
          let r = record(
            path: n % paths.count,
            state: states[n / paths.count],
            text: n
          )
          listed[r.path] = r
        }
        apply(pane, [.sync(listed.keys.sorted().map { listed[$0]! })])
      case let .reset(pane):
        epochs[pane] += 3
        apply(pane, [])
      case let .exited(pane): box.paneExited(id(pane), at: now)
      case let .seen(n): if let ref = try ref(n) { box.markSeen(ref, at: now) }
      case let .snooze(n, seconds):
        if let ref = try ref(n) {
          box.snooze(ref, until: now + TimeInterval(seconds), at: now)
        }
      case let .review(n):
        if let ref = try ref(n), box.item(ref.occurrence)?.category != .needsYou
        {
          _ = try box.markReviewed(ref, at: now)
        }
      case .expire: box.expireSnoozes(at: now)
      case let .wait(seconds): now += TimeInterval(seconds)
      case .flush: _ = box.takeUpdate(at: now)
      }
    }
    _ = box.takeUpdate(at: now)
    return (box, now)
  }

  static func sameReports(_ ops: [Op]) throws -> String? {
    let (box, now) = try drive(ops)
    let restored = try AttentionInbox(
      checkpoint: try box.checkpoint(),
      limits: limits
    )
    guard restored.revision == box.revision else {
      return "revision \(restored.revision), was \(box.revision)"
    }
    guard restored.textBytes == box.textBytes else {
      return "text bytes \(restored.textBytes), was \(box.textBytes)"
    }
    guard restored.itemCount == box.itemCount,
      try all(restored, at: now) == all(box, at: now)
    else { return "\(restored.itemCount) items, was \(box.itemCount)" }
    for section in [InboxQuery.Section.needsYou, .results] {
      let query = InboxQuery(section: section)
      guard try restored.page(query, at: now) == box.page(query, at: now) else {
        return "\(section) page differs"
      }
    }
    guard restored.counts(at: now) == box.counts(at: now),
      restored.nextSnoozeExpiry == box.nextSnoozeExpiry
    else { return "counts or snooze expiry differ" }
    for pane in 0 ..< 3 {
      guard
        restored.currentStatus(of: id(pane)) == box.currentStatus(of: id(pane))
      else { return "current status of pane \(pane) differs" }
    }
    guard !restored.hasPendingUpdate else {
      return "the restored inbox has an update to send"
    }
    return nil
  }

  static func canonicalBytes(_ ops: [Op]) throws -> String? {
    let (box, _) = try drive(ops)
    let checkpoint = try box.checkpoint()
    guard try box.checkpoint() == checkpoint else {
      return "two checkpoints of one inbox differ"
    }
    let restored = try AttentionInbox(checkpoint: checkpoint, limits: limits)
    let again = try restored.checkpoint()
    guard again == checkpoint else {
      return "restored inbox checkpoints to different bytes "
        + "(\(again.count) and \(checkpoint.count) bytes, "
        + "\(box.itemCount) items); fields differing: "
        + differingFields(checkpoint, again).joined(separator: ", ")
    }
    return nil
  }

  /// Top-level snapshot fields whose JSON differs.
  static func differingFields(_ a: Data, _ b: Data) -> [String] {
    guard let x = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
      let y = try? JSONSerialization.jsonObject(with: b) as? [String: Any]
    else { return ["not JSON objects"] }
    func json(_ value: Any?) -> Data? {
      value.flatMap {
        try? JSONSerialization.data(
          withJSONObject: $0,
          options: [.sortedKeys, .fragmentsAllowed]
        )
      }
    }
    return Set(x.keys).union(y.keys).sorted()
      .filter { json(x[$0]) != json(y[$0]) }
  }

  @Test
  func restoredInboxReportsTheSameItems() {
    let failure = Property.check(
      seeds: Property.seeds(150),
      generate: Self.generate,
      shrink: { Property.shrinkList($0) },
      property: Self.sameReports
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  /// `Snapshot`'s tables keyed by `PaneID`, `OccurrenceID` and
  /// `AttentionSource` are written in key order; hash order (which
  /// `.sortedKeys` does not touch) differs per instance.
  @Test
  func checkpointBytesSurviveARestore() {
    let failure = Property.check(
      seeds: Property.seeds(150),
      generate: Self.generate,
      shrink: { Property.shrinkList($0) },
      property: Self.canonicalBytes
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  /// Seed 1 shrinks to one report on each of two panes.
  @Test(arguments: [UInt64(1)])
  func checkpointBytesRegression(seed: UInt64) {
    let failure = Property.check(
      seeds: [seed],
      generate: Self.generate,
      shrink: { Property.shrinkList($0) },
      property: Self.canonicalBytes
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  /// Static analogue of the two-pane counterexample, with all three panes
  /// so a restore reorders `panes` most of the time.
  @Test
  func threePanesCheckpointCanonically() throws {
    let ops: [Op] = (0 ..< 3)
      .map { .report(pane: $0, path: 1, state: .working, text: 1) }
    // Hash order varies per instance; repeat so a regression shows.
    for _ in 0 ..< 20 {
      let violation = try Self.canonicalBytes(ops)
      #expect(violation == nil, "\(violation ?? "")")
    }
  }
}
