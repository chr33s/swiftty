import Foundation

/// A link under the pointer: an OSC 8 hyperlink, or a URL found in the text.
public struct TerminalLink: Sendable, Equatable {
  public var url: String
  /// Cells the link covers (inclusive), for underlining on hover.
  public var range: TerminalRange
  /// OSC 8 id when the link came from the application.
  public var id: UInt8
}

extension TerminalState {
  /// The link at `p`: the cell's OSC 8 hyperlink, else (with
  /// `detectURLs`, Ghostty's `link-url`) a URL in the surrounding text,
  /// followed across soft wraps.
  public func link(
    at p: TerminalPoint,
    detectURLs: Bool = true
  ) -> TerminalLink? {
    guard let (cells, _) = line(absoluteRow: p.row), p.column >= 0,
      p.column < cells.count
    else { return nil }
    var column = p.column
    if cells[column].width == 0, column > 0 { column -= 1 }
    let id = cells[column].attributes.link
    if id != 0, let url = hyperlink(id) {
      var lo = column
      var hi = column
      while lo > 0, cells[lo - 1].attributes.link == id { lo -= 1 }
      while hi + 1 < cells.count, cells[hi + 1].attributes.link == id {
        hi += 1
      }
      return TerminalLink(
        url: url,
        range: TerminalRange(
          start: TerminalPoint(row: p.row, column: lo),
          end: TerminalPoint(row: p.row, column: hi)
        ),
        id: id,
      )
    }
    guard detectURLs else { return nil }
    // The logical line around `p`, mapping each UTF-16 unit to its
    // cell so regex offsets work directly with combining marks and emoji.
    var top = p.row
    while let (_, wrapped) = line(absoluteRow: top - 1), wrapped { top -= 1 }
    var text = String.UnicodeScalarView()
    var points: [TerminalPoint] = []
    func append(_ scalar: Unicode.Scalar, at point: TerminalPoint) {
      text.append(scalar)
      points.append(point)
      if scalar.value > 0xFFFF { points.append(point) }
    }
    var row = top
    while let (rowCells, wrapped) = line(absoluteRow: row) {
      for x in 0 ..< rowCells.count where !rowCells[x].isSpacer {
        let cell = rowCells[x]
        let point = TerminalPoint(row: row, column: x)
        if cell.isGrapheme {
          var hasContent = false
          let scalars = graphemeScalars(cell.glyph)
          for value in scalars {
            if let scalar = Unicode.Scalar(value) {
              append(scalar, at: point)
              hasContent = true
            }
          }
          if !hasContent { append(" ", at: point) }
        } else if cell.glyph != 0, let scalar = Unicode.Scalar(cell.glyph) {
          append(scalar, at: point)
        } else {
          append(" ", at: point)
        }
      }
      guard wrapped else { break }
      row += 1
    }
    let string = String(text)
    let ns = string as NSString
    for match in Self.urlPattern?
      .matches(in: string, range: NSRange(location: 0, length: ns.length)) ?? []
    {
      let rawStart = points[match.range.location]
      let rawEnd = points[NSMaxRange(match.range) - 1]
      guard (rawStart.row, rawStart.column) <= (p.row, column),
        (p.row, column) <= (rawEnd.row, rawEnd.column)
      else { continue }
      var url = ns.substring(with: match.range)
      url = Self.trimURL(url)
      let count = url.utf16.count
      guard count > 0, match.range.location + count <= points.count else {
        continue
      }
      let start = points[match.range.location]
      var end = points[match.range.location + count - 1]
      if let (cells, _) = line(absoluteRow: end.row),
        cells[end.column].width == 2
      {
        end.column += 1
      }
      let range = TerminalRange(start: start, end: end)
      if (start.row, start.column) <= (p.row, column),
        (p.row, column) <= (end.row, end.column)
      {
        return TerminalLink(url: url, range: range, id: 0)
      }
    }
    return nil
  }

  private static let urlPattern = try? NSRegularExpression(
    pattern: #"(?:https?|ftp|file|ssh|git)://[^\s<>"'`]+|mailto:[^\s<>"'`]+"#,
    options: .caseInsensitive,
  )

  /// Drops trailing punctuation that usually ends a sentence, keeping a
  /// closing bracket that has its opening one inside the URL.
  private static func trimURL(_ url: String) -> String {
    let brackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    var counts: [Character: Int] = [:]
    var counted = false
    var url = Substring(url)
    while let last = url.last {
      if ".,;:!?'\"".contains(last) {
        url.removeLast()
      } else if let open = brackets[last] {
        if !counted {
          for character in url
          where brackets[character] != nil
            || brackets.values.contains(character)
          { counts[character, default: 0] += 1 }
          counted = true
        }
        guard counts[open, default: 0] < counts[last, default: 0] else { break }
        counts[last, default: 0] -= 1
        url.removeLast()
      } else {
        break
      }
    }
    return String(url)
  }
}
