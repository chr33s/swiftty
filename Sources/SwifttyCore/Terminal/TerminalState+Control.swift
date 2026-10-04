/// Host-facing control: DCS strings (tmux control mode, XTGETTCAP,
/// DECRQSS) and operations the embedding app performs on the state.
extension TerminalState {
    // MARK: DCS

    mutating func dcsHook(_ csi: borrowing CSISequence) {
        dcsBuffer.removeAll(keepingCapacity: true)
        switch (csi.marker, csi.intermediate, csi.final) {
        case (0, 0, 0x70) where csi.value(0) == 1000: // tmux -CC
            dcsKind = .tmux
            isControlMode = true
            events.append(.controlModeStarted)
        case (0, 0x2B, 0x71): dcsKind = .termcap // XTGETTCAP + q
        case (0, 0x24, 0x71): dcsKind = .statusString // DECRQSS $ q
        default: dcsKind = .ignored
        }
    }

    mutating func dcsPut(_ bytes: UnsafeBufferPointer<UInt8>) {
        switch dcsKind {
        case .tmux: controlModeData.append(contentsOf: bytes)
        case .termcap, .statusString:
            if dcsBuffer.count + bytes.count <= 4096 {
                dcsBuffer.append(contentsOf: bytes)
            }
        case .ignored: break
        }
    }

    mutating func dcsUnhook() {
        switch dcsKind {
        case .tmux:
            isControlMode = false
            events.append(.controlModeEnded)
        case .termcap: replyTermcap()
        case .statusString: replyStatusString()
        case .ignored: break
        }
        dcsKind = .ignored
        dcsBuffer.removeAll(keepingCapacity: true)
    }

    /// XTGETTCAP: names are hex-encoded and `;`-separated.
    private mutating func replyTermcap() {
        for hexName in String(decoding: dcsBuffer, as: UTF8.self).split(separator: ";") {
            let name = Self.unhex(hexName)
            let value: String? = switch name {
            case "TN", "name": "xterm-256color"
            case "Co", "colors": "256"
            case "RGB": "8"
            case "Tc": ""
            case "Ms": #"\E]52;%p1%s;%p2%s\007"#
            case "Ss": #"\E[%p1%d q"#
            case "Se": #"\E[2 q"#
            case "Smulx": #"\E[4:%p1%dm"#
            case "setrgbf": #"\E[38:2:%p1%d:%p2%d:%p3%dm"#
            case "setrgbb": #"\E[48:2:%p1%d:%p2%d:%p3%dm"#
            default: nil
            }
            if let value {
                let encoded = value.isEmpty ? "" : "=" + Self.hex(value)
                reply("\u{1B}P1+r\(hexName)\(encoded)\u{1B}\\")
            } else {
                reply("\u{1B}P0+r\(hexName)\u{1B}\\")
            }
        }
    }

    /// DECRQSS for the settings applications query in practice.
    private mutating func replyStatusString() {
        let request = String(decoding: dcsBuffer, as: UTF8.self)
        let value: String? = switch request {
        case "m": sgrReport() + "m"
        case "r": "\(scrollTop + 1);\(scrollBottom + 1)r"
        case "s": modes.contains(.leftRightMargin) ? "\(scrollLeft + 1);\(scrollRight + 1)s" : nil
        case " q":
            "\((cursorStyle == .block ? 1 : cursorStyle == .underline ? 3 : 5) + (modes.contains(.cursorBlink) ? 0 : 1)) q"
        default: nil
        }
        if let value {
            reply("\u{1B}P1$r\(value)\u{1B}\\")
        } else {
            reply("\u{1B}P0$r\u{1B}\\")
        }
    }

    /// The pen as SGR parameters (Ghostty `printAttributes`).
    func sgrReport() -> String {
        let pen = cursor.pen
        var out = "0"
        let f = pen.flags
        if f.contains(.bold) { out += ";1" }
        if f.contains(.faint) { out += ";2" }
        if f.contains(.italic) { out += ";3" }
        if f.contains(.doubleUnderline) {
            out += ";4:2"
        } else if f.contains(.underline) {
            switch (f.contains(.underlineStyleA), f.contains(.underlineStyleB)) {
            case (true, false): out += ";4:3"
            case (false, true): out += ";4:4"
            case (true, true): out += ";4:5"
            case (false, false): out += ";4"
            }
        }
        if f.contains(.overline) { out += ";53" }
        if f.contains(.blink) { out += ";5" }
        if f.contains(.inverse) { out += ";7" }
        if f.contains(.invisible) { out += ";8" }
        if f.contains(.strikethrough) { out += ";9" }
        func color(_ c: TerminalColor, _ base: Int, _ bright: Int, _ extended: Int) -> String {
            switch c.kind {
            case .default: return ""
            case let .palette(i) where i >= 16: return ";\(extended):5:\(i)"
            case let .palette(i) where i >= 8: return ";\(bright + Int(i) - 8)"
            case let .palette(i): return ";\(base + Int(i))"
            case let .rgb(v): return ";\(extended):2::\(v >> 16 & 0xFF):\(v >> 8 & 0xFF):\(v & 0xFF)"
            }
        }
        out += color(pen.foreground, 30, 90, 38)
        out += color(pen.background, 40, 100, 48)
        return out
    }

    static func hex(_ s: String) -> String {
        s.utf8.map { b in
            let h = String(b, radix: 16, uppercase: true)
            return h.count == 1 ? "0" + h : h
        }.joined()
    }

    static func unhex(_ s: Substring) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), let b = UInt8(s[i ..< j], radix: 16) {
            bytes.append(b)
            i = j
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Host operations

    /// Replaces the default palette (a theme change); colours the
    /// application set with OSC 4/10/11 are discarded.
    public mutating func setDefaultPalette(_ newValue: Palette) {
        defaultPalette = newValue
        palette = newValue
        damage.setFull()
    }

    /// Clears the screen and scrollback, keeping the cursor's line (e.g. a
    /// shell prompt) as the new top line.
    public mutating func clearScreenKeepingCursorLine() {
        invalidateSelection()
        forgetHyperlinkRows()
        if !isAlternateScreen, cursor.y > 0 {
            let keep = cursor.y
            grid.scrollUp(top: 0, bottom: rows - 1, count: keep, fill: .blank)
            cursor.y = 0
        }
        if !isAlternateScreen {
            for y in 1 ..< rows {
                grid.fill(row: y, from: 0, to: columns, with: .blank)
                grid.setWrapped(y, false)
            }
            grid.clearHistory()
        }
        viewportOffset = 0
        damage.setFull()
    }

    /// RIS, as if the application had sent `ESC c`.
    public mutating func reset() {
        fullReset()
    }
}
