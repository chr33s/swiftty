import Foundation
import SwiftMuxProtocol
import Testing
import TestSupport

/// `LayoutNode` edits and `LayoutGeometry` under random split, remove and
/// resize sequences.
struct LayoutPropertyTests {
  /// Targets are taken modulo what the tree holds when the edit runs, so
  /// every shrunk sequence is still meaningful.
  enum Op: CustomStringConvertible {
    case split(target: Int, axis: SplitAxis, ratio: Double)
    case remove(target: Int)
    /// `target` picks a split; an odd `leaf` instead names a pane's path.
    case ratio(target: Int, ratio: Double, leaf: Bool)
    case geometry(width: Int, height: Int, divider: Int)

    var description: String {
      switch self {
      case let .split(t, axis, r):
        "split(\(t) \(axis == .leftRight ? "|" : "-") \(r))"
      case let .remove(t): "remove(\(t))"
      case let .ratio(t, r, leaf): "ratio(\(t)\(leaf ? " leaf" : "") \(r))"
      case let .geometry(w, h, d): "frames(\(w)x\(h) /\(d))"
      }
    }
  }

  static func pane(_ n: Int) -> PaneID {
    PaneID(String(format: "00000000-0000-0000-0000-%012X", n))!
  }

  static func ratio(_ random: inout PropertyRandom) -> Double {
    switch random.int(10) {
    case 0: 1e-9
    case 1: 1 - 1e-9
    case 2: 0.5
    default: random.double(in: 0.01 ..< 0.99)
    }
  }

  static func generate(_ random: inout PropertyRandom) -> [Op] {
    random.array(count: random.int(in: 1 ... 30)) { random in
      switch random.int(10) {
      case ..<4:
        .split(
          target: random.int(64),
          axis: random.bool() ? .leftRight : .topBottom,
          ratio: ratio(&random)
        )
      case ..<6: .remove(target: random.int(64))
      case ..<8:
        .ratio(
          target: random.int(64),
          ratio: ratio(&random),
          leaf: random.oneIn(5)
        )
      default:
        .geometry(
          width: random.int(in: 0 ... 40),
          height: random.int(in: 0 ... 24),
          divider: random.int(in: 0 ... 2)
        )
      }
    }
  }

  /// Paths to every split, root first.
  static func splitPaths(_ node: LayoutNode, _ path: [Bool] = []) -> [[Bool]] {
    guard case let .split(_, _, a, b) = node else { return [] }
    return [path] + splitPaths(a, path + [false]) + splitPaths(b, path + [true])
  }

  static func leafPaths(_ node: LayoutNode, _ path: [Bool] = []) -> [[Bool]] {
    guard case let .split(_, _, a, b) = node else { return [path] }
    return leafPaths(a, path + [false]) + leafPaths(b, path + [true])
  }

  /// The splits along `axis` from the root down to `pane`, by brute force.
  static func innermost(
    _ node: LayoutNode,
    _ pane: PaneID,
    axis: SplitAxis
  ) -> (path: [Bool], paneIsFirst: Bool, ratio: Double)? {
    var found: (path: [Bool], paneIsFirst: Bool, ratio: Double)?
    var node = node
    var path: [Bool] = []
    while case let .split(ax, r, a, b) = node {
      let first = a.contains(pane)
      guard first || b.contains(pane) else { return nil }
      if ax == axis { found = (path, first, r) }
      path.append(!first)
      node = first ? a : b
    }
    return found
  }

  /// Panes and dividers cover every cell of `rect` exactly once.
  static func checkGeometry(
    _ tree: LayoutNode,
    width: Int,
    height: Int,
    divider: Int
  ) -> String? {
    let rect = LayoutRect(x: 3, y: 2, width: width, height: height)
    let frames = LayoutGeometry.frames(tree, in: rect, divider: divider)
    let dividers = LayoutGeometry.dividers(tree, in: rect, divider: divider)
    guard Set(frames.keys) == Set(tree.panes) else {
      return "frames for \(frames.count) of \(tree.panes.count) panes"
    }
    guard dividers.count == splitPaths(tree).count else {
      return "\(dividers.count) dividers for \(splitPaths(tree).count) splits"
    }
    var cover = [Int](repeating: 0, count: width * height)
    let rects = Array(frames.values) + dividers.map(\.rect)
    for r in rects {
      guard r.width >= 0, r.height >= 0, r.x >= rect.x, r.y >= rect.y,
        r.maxX <= rect.maxX, r.maxY <= rect.maxY
      else { return "\(r) outside \(rect)" }
      for y in r.y ..< r.maxY {
        for x in r.x ..< r.maxX {
          cover[(y - rect.y) * width + (x - rect.x)] += 1
        }
      }
    }
    if let cell = cover.firstIndex(where: { $0 != 1 }) {
      return "cell (\(cell % width), \(cell / width)) of \(rect) covered "
        + "\(cover[cell]) times (divider \(divider))"
    }
    return nil
  }

