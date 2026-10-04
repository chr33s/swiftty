extension TerminalState {
    /// The primary screen and its history as UTF-8 text with SGR styling,
    /// oldest line first. Soft-wrapped rows are joined, so replaying the
    /// dump into a terminal of any width reflows it. Empty when blank.
    public func dumpPrimaryANSI() -> [UInt8] {
        isAlternateScreen ? dump(inactiveGrid, cursorRow: nil) : dump(grid, cursorRow: cursor.y)
    }

    private func dump(_ screen: borrowing Grid, cursorRow: Int?) -> [UInt8] {
        var lines: [(UnsafeBufferPointer<Cell>, Bool)] = []
        for i in 0 ..< screen.historyCount {
            lines.append(screen.historyLine(i))
        }
        var last = screen.rows - 1
        while last >= 0, screen.cells(row: last).allSatisfy(\.isBlank) {
            last -= 1
        }
        if let cursorRow {
            last = max(last, cursorRow)
        }
        if last >= 0 {
            for y in 0 ... last {
                lines.append((screen.cells(row: y), screen.isWrapped(y)))
            }
        }
        var out: [UInt8] = []
        var pen = CellAttributes.default
        for (index, (cells, wrapped)) in lines.enumerated() {
            var end = cells.count
            if !wrapped {
                while end > 0, cells[end - 1].isBlank {
                    end -= 1
                }
            }
            for x in 0 ..< end {
                let cell = cells[x]
                if cell.isSpacer {
                    continue
                }
                var attrs = cell.attributes
                attrs.flags.subtract(.structural)
                attrs.link = 0
                if attrs != pen {
                    Self.appendSGR(attrs, to: &out)
                    pen = attrs
                }
                let scalars = scalars(of: cell)
                if scalars.isEmpty {
                    out.append(0x20)
                } else {
                    for s in scalars {
                        out.append(contentsOf: String(s).utf8)
                    }
                }
            }
            if !wrapped, index < lines.count - 1 {
                if pen != .default {
                    out.append(contentsOf: "\u{1B}[0m".utf8)
                    pen = .default
                }
                out.append(contentsOf: "\r\n".utf8)
            }
        }
        if pen != .default {
            out.append(contentsOf: "\u{1B}[0m".utf8)
        }
        return out
    }

    static func appendSGR(_ a: CellAttributes, to out: inout [UInt8]) {
        var params = ["0"]
        let flags: [(CellFlags, String)] = [
            (.bold, "1"), (.faint, "2"), (.italic, "3"), (.underline, "4"), (.doubleUnderline, "21"),
            (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.strikethrough, "9"), (.overline, "53"),
        ]
        for (flag, code) in flags where a.flags.contains(flag) {
            params.append(code)
        }
        func color(_ c: TerminalColor, _ base: Int) {
            switch c.kind {
            case .default: break
            case let .palette(i) where i < 8: params.append("\(base + Int(i))")
            case let .palette(i) where i < 16: params.append("\(base + 60 + Int(i) - 8)")
            case let .palette(i): params.append("\(base + 8);5;\(i)")
            case let .rgb(v): params.append("\(base + 8);2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)")
            }
        }
        color(a.foreground, 30)
        color(a.background, 40)
        out.append(contentsOf: "\u{1B}[\(params.joined(separator: ";"))m".utf8)
    }
}
