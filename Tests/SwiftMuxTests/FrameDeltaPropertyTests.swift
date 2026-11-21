import Foundation
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyCore
import Testing
import TestSupport

/// Frame deltas and `SMXB/1` under random terminal output: every delta
/// rebuilds the next frame from the previous one, and every frame and
/// delta survives the binary codec unchanged.
struct FrameDeltaPropertyTests {
  static let fragments: [String] = [
    "plain ", "wide 漢字 ", "e\u{301}\u{302} ", "👨‍👩‍👧 ", "🇳🇿",
    "0123456789abcdefghijklmnop", "\r\n", "\r\n", "\r\n", "\n", "\r", "\t",
    "line of output\r\n", "\u{1B}[1;31mred\u{1B}[0m ",
    "\u{1B}[38;2;10;20;30;48;5;200mrgb\u{1B}[m ",
    "\u{1B}[4:3;58:2::10:20:30mcurly\u{1B}[0m ", "\u{1B}[7;9minverse\u{1B}[m",
    "\u{1B}[H", "\u{1B}[3;5H", "\u{1B}[A", "\u{1B}[2B", "\u{1B}[5C", "\u{1B}[D",
    "\u{1B}[2J", "\u{1B}[J", "\u{1B}[1J", "\u{1B}[K", "\u{1B}[1K", "\u{1B}[3J",
    "\u{1B}[2;4r", "\u{1B}[r", "\u{1B}[2L", "\u{1B}[M", "\u{1B}[3@",
    "\u{1B}[2P", "\u{1B}[4X", "\u{1B}[S", "\u{1B}[2T", "\u{1B}D", "\u{1B}M",
    "\u{1B}E", "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[?25l", "\u{1B}[?25h",
    "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?47h", "\u{1B}[?47l",
    "\u{1B}[?2004h", "\u{1B}[?2004l", "\u{1B}[?1h", "\u{1B}[?1000h",
    "\u{1B}[?1006h", "\u{1B}[4 q", "\u{1B}]2;title \u{7}",
    "\u{1B}]2;漢字\u{1B}\\", "\u{1B}]4;1;rgb:12/34/56\u{7}",
    "\u{1B}]10;rgb:ff/ee/dd\u{7}", "\u{1B}]11;rgb:01/02/03\u{7}",
    "\u{1B}]104\u{7}", "\u{1B}7", "\u{1B}8", "\u{1B}(0lqk\u{1B}(B", "\u{1B}#8",
    "\u{1B}c",
  ]

  enum Step: CustomStringConvertible {
    /// Feeds a fragment; with `cut`, exports a frame part way through it.
    case feed(Int, cut: Int?, export: Bool)
    case resize(columns: Int, rows: Int)
    case scroll(Int)

    var description: String {
      switch self {
      case let .feed(i, cut, export):
        fragments[i].debugDescription + (cut.map { "@\($0)" } ?? "")
          + (export ? "!" : "")
      case let .resize(c, r): "resize(\(c)x\(r))"
      case let .scroll(n): "scroll(\(n))"
      }
    }
  }

  static func generate(_ random: inout PropertyRandom) -> [Step] {
    random.array(count: random.int(in: 1 ... 60)) { random in
      switch random.int(100) {
      case ..<88:
        let i = random.int(fragments.count)
        let cut =
          random.oneIn(6) ? random.int(fragments[i].utf8.count + 1) : nil
        return .feed(i, cut: cut, export: !random.oneIn(3))
      case ..<93:
        return .resize(
          columns: random.int(in: 8 ... 30),
          rows: random.int(in: 2 ... 10)
        )
      default: return .scroll(random.int(in: -4 ... 4))
      }
    }
  }

