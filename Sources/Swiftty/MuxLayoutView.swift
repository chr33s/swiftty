import AppKit
import SwiftMuxProtocol

/// Lays out pane views from the logical split tree; dividers drag. A
/// split tab shows its panes as cards with even gaps (the dividers) and
/// the same margin around them; a single pane fills the window.
@MainActor
final class MuxLayoutView: NSView {
  /// The gap between pane cards, which is also the draggable divider.
  static let divider = 5
  /// Space around the cards of a split tab.
  static let margin = 5
  /// The resize margin around a floating layer, in points.
  static let floatInset = 8
  /// The strip of minimized-layer chips along the bottom.
  static let chipStrip = 32

  /// The area panes are laid out in, in layout coordinates (y down).
  static func area(
    _ bounds: NSRect,
    split: Bool,
    margin: Int = margin
  ) -> LayoutRect {
    let inset = split ? margin : 0
    return LayoutRect(
      x: inset,
      y: inset,
      width: max(0, Int(bounds.width) - 2 * inset),
      height: max(0, Int(bounds.height) - 2 * inset)
    )
  }
  weak var controller: MuxWorkspaceController?
  /// The panes show in a rounded card, which already sets them apart
  /// (tabs on the left): a split tab's cards need no margin of their own.
  var isCard = false {
    didSet {
      guard isCard != oldValue else { return }
      layer?.cornerCurve = .continuous
      layer?.cornerRadius = isCard ? MuxPaneContainer.cornerRadius : 0
      layer?.masksToBounds = isCard
      needsLayout = true
    }
  }
  var splitMargin: Int { isCard ? 0 : Self.margin }
  private(set) var dividers: [LayoutDivider] = []
  /// Outer frames of visible floating layers, in layout coordinates.
  private var layerFrames: [LayerFrame] = []
  private var dragging: LayoutDivider?
  private var dividerElements: [MuxDividerElement] = []
  private var chips: [LayerID: MuxLayerChip] = [:]

