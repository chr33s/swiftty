public enum OuterColor: Hashable, Sendable {
  case `default`
  case palette(UInt8)
  case rgb(UInt32)

  /// From an engine `TerminalColor` raw value.
  public init(raw: UInt32) {
    switch raw >> 24 {
    case 1: self = .palette(UInt8(truncatingIfNeeded: raw))
    case 2: self = .rgb(raw & 0xFF_FFFF)
    default: self = .default
    }
  }
}

public struct OuterStyle: Hashable, Sendable {
  public var foreground: OuterColor = .default
  public var background: OuterColor = .default
  public var underlineColor: OuterColor = .default
  /// Engine `CellFlags` bits (structural bits never set here).
  public var flags: UInt16 = 0

  public static let plain = OuterStyle()

  package static let bold: UInt16 = 1 << 0
  package static let faint: UInt16 = 1 << 1
  package static let italic: UInt16 = 1 << 2
  package static let underline: UInt16 = 1 << 3
  package static let doubleUnderline: UInt16 = 1 << 4
  package static let blink: UInt16 = 1 << 5
  package static let inverse: UInt16 = 1 << 6
  package static let invisible: UInt16 = 1 << 7
  package static let strikethrough: UInt16 = 1 << 8
  package static let overline: UInt16 = 1 << 9
  package static let underlineStyleA: UInt16 = 1 << 11
  package static let underlineStyleB: UInt16 = 1 << 15

  public init(
    foreground: OuterColor = .default,
    background: OuterColor = .default,
    underlineColor: OuterColor = .default,
    flags: UInt16 = 0
  ) {
    self.foreground = foreground
    self.background = background
    self.underlineColor = underlineColor
    self.flags = flags
  }

  package func toggling(_ flag: UInt16) -> OuterStyle {
    var copy = self
    copy.flags ^= flag
    return copy
  }

  /// SGR for exactly this style, starting from a reset.
  package var sgr: String {
    var p = ["0"]
    if flags & Self.bold != 0 { p.append("1") }
    if flags & Self.faint != 0 { p.append("2") }
    if flags & Self.italic != 0 { p.append("3") }
    if flags & Self.doubleUnderline != 0 {
      p.append("21")
    } else if flags & Self.underline != 0 {
      let a = flags & Self.underlineStyleA != 0
      let b = flags & Self.underlineStyleB != 0
      p.append(a && b ? "4:5" : a ? "4:3" : b ? "4:4" : "4")
    }
    if flags & Self.blink != 0 { p.append("5") }
    if flags & Self.inverse != 0 { p.append("7") }
    if flags & Self.invisible != 0 { p.append("8") }
    if flags & Self.strikethrough != 0 { p.append("9") }
    if flags & Self.overline != 0 { p.append("53") }
    switch foreground {
    case .default: break
    case let .palette(i): p.append("38;5;\(i)")
    case let .rgb(v):
      p.append("38;2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)")
    }
    switch background {
    case .default: break
    case let .palette(i): p.append("48;5;\(i)")
    case let .rgb(v):
      p.append("48;2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)")
    }
    switch underlineColor {
    case .default: break  // SGR 0 restores the foreground underline color.
    case let .palette(i): p.append("58;5;\(i)")
    case let .rgb(v):
      p.append("58;2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)")
    }
    return "\u{1B}[" + p.joined(separator: ";") + "m"
  }
}

/// One composed outer cell. `width` 2 is a wide lead whose right half is a
/// `width` 0 continuation.
public struct ScreenCell: Hashable, Sendable {
  public var text: String
  public var width: UInt8
  public var style: OuterStyle

  public static let blank = ScreenCell(text: " ", width: 1, style: .plain)

  public init(text: String, width: UInt8 = 1, style: OuterStyle = .plain) {
    self.text = text
    self.width = width
    self.style = style
  }
}

/// Everything that produced one composed row, compared exactly
/// (spec.multiplexer.md §6, "Keyed row diffing"). Two rows with equal
/// keys hold equal cells, so the diff can skip comparing them.
public struct RowKey: Hashable, Sendable {
  public var parts: [UInt64]

  public init(_ parts: [UInt64] = []) { self.parts = parts }

  public mutating func append(_ v: UInt64) { parts.append(v) }
  public mutating func append(_ v: Int) {
    parts.append(UInt64(bitPattern: Int64(v)))
  }
}

/// The composed workspace for the outer terminal.
public struct ScreenBuffer: Equatable, Sendable {
  public let columns: Int
  public let rows: Int
  public var cells: [ScreenCell]
  public var cursor: (x: Int, y: Int, style: UInt8)?
  /// Per row, the key of what drew it, or nil when unkeyed (compared
  /// cell by cell). Only an optimization: never part of equality.
  public var rowKeys: [RowKey?]

  public init(columns: Int, rows: Int) {
    self.columns = max(1, columns)
    self.rows = max(1, rows)
    cells = Array(repeating: .blank, count: self.columns * self.rows)
    rowKeys = Array(repeating: nil, count: self.rows)
  }

  /// Forgets every key, after drawing over rows without keying them.
  public mutating func unkeyAll() {
    rowKeys = Array(repeating: nil, count: rows)
  }

