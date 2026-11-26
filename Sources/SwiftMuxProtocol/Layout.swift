/// `leftRight` places children side by side; `topBottom` stacks them.
public enum SplitAxis: String, Codable, Sendable, Hashable {
  case leftRight, topBottom
}

public enum Direction: String, Codable, Sendable, Hashable {
  case left, right, up, down
}

/// A tab's logical split tree. Persisted by the service; frontends map it
/// onto their own pixels or cells.
public indirect enum LayoutNode: Codable, Sendable, Hashable {
  case pane(PaneID)
  /// `ratio` is the share given to `first`, in (0, 1).
  case split(
    axis: SplitAxis,
    ratio: Double,
    first: LayoutNode,
    second: LayoutNode
  )

  /// Panes in display order (depth first, first child before second).
  public var panes: [PaneID] {
    switch self {
    case let .pane(id): [id]
    case let .split(_, _, a, b): a.panes + b.panes
    }
  }

  public func contains(_ pane: PaneID) -> Bool {
    switch self {
    case let .pane(id): id == pane
    case let .split(_, _, a, b): a.contains(pane) || b.contains(pane)
    }
  }

  public var depth: Int {
    switch self {
    case .pane: 0
    case let .split(_, _, a, b): 1 + max(a.depth, b.depth)
    }
  }

  /// Replaces `pane` with a split holding it first and `newPane` second.
  public func splitting(
    _ pane: PaneID,
    axis: SplitAxis,
    newPane: PaneID,
    ratio: Double = 0.5
  ) -> LayoutNode {
    switch self {
    case let .pane(id) where id == pane:
      .split(axis: axis, ratio: ratio, first: self, second: .pane(newPane))
    case .pane: self
    case let .split(ax, r, a, b):
      .split(
        axis: ax,
        ratio: r,
        first: a.splitting(pane, axis: axis, newPane: newPane, ratio: ratio),
        second: b.splitting(pane, axis: axis, newPane: newPane, ratio: ratio)
      )
    }
  }

  /// The tree without `pane`; its sibling takes the parent's place.
  /// Nil when `pane` was the only leaf.
  public func removing(_ pane: PaneID) -> LayoutNode? {
    switch self {
    case let .pane(id): return id == pane ? nil : self
    case let .split(ax, r, a, b):
      let na = a.removing(pane)
      let nb = b.removing(pane)
      switch (na, nb) {
      case let (x?, y?): return .split(axis: ax, ratio: r, first: x, second: y)
      case let (x?, nil): return x
      case let (nil, y?): return y
      case (nil, nil): return nil
      }
    }
  }

  /// The split at `path` (false = first, true = second), if any.
  public func node(at path: [Bool]) -> LayoutNode? {
    guard let step = path.first else { return self }
    guard case let .split(_, _, a, b) = self else { return nil }
    return (step ? b : a).node(at: Array(path.dropFirst()))
  }

  /// Sets the ratio of the split at `path`; nil if no split is there.
  public func settingRatio(_ ratio: Double, at path: [Bool]) -> LayoutNode? {
    guard case let .split(ax, r, a, b) = self else { return nil }
    guard let step = path.first else {
      return .split(axis: ax, ratio: ratio, first: a, second: b)
    }
    let rest = Array(path.dropFirst())
    if step {
      guard let nb = b.settingRatio(ratio, at: rest) else { return nil }
      return .split(axis: ax, ratio: r, first: a, second: nb)
    }
    guard let na = a.settingRatio(ratio, at: rest) else { return nil }
    return .split(axis: ax, ratio: r, first: na, second: b)
  }

  /// Path to the innermost split along `axis` enclosing `pane`, plus
  /// whether the pane lies in its first child.
  public func enclosingSplit(
    of pane: PaneID,
    axis: SplitAxis
  ) -> (path: [Bool], paneIsFirst: Bool, ratio: Double)? {
    guard case let .split(ax, r, a, b) = self else { return nil }
    if a.contains(pane) {
      if let inner = a.enclosingSplit(of: pane, axis: axis) {
        return ([false] + inner.path, inner.paneIsFirst, inner.ratio)
      }
      return ax == axis ? ([], true, r) : nil
    }
    if b.contains(pane) {
      if let inner = b.enclosingSplit(of: pane, axis: axis) {
        return ([true] + inner.path, inner.paneIsFirst, inner.ratio)
      }
      return ax == axis ? ([], false, r) : nil
    }
    return nil
  }

  /// Whether ratios are finite and in (0, 1) and no pane repeats.
  public func isValid(maxDepth: Int = 32) -> Bool {
    guard depth <= maxDepth else { return false }
    let ids = panes
    guard Set(ids).count == ids.count else { return false }
    return ratiosValid
  }

  private var ratiosValid: Bool {
    switch self {
    case .pane: true
    case let .split(_, r, a, b):
      r.isFinite && r > 0 && r < 1 && a.ratiosValid && b.ratiosValid
    }
  }
}