  /// Where two frames that should be equal differ.
  static func mismatch(_ a: PaneFrame, _ b: PaneFrame) -> String? {
    let x = FrameDeltaTests.semantic(a)
    let y = FrameDeltaTests.semantic(b)
    if x != y {
      let row = zip(x, y).enumerated().first { $0.element.0 != $0.element.1 }?
        .offset
      return "cells differ (rows \(x.count)/\(y.count), first row \(row ?? -1))"
    }
    if a.identity != b.identity { return "identity" }
    if a.cursor != b.cursor { return "cursor \(a.cursor) vs \(b.cursor)" }
    if a.history != b.history { return "history \(a.history) vs \(b.history)" }
    if a.palette != b.palette { return "palette" }
    if a.modes != b.modes { return "modes \(a.modes) vs \(b.modes)" }
    if a.title != b.title { return "title \(a.title) vs \(b.title)" }
    if a.rowVersions != b.rowVersions { return "row versions" }
    if a.grid.alternateScreen != b.grid.alternateScreen {
      return "alternate screen"
    }
    return nil
  }

  /// The codec decodes `SMXB.encode` to the same record, and re-encodes
  /// that record to the same bytes.
  static func roundTrip(_ frame: PaneFrame) throws -> String? {
    let data = SMXB.encode(frame)
    let record = try SMXB.decode(data)
    guard record == SMXB.Record(envelope: .mux, payload: .frame(frame)) else {
      return "frame changed through SMXB"
    }
    guard case let .frame(decoded) = record.payload,
      SMXB.encode(decoded) == data
    else { return "frame re-encodes differently" }
    return nil
  }

  static func roundTrip(_ delta: FrameDelta) throws -> String? {
    let data = SMXB.encode(delta)
    let record = try SMXB.decode(data)
    guard record == SMXB.Record(envelope: .mux, payload: .delta(delta)) else {
      return "delta changed through SMXB"
    }
    guard case let .delta(decoded) = record.payload,
      SMXB.encode(decoded) == data
    else { return "delta re-encodes differently" }
    return nil
  }

  struct Counts {
    var frames = 0
    var deltas = 0
  }

  static func run(_ steps: [Step], counts: inout Counts) throws -> String? {
    var e = FrameDeltaTests.Exporter()
    var previous = try e.frame()
    if let failure = try roundTrip(previous) { return "initial: \(failure)" }
    for (index, step) in steps.enumerated() {
      let label = "step \(index) (\(step))"
      var export = true
      switch step {
      case let .feed(i, cut, last):
        let bytes = Array(fragments[i].utf8)
        let split = min(cut ?? bytes.count, bytes.count)
        if split < bytes.count {
          e.session.feed(Array(bytes[..<split]))
          let next = try e.frame()
          if let failure = try check(previous, next, &counts) {
            return "\(label) cut: \(failure)"
          }
          previous = next
          e.session.feed(Array(bytes[split...]))
        } else {
          e.session.feed(bytes)
        }
        export = last
      case let .resize(columns, rows):
        e.session.resize(columns: columns, rows: rows)
        e.geometry += 1
      case let .scroll(lines): e.session.scrollViewport(by: lines)
      }
      guard export else { continue }
      let next = try e.frame()
      if let failure = try check(previous, next, &counts) {
        return "\(label): \(failure)"
      }
      previous = next
    }
    return nil
  }

  static func check(
    _ previous: PaneFrame,
    _ next: PaneFrame,
    _ counts: inout Counts
  ) throws -> String? {
    counts.frames += 1
    if let failure = try roundTrip(next) { return failure }
    guard let base = FrameBaseline(previous) else {
      return "a frame with row versions is no baseline"
    }
    guard let delta = FrameDeltaBuilder.delta(from: next, base: base) else {
      return nil
    }
    counts.deltas += 1
    if let failure = try roundTrip(delta) { return failure }
    let applied = try FrameDeltaApplier.apply(delta, to: previous)
    return mismatch(applied, next).map { "applied delta: \($0)" }
  }

  @Test
  func deltasRebuildFramesAndSurviveTheCodec() {
    var counts = Counts()
    let failure = Property.check(
      seeds: Property.seeds(40),
      generate: Self.generate,
      shrink: { Property.shrinkList($0) },
      property: { try Self.run($0, counts: &counts) }
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
    // Most frames go out as deltas, so the property is not vacuous.
    #expect(counts.deltas * 2 > counts.frames, "\(counts)")
  }
}
