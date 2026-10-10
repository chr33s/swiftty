import SwifttyCore

/// Physical rows of the editable command. A viewport can show any slice
/// without losing the text outside it or moving the caret through history.
struct DemoCommandLayout {
  var rows: [[UInt8]] = [[]]
  private var caretRow = 0
  private var caretColumn = 0
  private var pendingWrap = false
  private var promptEndRow = 0
  private var promptEndOffset = 0

  init(
    line: [Unicode.Scalar],
    cursor: Int,
    columns: Int,
    render: ([Unicode.Scalar]) -> [UInt8]
  ) {
    var column = 0
    func append(_ bytes: [UInt8], width: Int) {
      if column == columns || column + width > columns {
        rows.append([])
        column = 0
      }
      rows[rows.count - 1] += bytes
      column += width
    }
    for (i, scalar) in "demo:~$ ".unicodeScalars.enumerated() {
      let style = i < 4 ? "\u{1B}[1;32m" : i == 5 ? "\u{1B}[1;34m" : "\u{1B}[0m"
      append(Array(style.utf8) + [UInt8(scalar.value)], width: 1)
    }
    rows[rows.count - 1] += Array("\u{1B}[0m".utf8)
    promptEndRow = rows.count - 1
    promptEndOffset = rows[promptEndRow].count
    if line.allSatisfy(\.isASCII) {
      // ASCII command text has one cell per scalar. Batch complete
      // row segments instead of allocating and rendering each key.
      if cursor < line.count {
        caretRow = (8 + cursor) / columns
        caretColumn = (8 + cursor) % columns
      }
      var first = 0
      while first < line.count {
        if column == columns {
          rows.append([])
          column = 0
        }
        let length = min(columns - column, line.count - first)
        rows[rows.count - 1]
          .append(
            contentsOf: line[first ..< first + length].map { UInt8($0.value) }
          )
        column += length
        first += length
      }
    } else {
      let values = line.map(\.value)
      var first = 0
      while first < line.count {
        if first == cursor {
          caretRow = rows.count - 1 + (column == columns ? 1 : 0)
          caretColumn = column == columns ? 0 : column
        }
        let cluster = UnicodeWidth.graphemeWidth(values[first...])
        append(
          render(Array(line[first ..< first + cluster.length])),
          width: min(columns, max(1, cluster.width))
        )
        first += cluster.length
      }
    }
    if cursor == line.count {
      caretRow = rows.count - 1
      caretColumn = min(column, columns - 1)
      pendingWrap = column == columns
    }
  }

  func frame(height: Int) -> [UInt8] {
    let top = min(max(0, caretRow - height / 2), max(0, rows.count - height))
    // Resize reflows the current viewport; the demo receives its new
    // dimensions with the next input, rather than redrawing on SIGWINCH.
    var out = Array(
      "\u{1B}[H\u{1B}[2J\u{1B}]133;A;redraw=0;k=\(top == 0 ? "i" : "s")\u{7}"
        .utf8
    )
    if top > 0 { out += Array("\u{1B}]133;B\u{7}".utf8) }
    for row in top ..< min(rows.count, top + height) {
      if top == 0, row == promptEndRow {
        out += rows[row][..<promptEndOffset]
        out += Array("\u{1B}]133;B\u{7}".utf8)
        out += rows[row][promptEndOffset...]
      } else {
        out += rows[row]
      }
    }
    // At an end-of-line pending wrap, leave the cursor in that state.
    if !pendingWrap {
      out += Array("\u{1B}[\(caretRow - top + 1);\(caretColumn + 1)H".utf8)
    }
    return out
  }
}