/// An integer rectangle in cells or points.
public struct LayoutRect: Codable, Sendable, Hashable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Int { x + width }
  public var maxY: Int { y + height }

  public func contains(x px: Int, y py: Int) -> Bool {
    px >= x && px < maxX && py >= y && py < maxY
  }
}

/// A divider between two children of the split at `path`.
public struct LayoutDivider: Sendable, Hashable {
  public var rect: LayoutRect
  public var axis: SplitAxis
  public var path: [Bool]
  /// The extent shared by both children along the split axis.
  public var parent: LayoutRect
  /// Set when the split is inside a floating layer. Nil is the tiled tree.
  public var layer: LayerID? = nil
}

/// Fractions of a tab's content box, origin at the top left. A floating
/// layer stores this instead of pixels, so a resize or another frontend
/// places it again.
public struct LayerRect: Codable, Sendable, Hashable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }

  /// Centered, large enough to read, inside the tab.
  public static let standard = LayerRect(x: 0.2, y: 0.15, w: 0.6, h: 0.55)

  /// Finite, positive, and inside the unit square. A millionth of slack
  /// covers a fraction that landed on 1.
  public var isValid: Bool {
    let slack = 1e-6
    guard [x, y, w, h].allSatisfy(\.isFinite), w > slack, h > slack else {
      return false
    }
    return x >= -slack && y >= -slack && x + w <= 1 + slack
      && y + h <= 1 + slack
  }

  /// Slides into the tab, keeping the size when it fits.
  public func fitted() -> LayerRect {
    var rect = self
    rect.w = min(1, max(rect.w, 0))
    rect.h = min(1, max(rect.h, 0))
    rect.x = min(max(0, rect.x), 1 - rect.w)
    rect.y = min(max(0, rect.y), 1 - rect.h)
    return rect
  }

  /// A pointer drag of `dx`, `dy` (fractions of the tab). No edges moves
  /// the rectangle, sliding it inside the tab. Otherwise only the named
  /// edges follow, each stopping at the tab and at the opposite edge.
  public func dragged(
    dx: Double,
    dy: Double,
    edges: LayerEdges = []
  ) -> LayerRect {
    guard !edges.isEmpty else {
      return LayerRect(x: x + dx, y: y + dy, w: w, h: h).fitted()
    }
    var (left, right, top, bottom) = (x, x + w, y, y + h)
    if edges.contains(.left) { left = min(max(0, left + dx), right) }
    if edges.contains(.right) { right = max(min(1, right + dx), left) }
    if edges.contains(.top) { top = min(max(0, top + dy), bottom) }
    if edges.contains(.bottom) { bottom = max(min(1, bottom + dy), top) }
    return LayerRect(x: left, y: top, w: right - left, h: bottom - top)
  }
}

/// Which sides of a floating layer a drag resizes.
public struct LayerEdges: OptionSet, Sendable, Hashable {
  public var rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let left = LayerEdges(rawValue: 1 << 0)
  public static let right = LayerEdges(rawValue: 1 << 1)
  public static let top = LayerEdges(rawValue: 1 << 2)
  public static let bottom = LayerEdges(rawValue: 1 << 3)
}