  public subscript(x: Int, y: Int) -> ScreenCell {
    get { cells[y * columns + x] }
    set { cells[y * columns + x] = newValue }
  }

  /// Writes a cell, repairing any wide character it splits.
  public mutating func put(_ cell: ScreenCell, x: Int, y: Int) {
    guard x >= 0, y >= 0, x < columns, y < rows else { return }
    let i = y * columns + x
    if cells[i].width == 0, x > 0 { cells[i - 1] = .blank }
    if cells[i].width == 2, x + 1 < columns { cells[i + 1] = .blank }
    if cell.width == 2 {
      guard x + 1 < columns else {
        cells[i] = ScreenCell(text: " ", style: cell.style)
        return
      }
      if cells[i + 1].width == 2, x + 2 < columns { cells[i + 2] = .blank }
      cells[i] = cell
      cells[i + 1] = ScreenCell(text: "", width: 0, style: cell.style)
      return
    }
    cells[i] = cell
  }

  /// Writes chrome text in display cells, clipping only at grapheme boundaries.
  public mutating func write(
    _ text: String,
    x: Int,
    y: Int,
    style: OuterStyle,
    limit: Int? = nil
  ) {
    var cx = x
    let end = min(columns, limit.map { x + $0 } ?? columns)
    for glyph in TerminalText.glyphs(text) {
      guard cx + glyph.width <= end else { break }
      if cx >= 0 {
        put(
          ScreenCell(text: glyph.text, width: UInt8(glyph.width), style: style),
          x: cx,
          y: y
        )
      }
      cx += glyph.width
    }
  }

  public func text(row y: Int) -> String {
    var s = ""
    for x in 0 ..< columns where cells[y * columns + x].width != 0 {
      s += cells[y * columns + x].text
    }
    while s.last == " " { s.removeLast() }
    return s
  }

  public static func == (a: ScreenBuffer, b: ScreenBuffer) -> Bool {
    a.columns == b.columns && a.rows == b.rows && a.cells == b.cells
      && a.cursor?.x == b.cursor?.x && a.cursor?.y == b.cursor?.y
      && a.cursor?.style == b.cursor?.style
  }
}

/// Encodes only changed cells against the last fully completed update,
/// using the verified Swiftty outer subset: CUP, SGR (256/truecolor),
/// DECTCEM, DECSCUSR and synchronized output (2026).
public struct DiffRenderer {
  private var baseline: ScreenBuffer?

  public init() {}

  /// Forget the baseline (reconnect, resize or output failure).
  public mutating func invalidate() { baseline = nil }

  /// Rows of `screen` whose key equals the baseline's: they are skipped
  /// without comparing cells.
  public func keyedRows(of screen: ScreenBuffer) -> Set<Int> {
    guard let old = baseline, old.columns == screen.columns,
      old.rows == screen.rows, old.rowKeys.count == screen.rowKeys.count
    else { return [] }
    var rows: Set<Int> = []
    for y in 0 ..< screen.rows {
      if let key = screen.rowKeys[y], key == old.rowKeys[y] { rows.insert(y) }
    }
    return rows
  }

  /// Bytes to transform the outer display into `screen`. Call
  /// `commit(screen)` only after all bytes were written. With `useKeys`,
  /// rows whose key matches the baseline's are not compared.
  public func update(to screen: ScreenBuffer, useKeys: Bool = true) -> [UInt8] {
    var out = "\u{1B}[?2026h\u{1B}[?25l"
    let old = baseline.flatMap {
      $0.columns == screen.columns && $0.rows == screen.rows ? $0 : nil
    }
    if old == nil { out += "\u{1B}[0m\u{1B}[H\u{1B}[2J" }
    let skipped = useKeys ? keyedRows(of: screen) : []
    var pen: OuterStyle?
    var at: (x: Int, y: Int)?
    for y in 0 ..< screen.rows where !skipped.contains(y) {
      var x = 0
      while x < screen.columns {
        let i = y * screen.columns + x
        let cell = screen.cells[i]
        let span = cell.width == 2 && x + 1 < screen.columns ? 2 : 1
        var changed = old == nil || old!.cells[i] != cell
        if !changed, span == 2 {
          changed = old!.cells[i + 1] != screen.cells[i + 1]
        }
        if cell.width == 0 {
          // Continuation of a lead drawn (or unchanged) to the left.
          x += 1
          continue
        }
        if changed {
          if at == nil || at! != (x, y) { out += "\u{1B}[\(y + 1);\(x + 1)H" }
          if pen != cell.style {
            out += cell.style.sgr
            pen = cell.style
          }
          out += cell.text.isEmpty ? " " : cell.text
          at = (x + span, y)
        }
        x += span
      }
    }
    out += "\u{1B}[0m"
    if let c = screen.cursor {
      out += "\u{1B}[\(c.y + 1);\(c.x + 1)H"
      // DECSCUSR: steady block 2, underline 4, bar 6.
      out += "\u{1B}[\(c.style == 1 ? 4 : c.style == 2 ? 6 : 2) q"
      out += "\u{1B}[?25h"
    }
    out += "\u{1B}[?2026l"
    return Array(out.utf8)
  }

  public mutating func commit(_ screen: ScreenBuffer) { baseline = screen }
}
