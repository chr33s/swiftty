import TTYKit
import Foundation
import SwiftMuxProtocol

/// What the compositor draws over one pane.
public struct PaneOverlay: Sendable {
  /// Inclusive selection in viewport cells.
  public var selection:
    (start: (row: Int, column: Int), end: (row: Int, column: Int), lines: Bool)?
  /// Copy-mode cursor.
  public var cursor: (row: Int, column: Int)?

  public init(
    selection: (
      start: (row: Int, column: Int), end: (row: Int, column: Int), lines: Bool
    )? = nil,
    cursor: (row: Int, column: Int)? = nil
  ) {
    self.selection = selection
    self.cursor = cursor
  }
}

/// Composes owned pane frames into one terminal-sized workspace with
/// one-cell dividers and a status row. Decoration belongs to this
/// frontend; the shared layout has no border.
public struct Compositor {
  public static let divider = 1

  public var columns: Int
  public var rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = max(1, columns)
    self.rows = max(1, rows)
  }

  /// Area for panes: everything above the status row.
  public var paneArea: LayoutRect {
    LayoutRect(x: 0, y: 0, width: columns, height: max(0, rows - 1))
  }

  /// Visible pane rectangles of a tab, honouring zoom.
  public func frames(for tab: TabSnapshot) -> [PaneID: LayoutRect] {
    if let zoomed = tab.zoomedPane { return [zoomed: paneArea] }
    return LayoutGeometry.frames(
      tab.layout,
      in: paneArea,
      divider: Self.divider
    )
  }

  public func dividers(for tab: TabSnapshot) -> [LayoutDivider] {
    guard tab.zoomedPane == nil else { return [] }
    return LayoutGeometry.dividers(
      tab.layout,
      in: paneArea,
      divider: Self.divider
    )
  }

  public func compose(
    workspace: WorkspaceSnapshot,
    frames: [PaneID: PaneFrame],
    overlays: [PaneID: PaneOverlay] = [:],
    status: StatusLine,
    showCursor: Bool,
    paletteTokens: [PaneID: UInt64] = [:]
  ) -> ScreenBuffer {
    var screen = ScreenBuffer(columns: columns, rows: rows)
    guard let tab = workspace.activeTabSnapshot else {
      drawStatus(status, into: &screen)
      return screen
    }
    let rects = self.frames(for: tab)
    for (pane, rect) in rects {
      if let frame = frames[pane] {
        draw(frame, in: rect, overlay: overlays[pane], into: &screen)
      } else {
        screen.fill(rect)
      }
      if let exit = workspace.pane(pane)?.exitStatus, rect.height > 0 {
        let note = " [exited \(exit)] "
        screen.write(
          note,
          x: rect.x + max(0, rect.width - TerminalText.width(note)),
          y: rect.y,
          style: OuterStyle(foreground: .palette(0), background: .palette(3))
        )
      }
    }
    drawDividers(tab: tab, active: rects[tab.activePane], into: &screen)
    drawStatus(status, into: &screen)
    if showCursor, let rect = rects[tab.activePane],
      let frame = frames[tab.activePane],
      overlays[tab.activePane]?.cursor == nil, frame.cursor.visible,
      frame.cursor.x < rect.width, frame.cursor.y < rect.height
    {
      screen.cursor = (
        rect.x + frame.cursor.x, rect.y + frame.cursor.y, frame.cursor.style
      )
    }
    keyRows(
      of: &screen,
      workspace: workspace,
      tab: tab,
      frames: frames,
      overlays: overlays,
      paletteTokens: paletteTokens
    )
    return screen
  }

  /// Draws a frame clipped to `rect`; uncovered space stays blank while
  /// a resize is pending.
  func draw(
    _ frame: PaneFrame,
    in rect: LayoutRect,
    overlay: PaneOverlay?,
    into screen: inout ScreenBuffer
  ) {
    screen.fill(rect)
    let g = frame.grid
    let w = min(rect.width, g.columns)
    let h = min(rect.height, g.rows)
    var styleCache: [Int: OuterStyle] = [:]
    let reverse = frame.modes.contains(.reverseVideo)
    for y in 0 ..< h {
      for x in 0 ..< w {
        let i = y * g.columns + x
        let kind = g.kind(at: i)
        if kind == .continuation { continue }
        let si = g.style(at: i)
        var style =
          styleCache[si]
          ?? OuterStyle(
            frame.styles[si],
            palette: frame.palette,
            underlineColors: frame.underlineColors
          )
        styleCache[si] = style
        if reverse { style = style.toggling(OuterStyle.inverse) }
        if let overlay,
          Self.selected(overlay, row: y, column: x, columns: g.columns)
        {
          style = style.toggling(OuterStyle.inverse)
        }
        if let c = overlay?.cursor, c.row == y, c.column == x {
          style = style.toggling(OuterStyle.inverse)
        }
        let text: String
        var width: UInt8 = 1
        switch kind {
        case .padding: text = " "
        case .wideLead:
          // Clip a wide character that would cross the pane edge.
          if x + 1 >= w {
            text = " "
          } else {
            text = String(
              String.UnicodeScalarView(frame.scalars(row: y, column: x))
            )
            width = 2
          }
        default:
          text = String(
            String.UnicodeScalarView(frame.scalars(row: y, column: x))
          )
        }
        screen.put(
          ScreenCell(text: text, width: width, style: style),
          x: rect.x + x,
          y: rect.y + y
        )
      }
    }
    if h > 0, let search = frame.search {
      for (n, span) in search.visible.enumerated() {
        let style = OuterStyle(
          foreground: .palette(0),
          background: .palette(n == search.selectedVisible ? 3 : 11)
        )
        let firstRow = max(0, span.startRow)
        let lastRow = min(h - 1, span.endRow)
        guard firstRow <= lastRow else { continue }
        for row in firstRow ... lastRow {
          let from = row == span.startRow ? span.startColumn : 0
          let to = row == span.endRow ? span.endColumn : g.columns - 1
          guard from <= to else { continue }
          for x in from ... to where x < w {
            var cell = screen[rect.x + x, rect.y + row]
            guard cell.width != 0 else { continue }
            cell.style.foreground = style.foreground
            cell.style.background = style.background
            screen[rect.x + x, rect.y + row] = cell
          }
        }
      }
    }
  }

  /// Keys every pane row whose inputs are exact values: frame row
  /// identities, rectangles, palette tokens, overlays and search spans, plus
  /// the layout that places dividers. Rows with an exit note, a frame
  /// without versions or an unknown palette, and the status row stay
  /// unkeyed and are compared cell by cell.
  func keyRows(
    of screen: inout ScreenBuffer,
    workspace: WorkspaceSnapshot,
    tab: TabSnapshot,
    frames: [PaneID: PaneFrame],
    overlays: [PaneID: PaneOverlay],
    paletteTokens: [PaneID: UInt64]
  ) {
    var base = RowKey()
    base.append(workspace.layoutRevision)
    Self.append(tab.id.rawValue, to: &base)
    Self.append(tab.activePane.rawValue, to: &base)
    Self.append(tab.zoomedPane?.rawValue ?? Self.none, to: &base)
    base.append(columns)
    base.append(rows)
    let rects = self.frames(for: tab)
      .sorted { ($0.value.x, $0.value.y) < ($1.value.x, $1.value.y) }
    for y in 0 ..< paneArea.height {
      var key = base
      var keyed = true
      for (pane, rect) in rects
      where rect.height > 0 && y >= rect.y && y < rect.y + rect.height {
        let fy = y - rect.y
        if fy == 0, workspace.pane(pane)?.exitStatus != nil {
          keyed = false
          break
        }
        Self.append(pane.rawValue, to: &key)
        key.append(rect.x)
        key.append(rect.width)
        guard let frame = frames[pane] else {
          key.append(UInt64(1))
          continue
        }
        let g = frame.grid
        key.append(g.columns)
        guard fy < min(rect.height, g.rows) else {
          key.append(UInt64(2))
          continue
        }
        guard let identity = frame.rowIdentity(fy),
          let palette = paletteTokens[pane]
        else {
          keyed = false
          break
        }
        key.append(UInt64(3))
        key.append(identity.address.generation)
        key.append(identity.address.alternateScreen ? 1 : 0)
        key.append(identity.address.row)
        key.append(identity.version)
        key.append(palette)
        key.append(frame.modes.contains(.reverseVideo) ? 1 : 0)
        let overlay = overlays[pane]
        var selected: [Int] = []
        if let overlay {
          for x in 0 ..< g.columns
          where Self.selected(overlay, row: fy, column: x, columns: g.columns) {
            selected.append(x)
          }
        }
        key.append(selected.first.map { $0 + 1 } ?? 0)
        key.append(selected.last.map { $0 + 1 } ?? 0)
        key.append(selected.count)
        if let c = overlay?.cursor, c.row == fy {
          key.append(c.column + 1)
        } else {
          key.append(0)
        }
        if let search = frame.search {
          for (n, span) in search.visible.enumerated()
          where span.startRow <= fy && span.endRow >= fy {
            key.append(span.startRow == fy ? span.startColumn + 1 : 0)
            key.append(span.endRow == fy ? span.endColumn + 1 : 0)
            key.append(n == search.selectedVisible ? 1 : 0)
          }
        }
        key.append(UInt64.max)
      }
      screen.rowKeys[y] = keyed ? key : nil
    }
  }

  private static let none = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )

  private static func append(_ u: UUID, to key: inout RowKey) {
    withUnsafeBytes(of: u.uuid) { raw in
      key.append(raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
      key.append(raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
    }
  }

  static func selected(
    _ overlay: PaneOverlay,
    row: Int,
    column: Int,
    columns: Int
  ) -> Bool {
    guard let s = overlay.selection else { return false }
    var (a, b) = (s.start, s.end)
    if (b.row, b.column) < (a.row, a.column) { swap(&a, &b) }
    guard row >= a.row, row <= b.row else { return false }
    if s.lines { return true }
    if row == a.row, column < a.column { return false }
    if row == b.row, column > b.column { return false }
    return true
  }

  private func drawDividers(
    tab: TabSnapshot,
    active: LayoutRect?,
    into screen: inout ScreenBuffer
  ) {
    let dividers = self.dividers(for: tab)
    guard !dividers.isEmpty else { return }
    var mask = [Bool](repeating: false, count: columns * rows)
    for d in dividers {
      for y in d.rect.y ..< min(rows - 1, d.rect.maxY) {
        for x in d.rect.x ..< min(columns, d.rect.maxX) {
          mask[y * columns + x] = true
        }
      }
    }
    func on(_ x: Int, _ y: Int) -> Bool {
      x >= 0 && y >= 0 && x < columns && y < rows - 1 && mask[y * columns + x]
    }
    let normal = OuterStyle(foreground: .palette(8))
    let highlight = OuterStyle(foreground: .palette(2))
    for y in 0 ..< max(0, rows - 1) {
      for x in 0 ..< columns where mask[y * columns + x] {
        let u = on(x, y - 1)
        let d = on(x, y + 1)
        let l = on(x - 1, y)
        let r = on(x + 1, y)
        let ch: String =
          switch (u || d, l || r) {
          case (true, false): "│"
          case (false, _): "─"
          case (true, true):
            switch (u, d, l, r) {
            case (true, true, true, true): "┼"
            case (true, true, false, true): "├"
            case (true, true, true, false): "┤"
            case (false, true, _, _): "┬"
            default: "┴"
            }
          }
        let touchesActive =
          active.map { a in
            (x >= a.x - 1 && x <= a.maxX && y >= a.y - 1 && y <= a.maxY)
          } ?? false
        screen.put(
          ScreenCell(text: ch, style: touchesActive ? highlight : normal),
          x: x,
          y: y
        )
      }
    }
  }

  /// Draws a note (a message beside a prompt) right-aligned, shortened to
  /// `room`, or nothing when that is too little to read. Returns it.
  @discardableResult
  private func drawNote(
    _ text: String,
    room: Int,
    y: Int,
    style: OuterStyle,
    into screen: inout ScreenBuffer
  ) -> String {
    guard !text.isEmpty, room >= Self.minimumNote else { return "" }
    let note = TerminalText.head(text, width: room)
    screen.write(
      note,
      x: columns - TerminalText.width(note),
      y: y,
      style: style
    )
    return note
  }

  /// Narrowest room a note is drawn in.
  private static let minimumNote = 4

  private func drawStatus(_ status: StatusLine, into screen: inout ScreenBuffer)
  {
    let y = rows - 1
    let base = OuterStyle(foreground: .palette(0), background: .palette(2))
    screen.fill(LayoutRect(x: 0, y: y, width: columns, height: 1), style: base)
    if let prompt = status.prompt {
      let style = OuterStyle(foreground: .palette(0), background: .palette(3))
      guard status.promptCursor else {
        // A message or question keeps its start, and its suffix (answer
        // keys) whole; a note shows in what is left when that is readable.
        let suffix = TerminalText.tail(status.promptSuffix, width: columns)
        let shown =
          TerminalText.head(prompt, width: columns - TerminalText.width(suffix))
          + suffix
        screen.write(shown, x: 0, y: y, style: style)
        drawNote(
          status.right,
          room: columns - TerminalText.width(shown) - 1,
          y: y,
          style: base,
          into: &screen
        )
        return
      }
      // A typed prompt keeps its end, where the cursor is, clipping from
      // the left. It keeps its length up to half the line; a note (`right`,
      // a message) takes what is left.
      let line = columns - 1
      let note = drawNote(
        status.right,
        room: line - min(TerminalText.width(prompt), line / 2) - 1,
        y: y,
        style: base,
        into: &screen
      )
      let shown = TerminalText.tail(
        prompt,
        width: max(0, line - (note.isEmpty ? 0 : TerminalText.width(note) + 1))
      )
      screen.write(shown, x: 0, y: y, style: style)
      screen.cursor = (min(columns - 1, TerminalText.width(shown)), y, 2)
      return
    }
    let right = status.right
    let rightWidth = min(columns, TerminalText.width(right))
    var x = 0
    screen.write(
      status.left,
      x: x,
      y: y,
      style: base,
      limit: max(0, columns - rightWidth - 1)
    )
    x = min(columns, TerminalText.width(status.left))
    for item in status.items where x < columns - rightWidth - 1 {
      let style =
        item.active
        ? OuterStyle(
          foreground: .palette(0),
          background: .palette(2),
          flags: OuterStyle.bold | OuterStyle.inverse
        ) : base
      screen.write(
        item.text,
        x: x,
        y: y,
        style: style,
        limit: columns - rightWidth - 1 - x
      )
      x += TerminalText.width(item.text)
    }
    screen.write(right, x: columns - rightWidth, y: y, style: base)
  }
}

public struct StatusLine: Sendable {
  public struct Item: Sendable {
    public var text: String
    public var active: Bool
  }

  public var left = ""
  public var items: [Item] = []
  /// Right-hand status text; beside a prompt, a note (a message).
  public var right = ""
  /// Replaces `left` and `items`: a message, question or prompt (`right`
  /// then shows beside it as a note when there is room).
  public var prompt: String?
  /// `prompt` is being typed: the cursor follows it and its end stays in
  /// view. Otherwise it keeps its start.
  public var promptCursor = false
  /// Kept after a question however it is shortened ("? (y/n)").
  public var promptSuffix = ""

  public init() {}
}