/// One floating layer: its own split tree, placed over the tiled layout.
/// Layers are ordered back to front. A minimized layer keeps running and
/// keeps its bounds and stack position, and is not drawn.
public struct FloatingLayer: Codable, Sendable, Hashable {
  public var id: LayerID
  public var layout: LayoutNode
  public var bounds: LayerRect
  public var minimized: Bool
  public var focusedPane: PaneID

  public init(
    id: LayerID = LayerID(),
    layout: LayoutNode,
    bounds: LayerRect,
    minimized: Bool = false,
    focusedPane: PaneID
  ) {
    self.id = id
    self.layout = layout
    self.bounds = bounds
    self.minimized = minimized
    self.focusedPane = focusedPane
  }
}

/// Maps a split tree onto an integer area. Both frontends use it with
/// their own units and divider thickness; the protocol has no mandatory
/// border. Areas too small for every pane yield zero-sized frames, which
/// frontends present clipped while retaining the previous pane sizes.
public enum LayoutGeometry {
  public static func frames(
    _ node: LayoutNode,
    in rect: LayoutRect,
    divider: Int
  ) -> [PaneID: LayoutRect] {
    var out: [PaneID: LayoutRect] = [:]
    var dividers: [LayoutDivider] = []
    walk(node, rect, divider, [], &out, &dividers)
    return out
  }

  public static func dividers(
    _ node: LayoutNode,
    in rect: LayoutRect,
    divider: Int
  ) -> [LayoutDivider] {
    var out: [PaneID: LayoutRect] = [:]
    var dividers: [LayoutDivider] = []
    walk(node, rect, divider, [], &out, &dividers)
    return dividers
  }

  /// `bounds` placed in `rect`, snapped to whole units and clipped to it.
  public static func layerFrame(
    _ bounds: LayerRect,
    in rect: LayoutRect
  ) -> LayoutRect {
    let x = rect.x + Int((Double(rect.width) * bounds.x).rounded())
    let y = rect.y + Int((Double(rect.height) * bounds.y).rounded())
    let w = max(
      0,
      min(Int((Double(rect.width) * bounds.w).rounded()), rect.maxX - x)
    )
    let h = max(
      0,
      min(Int((Double(rect.height) * bounds.h).rounded()), rect.maxY - y)
    )
    return LayoutRect(x: x, y: y, width: w, height: h)
  }

  /// Shrinks `rect` by `n` on every side. A rect too small to shrink is
  /// returned unchanged, so the frame and the content share it.
  public static func inset(_ rect: LayoutRect, by n: Int) -> LayoutRect {
    guard n > 0, rect.width > n * 2, rect.height > n * 2 else { return rect }
    return LayoutRect(
      x: rect.x + n,
      y: rect.y + n,
      width: rect.width - n * 2,
      height: rect.height - n * 2
    )
  }

  /// Splits `length` minus the divider into first/second extents.
  public static func partition(
    _ length: Int,
    ratio: Double,
    divider: Int
  ) -> (first: Int, second: Int) {
    let usable = max(0, length - divider)
    let first = min(usable, max(0, Int((Double(usable) * ratio).rounded())))
    return (first, usable - first)
  }

  private static func walk(
    _ node: LayoutNode,
    _ rect: LayoutRect,
    _ divider: Int,
    _ path: [Bool],
    _ out: inout [PaneID: LayoutRect],
    _ dividers: inout [LayoutDivider]
  ) {
    switch node {
    case let .pane(id): out[id] = rect
    case let .split(axis, ratio, a, b):
      switch axis {
      case .leftRight:
        let (w1, w2) = partition(rect.width, ratio: ratio, divider: divider)
        let r1 = LayoutRect(
          x: rect.x,
          y: rect.y,
          width: w1,
          height: rect.height
        )
        let r2 = LayoutRect(
          x: rect.x + w1 + min(divider, rect.width),
          y: rect.y,
          width: w2,
          height: rect.height
        )
        dividers.append(
          LayoutDivider(
            rect: LayoutRect(
              x: rect.x + w1,
              y: rect.y,
              width: min(divider, rect.width),
              height: rect.height
            ),
            axis: axis,
            path: path,
            parent: rect
          )
        )
        walk(a, r1, divider, path + [false], &out, &dividers)
        walk(b, r2, divider, path + [true], &out, &dividers)
      case .topBottom:
        let (h1, h2) = partition(rect.height, ratio: ratio, divider: divider)
        let r1 = LayoutRect(x: rect.x, y: rect.y, width: rect.width, height: h1)
        let r2 = LayoutRect(
          x: rect.x,
          y: rect.y + h1 + min(divider, rect.height),
          width: rect.width,
          height: h2
        )
        dividers.append(
          LayoutDivider(
            rect: LayoutRect(
              x: rect.x,
              y: rect.y + h1,
              width: rect.width,
              height: min(divider, rect.height)
            ),
            axis: axis,
            path: path,
            parent: rect
          )
        )
        walk(a, r1, divider, path + [false], &out, &dividers)
        walk(b, r2, divider, path + [true], &out, &dividers)
      }
    }
  }