  override init(frame: NSRect) {
    super.init(frame: frame)
    // Layer-backed from the start: turning it on while shown would redraw
    // the whole subtree.
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { false }

  override func layout() {
    super.layout()
    guard let controller else { return }
    let arranged = controller.layout(in: bounds)
    dividers = arranged.dividers
    layerFrames = arranged.layers
    let shown = Set(arranged.panes.map { ObjectIdentifier($0.0) })
    for case let pane as MuxPaneContainer in subviews {
      pane.isHidden = !shown.contains(ObjectIdentifier(pane))
    }
    for (view, frame) in arranged.panes {
      view.isHidden = false
      view.frame = frame
    }
    // Bring front panes forward only when the order changed. Reordering
    // on every pass would schedule layout again.
    let wanted = arranged.panes.map(\.0)
    let visible = subviews.compactMap { $0 as? MuxPaneContainer }
      .filter { !$0.isHidden }
    if visible != wanted { for view in wanted { addSubview(view) } }
    placeChips(arranged.chips)
    window?.invalidateCursorRects(for: self)
    dividerElements = dividers.map { d in
      let element = MuxDividerElement(divider: d, in: self)
      element.setAccessibilityFrameInParentSpace(appKitRect(d.rect))
      return element
    }
  }

  /// Minimized layers sit in a strip along the bottom, above nothing else.
  /// Chips are reparented only when their set or order changes. Framing
  /// them on every pass would schedule layout again.
  private func placeChips(_ items: [(id: LayerID, title: String)]) {
    let keep = Set(items.map(\.id))
    for id in chips.keys.filter({ !keep.contains($0) }) {
      chips[id]?.removeFromSuperview()
      chips.removeValue(forKey: id)
    }
    let pad: CGFloat = 4
    let count = CGFloat(max(1, items.count))
    let width = max(48, min(160, (bounds.width - pad) / count - pad))
    let ordered = items.enumerated()
      .map { index, item in
        let chip = chips[item.id] ?? makeChip(item.id)
        chip.layerID = item.id
        chip.title = item.title
        chip.setAccessibilityLabel("Restore \(item.title)")
        chip.isHidden = false
        chip.frame = NSRect(
          x: pad + CGFloat(index) * (width + pad),
          y: pad,
          width: width,
          height: CGFloat(Self.chipStrip) - pad * 2
        )
        return chip
      }
    let trailing = subviews.suffix(ordered.count)
    let settled =
      trailing.count == ordered.count
      && zip(trailing, ordered).allSatisfy { $0.0 === $0.1 }
    if !settled { for chip in ordered { addSubview(chip) } }
  }

  private func makeChip(_ id: LayerID) -> MuxLayerChip {
    let chip = MuxLayerChip()
    chip.layerID = id
    chip.onRestore = { [weak self] id in self?.controller?.restoreLayer(id) }
    chips[id] = chip
    return chip
  }

  func appKitRect(_ r: LayoutRect) -> NSRect {
    NSRect(
      x: r.x,
      y: Int(bounds.height) - r.maxY,
      width: r.width,
      height: r.height
    )
  }

  override func accessibilityChildren() -> [Any]? {
    (super.accessibilityChildren() ?? []) + dividerElements
  }

  private func flippedY(_ p: NSPoint) -> Int { Int(bounds.height - p.y) }

  override func resetCursorRects() {
    // A handle shows only where no layer in front of it covers it.
    func add(_ rect: LayoutRect, _ cursor: NSCursor, under front: Int) {
      var pieces = [rect]
      for cover in layerFrames[front...] {
        pieces = pieces.flatMap { Self.subtract(cover.outer, from: $0) }
      }
      for piece in pieces { addCursorRect(appKitRect(piece), cursor: cursor) }
    }
    for d in dividers {
      let front =
        d.layer.flatMap { id in layerFrames.firstIndex { $0.id == id } }
        .map { $0 + 1 } ?? 0
      add(
        d.rect,
        d.axis == .leftRight ? .resizeLeftRight : .resizeUpDown,
        under: front
      )
    }
    for (index, frame) in layerFrames.enumerated() {
      for (rect, cursor) in edgeStrips(frame.outer) {
        add(rect, cursor, under: index + 1)
      }
    }
  }

  /// The four resize strips in a layer's margin, in layout coordinates.
  private func edgeStrips(_ outer: LayoutRect) -> [(LayoutRect, NSCursor)] {
    let inner = LayoutGeometry.inset(outer, by: Self.floatInset)
    guard inner != outer else { return [] }
    return [
      (
        LayoutRect(
          x: inner.x,
          y: outer.y,
          width: inner.width,
          height: inner.y - outer.y
        ), .resizeUpDown
      ),
      (
        LayoutRect(
          x: inner.x,
          y: inner.maxY,
          width: inner.width,
          height: outer.maxY - inner.maxY
        ), .resizeUpDown
      ),
      (
        LayoutRect(
          x: outer.x,
          y: inner.y,
          width: inner.x - outer.x,
          height: inner.height
        ), .resizeLeftRight
      ),
      (
        LayoutRect(
          x: inner.maxX,
          y: inner.y,
          width: outer.maxX - inner.maxX,
          height: inner.height
        ), .resizeLeftRight
      ),
    ]
  }

  /// `rect` minus `cover`, as up to four rectangles.
  private static func subtract(
    _ cover: LayoutRect,
    from rect: LayoutRect
  ) -> [LayoutRect] {
    let left = max(rect.x, cover.x)
    let right = min(rect.maxX, cover.maxX)
    let top = max(rect.y, cover.y)
    let bottom = min(rect.maxY, cover.maxY)
    guard left < right, top < bottom else { return [rect] }
    var out: [LayoutRect] = []
    if rect.y < top {
      out.append(
        LayoutRect(
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: top - rect.y
        )
      )
    }
    if bottom < rect.maxY {
      out.append(
        LayoutRect(
          x: rect.x,
          y: bottom,
          width: rect.width,
          height: rect.maxY - bottom
        )
      )
    }
    if rect.x < left {
      out.append(
        LayoutRect(
          x: rect.x,
          y: top,
          width: left - rect.x,
          height: bottom - top
        )
      )
    }
    if right < rect.maxX {
      out.append(
        LayoutRect(
          x: right,
          y: top,
          width: rect.maxX - right,
          height: bottom - top
        )
      )
    }
    return out
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    return hit(at: local) != nil ? self : super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    dragging = nil
    switch hit(at: convert(event.locationInWindow, from: nil)) {
    case let .divider(divider)?: dragging = divider
    case let .edge(layer, edges)?:
      controller?.trackLayer(layer, edges: edges, event)
    case nil: break
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let d = dragging else { return }
    let p = convert(event.locationInWindow, from: nil)
    let ratio =
      d.axis == .leftRight
      ? (Double(p.x) - Double(d.parent.x)) / Double(max(1, d.parent.width))
      : (Double(flippedY(p)) - Double(d.parent.y))
        / Double(max(1, d.parent.height))
    controller?.setRatio(ratio, path: d.path, layer: d.layer)
  }

  private enum Hit {
    case divider(LayoutDivider)
    case edge(LayerID, LayerEdges)
  }

  /// What `point` grabs. Only the front-most layer under it counts, so a
  /// tiled divider or a lower layer never reacts through a float.
  private func hit(at point: NSPoint) -> Hit? {
    let x = Int(point.x)
    let y = flippedY(point)
    guard let frame = layerFrames.last(where: { $0.outer.contains(x: x, y: y) })
    else {
      return dividers.first { $0.layer == nil && $0.rect.contains(x: x, y: y) }
        .map(Hit.divider)
    }
    if let divider = dividers.first(where: {
      $0.layer == frame.id && $0.rect.contains(x: x, y: y)
    }) {
      return .divider(divider)
    }
    let outer = frame.outer
    let inner = LayoutGeometry.inset(outer, by: Self.floatInset)
    guard inner != outer, !inner.contains(x: x, y: y) else { return nil }
    var edges: LayerEdges = []
    if x < inner.x { edges.insert(.left) }
    if x >= inner.maxX { edges.insert(.right) }
    if y < inner.y { edges.insert(.top) }
    if y >= inner.maxY { edges.insert(.bottom) }
    return edges.isEmpty ? nil : .edge(frame.id, edges)
  }

  override func mouseUp(with event: NSEvent) { dragging = nil }
}

/// A split handle for assistive technologies: its value is the first
/// child's share; increment and decrement move it in 5% steps.
/// AppKit calls accessibility on the main thread.
final class MuxDividerElement: NSAccessibilityElement {
  let divider: LayoutDivider
  private weak var layoutView: MuxLayoutView?

  @MainActor
  init(divider: LayoutDivider, in view: MuxLayoutView) {
    self.divider = divider
    layoutView = view
    super.init()
    setAccessibilityParent(view)
    setAccessibilityRole(.splitter)
    setAccessibilityOrientation(
      divider.axis == .leftRight ? .vertical : .horizontal
    )
    setAccessibilityLabel(
      divider.axis == .leftRight ? "Left/right divider" : "Top/bottom divider"
    )
  }

  override func accessibilityValue() -> Any? {
    let (view, path, layer) = (layoutView, divider.path, divider.layer)
    return
      MainActor.assumeIsolated {
        view?.controller?.ratio(at: path, layer: layer)
      }
      .map { $0 as NSNumber }
  }

  override func accessibilityPerformIncrement() -> Bool { move(0.05) }
  override func accessibilityPerformDecrement() -> Bool { move(-0.05) }

  private func move(_ delta: Double) -> Bool {
    let (view, path, layer) = (layoutView, divider.path, divider.layer)
    return MainActor.assumeIsolated {
      guard let controller = view?.controller,
        let ratio = controller.ratio(at: path, layer: layer)
      else { return false }
      controller.setRatio(ratio + delta, path: path, layer: layer)
      return true
    }
  }
}

struct RatioProposal: Equatable {
  var tab: TabID
  var path: [Bool]
  var ratio: Double
  var layer: LayerID? = nil
}

struct LayerProposal: Equatable, Sendable {
  var tab: TabID
  var layer: LayerID
  var bounds: LayerRect
}

struct MuxArrangedPanes {
  var panes: [(MuxPaneContainer, NSRect)]
  var dividers: [LayoutDivider]
  var layers: [LayerFrame]
  var chips: [(id: LayerID, title: String)]
}

/// A minimized floating layer, restored by a click.
@MainActor
final class MuxLayerChip: NSButton {
  var layerID = LayerID()
  var onRestore: ((LayerID) -> Void)?

  init() {
    super.init(frame: .zero)
    bezelStyle = .recessed
    setButtonType(.momentaryPushIn)
    controlSize = .small
    font = .systemFont(ofSize: 12)
    lineBreakMode = .byTruncatingTail
    target = self
    action = #selector(restore)
    toolTip = "Restore floating layer"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc
  private func restore() { onRestore?(layerID) }
}

struct MuxUnavailable: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}