  static func run(_ ops: [Op]) -> String? {
    var tree = LayoutNode.pane(pane(0))
    var expected: Set<PaneID> = [pane(0)]
    var next = 1
    for (index, op) in ops.enumerated() {
      let step = "op \(index) (\(op))"
      let before = tree.panes
      switch op {
      case let .split(target, axis, r):
        let old = before[target % before.count]
        let new = pane(next)
        next += 1
        tree = tree.splitting(old, axis: axis, newPane: new, ratio: r)
        expected.insert(new)
        let order = tree.panes
        guard let at = order.firstIndex(of: old), at + 1 < order.count,
          order[at + 1] == new
        else { return "\(step): the new pane does not follow its source" }
        var without = order
        without.remove(at: at + 1)
        guard without == before else {
          return "\(step): splitting reordered other panes"
        }
      case let .remove(target):
        let gone = before[target % before.count]
        guard let removed = tree.removing(gone) else {
          guard before.count == 1 else {
            return "\(step): removing one of \(before.count) gave nil"
          }
          continue
        }
        guard before.count > 1 else {
          return "\(step): removing the only pane kept a tree"
        }
        tree = removed
        expected.remove(gone)
        guard tree.panes == before.filter({ $0 != gone }) else {
          return "\(step): removing reordered the remaining panes"
        }
        guard tree.removing(gone) == tree else {
          return "\(step): removing an absent pane changed the tree"
        }
      case let .ratio(target, r, leaf):
        if leaf {
          let paths = leafPaths(tree)
          guard tree.settingRatio(r, at: paths[target % paths.count]) == nil
          else { return "\(step): a pane path took a ratio" }
          continue
        }
        let paths = splitPaths(tree)
        guard !paths.isEmpty else {
          guard tree.settingRatio(r, at: []) == nil else {
            return "\(step): a lone pane took a ratio"
          }
          continue
        }
        let path = paths[target % paths.count]
        guard let updated = tree.settingRatio(r, at: path) else {
          return "\(step): no split at \(path)"
        }
        guard case let .split(_, got, _, _)? = updated.node(at: path), got == r
        else { return "\(step): ratio not set at \(path)" }
        guard updated.panes == before else {
          return "\(step): setting a ratio moved panes"
        }
        tree = updated
      case let .geometry(width, height, divider):
        if let failure = checkGeometry(
          tree,
          width: width,
          height: height,
          divider: divider
        ) {
          return "\(step): \(failure)"
        }
      }
      guard tree.isValid() else { return "\(step): tree invalid" }
      guard Set(tree.panes) == expected, tree.panes.count == expected.count
      else { return "\(step): panes \(tree.panes.count), \(expected.count)" }
      for id in tree.panes {
        for axis in [SplitAxis.leftRight, .topBottom] {
          let got = tree.enclosingSplit(of: id, axis: axis)
          let want = innermost(tree, id, axis: axis)
          guard got?.path == want?.path, got?.paneIsFirst == want?.paneIsFirst,
            got?.ratio == want?.ratio
          else { return "\(step): enclosing \(axis) split of a pane" }
        }
      }
    }
    return nil
  }

  @Test
  func randomEditsKeepTheTreeValidAndTiled() {
    let failure = Property.check(
      seeds: Property.seeds(300),
      generate: Self.generate,
      shrink: { Property.shrinkList($0) },
      property: Self.run
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  @Test
  func partitionSplitsTheUsableLengthByRatio() {
    struct Input: CustomStringConvertible {
      var length: Int
      var ratio: Double
      var divider: Int
      var description: String { "\(length) at \(ratio) /\(divider)" }
    }
    let failure = Property.check(
      seeds: Property.seeds(1_000),
      generate: { random in
        Input(
          length: random.int(in: 0 ... 4_000),
          ratio: Self.ratio(&random),
          divider: random.int(in: 0 ... 3)
        )
      },
      property: { input in
        let (first, second) = LayoutGeometry.partition(
          input.length,
          ratio: input.ratio,
          divider: input.divider
        )
        let usable = max(0, input.length - input.divider)
        guard first >= 0, second >= 0, first + second == usable else {
          return "\(first) + \(second) for \(usable) usable"
        }
        guard abs(Double(first) - Double(usable) * input.ratio) <= 0.5 else {
          return "first \(first) is not the ratio's share of \(usable)"
        }
        return nil
      }
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }
}
