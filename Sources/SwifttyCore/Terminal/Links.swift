import Foundation

/// A link under the pointer: an OSC 8 hyperlink, or a URL found in the text.
public struct TerminalLink: Sendable, Equatable {
    public var url: String
    /// Cells the link covers (inclusive), for underlining on hover.
    public var range: TerminalRange
    /// OSC 8 id when the link came from the application.
    public var id: UInt8
}

public extension TerminalState {
    /// The link at `p`: the cell's OSC 8 hyperlink, else (with
    /// `detectURLs`, Ghostty's `link-url`) a URL in the surrounding text,
    /// followed across soft wraps.
    func link(at p: TerminalPoint, detectURLs: Bool = true) -> TerminalLink? {
        guard let (cells, _) = line(absoluteRow: p.row), p.column >= 0, p.column < cells.count else { return nil }
        var column = p.column
        if cells[column].width == 0, column > 0 {
            column -= 1
        }
        let id = cells[column].attributes.link
        if id != 0, let url = hyperlink(id) {
            var lo = column, hi = column
            while lo > 0, cells[lo - 1].attributes.link == id {
                lo -= 1
            }
            while hi + 1 < cells.count, cells[hi + 1].attributes.link == id {
                hi += 1
            }
            return TerminalLink(
                url: url,
                range: TerminalRange(start: TerminalPoint(row: p.row, column: lo), end: TerminalPoint(row: p.row, column: hi)),
                id: id,
            )
        }
        guard detectURLs else { return nil }
        // The logical line around `p`, one scalar per position.
        var top = p.row
        while let (_, wrapped) = line(absoluteRow: top - 1), wrapped {
            top -= 1
        }
        var text = String.UnicodeScalarView()
        var points: [TerminalPoint] = []
        var row = top
        while let (rowCells, wrapped) = line(absoluteRow: row) {
            for x in 0 ..< rowCells.count where !rowCells[x].isSpacer {
                let scalars = self.scalars(of: rowCells[x])
                text.append(scalars.first ?? " ")
                points.append(TerminalPoint(row: row, column: x))
            }
            guard wrapped else { break }
            row += 1
        }
        let string = String(text)
        let ns = string as NSString
        for match in Self.urlPattern?.matches(in: string, range: NSRange(location: 0, length: ns.length)) ?? [] {
            var url = ns.substring(with: match.range)
            url = Self.trimURL(url)
            // Map UTF-16 offsets back to cell points.
            let startScalar = string.unicodeScalars.distance(
                from: string.unicodeScalars.startIndex,
                to: String.Index(utf16Offset: match.range.location, in: string),
            )
            let count = url.unicodeScalars.count
            guard count > 0, startScalar + count <= points.count else { continue }
            let start = points[startScalar], end = points[startScalar + count - 1]
            let range = TerminalRange(start: start, end: end)
            if (start.row, start.column) <= (p.row, column), (p.row, column) <= (end.row, end.column) {
                return TerminalLink(url: url, range: range, id: 0)
            }
        }
        return nil
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?:https?|ftp|file|ssh|git)://[^\s<>"'`]+|mailto:[^\s<>"'`]+"#,
    )

    /// Drops trailing punctuation that usually ends a sentence, keeping a
    /// closing bracket that has its opening one inside the URL.
    private static func trimURL(_ url: String) -> String {
        var url = Substring(url)
        while let last = url.last {
            if ".,;:!?'\"".contains(last) {
                url.removeLast()
            } else if let open = [")": "(", "]": "[", "}": "{"][String(last)],
                      url.filter({ String($0) == open }).count < url.filter({ $0 == last }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return String(url)
    }
}
