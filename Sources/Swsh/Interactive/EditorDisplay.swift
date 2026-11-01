/// Paints explicit hard rows, reserving the last column to avoid terminal soft
/// wrapping. Track occupied rows for edits and refresh a saved cursor origin
/// after scrolling; terminals map that anchor through resize/reflow.
struct EditorDisplay {
  private var paintedLines: [String] = []
  private var previousColumns = 0
  private var previousRows = 0

  mutating func paint(
    prompt: String,
    bytes: [UInt8],
    columns: Int,
    rows: Int
  ) -> [UInt8] {
    let width = max(1, columns - 1)
    var lines = [String()]
    var column = 0
    for character in prompt + String(decoding: bytes, as: UTF8.self) {
      let cells = Self.cells(character)
      if column + cells > width && column > 0 {
        lines.append("")
        column = 0
      }
      // A two-cell glyph cannot fit on a one-column display.
      let text = cells > width ? "?" : String(character)
      lines[lines.count - 1] += text
      column += min(cells, width)
    }
    let visible = lines.suffix(max(1, rows))
    let cursorRow = max(0, paintedLines.count - 1)
    let resized = previousColumns != columns || previousRows != rows
    let before = Array(paintedLines.joined(separator: "\r\n").utf8)
    let after = Array(visible.joined(separator: "\r\n").utf8)
    let up = min(cursorRow, max(0, rows - 1))
    let prefix: String
    if previousColumns != 0 && resized {
      prefix = "\u{1B}8\r\u{1B}[J"
    } else {
      prefix = "\r" + (up > 0 ? "\u{1B}[\(up)A" : "") + "\u{1B}[J"
    }
    let output: [UInt8]
    if !resized && !before.isEmpty && after.starts(with: before) {
      output = Array(after.dropFirst(before.count))
    } else {
      output = Array(prefix.utf8) + after
    }
    paintedLines = Array(visible)
    previousColumns = columns
    previousRows = rows
    // Refresh the saved origin after scrolling, without leaving the cursor there.
    let offset = visible.count - 1
    let endColumn = visible.last?.reduce(0) { $0 + Self.cells($1) } ?? 0
    let anchor =
      "\r" + (offset > 0 ? "\u{1B}[\(offset)A" : "") + "\u{1B}7"
      + (offset > 0 ? "\u{1B}[\(offset)B" : "")
      + (endColumn > 0 ? "\u{1B}[\(endColumn)C" : "")
    return output + Array(anchor.utf8)
  }

  private static func cells(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    if scalars.contains(where: {
      $0.properties.isEmojiPresentation || $0.value == 0xFE0F
    }) {
      return 2
    }
    var width = 0
    for scalar in scalars {
      switch scalar.properties.generalCategory {
      case .nonspacingMark, .enclosingMark, .format: continue
      default: break
      }
      let v = scalar.value
      let wide =
        (0x1100 ... 0x115F).contains(v) || (0x2329 ... 0x232A).contains(v)
        || (0x2E80 ... 0xA4CF).contains(v) || (0xAC00 ... 0xD7A3).contains(v)
        || (0xF900 ... 0xFAFF).contains(v) || (0xFE10 ... 0xFE19).contains(v)
        || (0xFE30 ... 0xFE6F).contains(v) || (0xFF01 ... 0xFF60).contains(v)
        || (0xFFE0 ... 0xFFE6).contains(v) || (0x20000 ... 0x3FFFD).contains(v)
      width = max(width, wide ? 2 : 1)
    }
    return width
  }
}