  /// The pane adjacent to `pane` in `direction`, choosing the neighbour
  /// overlapping the pane's centre line when several touch it.
  public static func neighbor(
    of pane: PaneID,
    direction: Direction,
    frames: [PaneID: LayoutRect],
    order: [PaneID]
  ) -> PaneID? {
    guard let r = frames[pane] else { return nil }
    var best: (PaneID, Int)?
    for id in order where id != pane {
      guard let o = frames[id] else { continue }
      let gap: Int
      let overlaps: Bool
      let centre: Bool
      switch direction {
      case .left:
        gap = r.x - o.maxX
        overlaps = o.y < r.maxY && o.maxY > r.y
        centre = (o.y ... o.maxY).contains(r.y + r.height / 2)
      case .right:
        gap = o.x - r.maxX
        overlaps = o.y < r.maxY && o.maxY > r.y
        centre = (o.y ... o.maxY).contains(r.y + r.height / 2)
      case .up:
        gap = r.y - o.maxY
        overlaps = o.x < r.maxX && o.maxX > r.x
        centre = (o.x ... o.maxX).contains(r.x + r.width / 2)
      case .down:
        gap = o.y - r.maxY
        overlaps = o.x < r.maxX && o.maxX > r.x
        centre = (o.x ... o.maxX).contains(r.x + r.width / 2)
      }
      guard gap >= 0, overlaps else { continue }
      let score = gap * 2 + (centre ? 0 : 1)
      if best == nil || score < best!.1 { best = (id, score) }
    }
    return best?.0
  }

  /// The pane focus moves to. Inside a floating layer, arrows stay in
  /// that layer and leave it only when it has no neighbour, stepping to
  /// the layer below and then the tiled tree. From the tiled tree, arrows
  /// stay there.
  public static func focusNeighbor(
    of pane: PaneID,
    direction: Direction,
    tab: TabSnapshot,
    frames: [PaneID: LayoutRect]
  ) -> PaneID? {
    guard tab.zoomedPane == nil else { return nil }
    if let layer = tab.layer(containing: pane), !layer.minimized {
      let local = frames.filter { layer.layout.contains($0.key) }
      if let next = neighbor(
        of: pane,
        direction: direction,
        frames: local,
        order: layer.layout.panes
      ) {
        return next
      }
      let visible = tab.layers.filter { !$0.minimized }
      if let index = visible.firstIndex(where: { $0.id == layer.id }), index > 0
      {
        return visible[index - 1].focusedPane
      }
      return tab.layout?.panes.first
    }
    let tiled = frames.filter { tab.layout?.contains($0.key) == true }
    return neighbor(
      of: pane,
      direction: direction,
      frames: tiled,
      order: tab.layout?.panes ?? []
    )
  }
}

/// The outer frame of one visible floating layer.
public struct LayerFrame: Sendable, Hashable {
  public var layer: FloatingLayer
  public var outer: LayoutRect
  public var id: LayerID { layer.id }

  public init(layer: FloatingLayer, outer: LayoutRect) {
    self.layer = layer
    self.outer = outer
  }
}

/// Where a tab's visible panes sit: the tiled panes (or the zoomed one),
/// then each visible layer, back to front.
public struct TabPlacement: Sendable, Hashable {
  public var panes: [PaneID: LayoutRect]
  /// The zoomed pane, or the tiled tree's panes.
  public var tiled: [PaneID]
  public var dividers: [LayoutDivider]
  /// Each visible floating layer, back to front.
  public var layers: [LayerFrame]

