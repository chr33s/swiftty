import Foundation

/// The visible screen as plain text for screen readers (VoiceOver on
/// macOS and iOS): one line per row, with UTF-16 ranges for the
/// platform APIs, and the cursor's position in it.
public struct AccessibilityText: Sendable, Equatable {
  public let lines: [String]
  /// `lines` joined with newlines.
  public let string: String
  /// Range of each line in `string`, in UTF-16 units, excluding the newline.
  public let lineRanges: [NSRange]
  /// UTF-16 offset of the cursor in `string`, clamped to the visible text
  /// when scrollback places the cursor outside the viewport.
  public let cursorOffset: Int
  public let cursorLine: Int

  public init(_ snapshot: RenderSnapshot) {
    let rows = snapshot.rowCount - snapshot.overscanRows
    let lines = Array(snapshot.text.prefix(rows))
    var ranges: [NSRange] = []
    var offset = 0
    for line in lines {
      let length = line.utf16.count
      ranges.append(NSRange(location: offset, length: length))
      offset += length + 1
    }
    self.lines = lines
    string = lines.joined(separator: "\n")
    lineRanges = ranges
    let cursorRow = snapshot.cursor.y + snapshot.viewportOffset
    let y = min(max(cursorRow, 0), max(lines.count - 1, 0))
    cursorLine = y
    // Text before the cursor's column, as the line renders it.
    var prefix = 0
    if y < lines.count, cursorRow == y {
      let cells = snapshot.cells(row: y)
      for x in 0 ..< min(snapshot.cursor.x, cells.count)
      where !cells[x].isSpacer {
        let cell = cells[x]
        if cell.isGrapheme {
          let scalars = snapshot.graphemeScalars(cell)
          for i in 0 ..< scalars.count {
            prefix +=
              Unicode.Scalar(scalars[i]).map { String($0).utf16.count } ?? 1
          }
        } else {
          prefix +=
            cell.glyph == 0
            ? 1 : Unicode.Scalar(cell.glyph).map { String($0).utf16.count } ?? 1
        }
      }
      cursorOffset = ranges[y].location + min(prefix, ranges[y].length)
    } else if y < ranges.count {
      cursorOffset = ranges[y].location + (cursorRow > y ? ranges[y].length : 0)
    } else {
      cursorOffset = 0
    }
  }

  /// Line containing UTF-16 offset `offset`.
  public func line(forOffset offset: Int) -> Int {
    lineRanges.lastIndex { $0.location <= offset } ?? 0
  }
}