  /// Back to front, so a later pane paints over an earlier one.
  public var order: [PaneID] { tiled + layers.flatMap(\.layer.layout.panes) }

  public init(
    panes: [PaneID: LayoutRect],
    tiled: [PaneID],
    dividers: [LayoutDivider],
    layers: [LayerFrame]
  ) {
    self.panes = panes
    self.tiled = tiled
    self.dividers = dividers
    self.layers = layers
  }
}

/// A tab's tiled tree and floating layers. The service model, the wire
/// snapshot and the migration checkpoint share these helpers.
public protocol LayeredTab {
  var layout: LayoutNode? { get }
  var layers: [FloatingLayer] { get }
  var zoomedPane: PaneID? { get }
}

extension LayeredTab {
  public var tiledPanes: [PaneID] { layout?.panes ?? [] }

  /// Tiled panes, then each floating layer's panes, back to front.
  public var panes: [PaneID] { tiledPanes + layers.flatMap(\.layout.panes) }

  public func contains(_ pane: PaneID) -> Bool {
    (layout?.contains(pane) ?? false)
      || layers.contains { $0.layout.contains(pane) }
  }

  public func layer(containing pane: PaneID) -> FloatingLayer? {
    layers.first { $0.layout.contains(pane) }
  }

  public func layer(id: LayerID) -> FloatingLayer? {
    layers.first { $0.id == id }
  }

  /// The tree a split addresses: `layer`'s, or the tiled tree for nil.
  public func tree(of layer: LayerID?) -> LayoutNode? {
    guard let layer else { return layout }
    return self.layer(id: layer)?.layout
  }

  /// The tree holding `pane`: its layer's, or the tiled tree.
  public func tree(containing pane: PaneID) -> LayoutNode? {
    layer(containing: pane)?.layout ?? layout
  }

  /// What a frontend draws and subscribes to. Zoom fills the tab with
  /// one pane. A minimized layer is absent.
  public var visiblePanes: [PaneID] {
    if let zoomedPane { return [zoomedPane] }
    let floating = layers.filter { !$0.minimized }.flatMap(\.layout.panes)
    return tiledPanes + floating
  }

  /// Whether minimizing `layer` leaves a visible pane.
  public func canMinimize(_ layer: FloatingLayer) -> Bool {
    let hiding = Set(layer.layout.panes)
    return visiblePanes.contains { !hiding.contains($0) }
  }

  /// Maps the tab onto `rect`. `floatInset` is the layer frame around
  /// each floating tree; `divider` separates panes inside a tree.
  public func placement(
    in rect: LayoutRect,
    divider: Int,
    floatInset: Int
  ) -> TabPlacement {
    if let zoomedPane {
      return TabPlacement(
        panes: [zoomedPane: rect],
        tiled: [zoomedPane],
        dividers: [],
        layers: []
      )
    }
    var placed = TabPlacement(panes: [:], tiled: [], dividers: [], layers: [])
    if let layout {
      placed.panes = LayoutGeometry.frames(layout, in: rect, divider: divider)
      placed.tiled = layout.panes
      placed.dividers = LayoutGeometry.dividers(
        layout,
        in: rect,
        divider: divider
      )
    }
    for layer in layers where !layer.minimized {
      let outer = LayoutGeometry.layerFrame(layer.bounds, in: rect)
      placed.layers.append(LayerFrame(layer: layer, outer: outer))
      let inner = LayoutGeometry.inset(outer, by: floatInset)
      let frames = LayoutGeometry.frames(
        layer.layout,
        in: inner,
        divider: divider
      )
      placed.panes.merge(frames) { _, new in new }
      var splits = LayoutGeometry.dividers(
        layer.layout,
        in: inner,
        divider: divider
      )
      for index in splits.indices { splits[index].layer = layer.id }
      placed.dividers.append(contentsOf: splits)
    }
    return placed
  }
}

extension TabSnapshot: LayeredTab {}
