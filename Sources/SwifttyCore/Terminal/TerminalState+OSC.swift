import Foundation

/// Operating system commands: titles, working directory, colours,
/// clipboard, notifications.
extension TerminalState {
    // MARK: OSC

    mutating func oscDispatch(_ data: UnsafeBufferPointer<UInt8>, terminatedByBell: Bool) {
        var command = 0
        var i = 0
        while i < data.count, data[i] != 0x3B {
            // No OSC number has more than a few digits; a longer one would overflow.
            guard (0x30 ... 0x39).contains(data[i]), i < 9 else { return }
            command = command * 10 + Int(data[i] - 0x30)
            i += 1
        }
        let rest = i < data.count ? UnsafeBufferPointer(rebasing: data[(i + 1)...]) : UnsafeBufferPointer(rebasing: data[data.count...])
        let st = terminatedByBell ? "\u{07}" : "\u{1B}\\"
        switch command {
        case 0, 2:
            if Self.replace(&titleBytes, with: rest) {
                titleChanged = true
            }
        case 4:
            let parts = String(decoding: rest, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            var k = 0
            while k + 1 < parts.count {
                if let index = Int(parts[k]), (0 ..< 256).contains(index) {
                    if parts[k + 1] == "?" {
                        reply("\u{1B}]4;\(index);\(Self.formatColor(palette.colors[index]))\(st)")
                    } else if let rgb = Self.parseColor(parts[k + 1]) {
                        palette.colors[index] = rgb
                        damage.setFull()
                    }
                }
                k += 2
            }
        case 7:
            if Self.replace(&directoryBytes, with: rest) {
                directoryChanged = true
            }
        case 9:
            let text = String(decoding: rest, as: UTF8.self)
            if text.hasPrefix("4;") {
                let parts = text.split(separator: ";", omittingEmptySubsequences: false)
                let state = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let percent = parts.count > 2 ? Int(parts[2]).map { min(max($0, 0), 100) } : nil
                events.append(.progress(state: state, percent: percent))
            } else if !text.isEmpty {
                events.append(.notification(title: "", body: text))
            }
        case 777:
            let parts = String(decoding: rest, as: UTF8.self).split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify" {
                events.append(.notification(
                    title: parts.count > 1 ? String(parts[1]) : "",
                    body: parts.count > 2 ? String(parts[2]) : "",
                ))
            }
        case 8: hyperlink(rest)
        case 21: kittyColors(rest, terminator: st)
        case 22: setPointerShape(rest)
        case 133: semanticPrompt(rest)
        case 10, 11, 12:
            let spec = String(decoding: rest, as: UTF8.self)
            if spec == "?" {
                let rgb = command == 10 ? palette.foreground : command == 11 ? palette.background : palette.cursor
                reply("\u{1B}]\(command);\(Self.formatColor(rgb))\(st)")
            } else if let rgb = Self.parseColor(Substring(spec)) {
                switch command {
                case 10: palette.foreground = rgb
                case 11: palette.background = rgb
                default: palette.cursor = rgb
                }
                damage.setFull()
            }
        case 52:
            let s = String(decoding: rest, as: UTF8.self)
            guard let semi = s.firstIndex(of: ";") else { return }
            let payload = s[s.index(after: semi)...]
            // Clipboard reads ("?") are refused: they would leak data to the app.
            if payload != "?", let decoded = Data(base64Encoded: String(payload)) {
                events.append(.clipboard(String(decoding: decoded, as: UTF8.self)))
            }
        case 104:
            if rest.isEmpty {
                palette.colors = defaultPalette.colors
            } else {
                for part in String(decoding: rest, as: UTF8.self).split(separator: ";") {
                    if let index = Int(part), (0 ..< 256).contains(index) {
                        palette.colors[index] = defaultPalette.colors[index]
                    }
                }
            }
            damage.setFull()
        case 110: palette.foreground = defaultPalette.foreground; damage.setFull()
        case 111: palette.background = defaultPalette.background; damage.setFull()
        case 112: palette.cursor = defaultPalette.cursor
        default: break // 1 (icon title) and others are ignored
        }
    }

    static func formatColor(_ rgb: UInt32) -> String {
        func c(_ v: UInt32) -> String {
            let s = String(v & 0xFF, radix: 16)
            let byte = s.count == 1 ? "0" + s : s
            return byte + byte
        }
        return "rgb:\(c(rgb >> 16))/\(c(rgb >> 8))/\(c(rgb))"
    }

    /// Parses `rgb:R/G/B` (1–4 hex digits each) or `#RRGGBB`.
    static func parseColor(_ spec: Substring) -> UInt32? {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            return v
        }
        guard spec.hasPrefix("rgb:") else { return nil }
        let parts = spec.dropFirst(4).split(separator: "/")
        guard parts.count == 3 else { return nil }
        var rgb: UInt32 = 0
        for part in parts {
            guard (1 ... 4).contains(part.count), let v = UInt32(part, radix: 16) else { return nil }
            let maxValue = (UInt32(1) << (4 * UInt32(part.count))) - 1
            rgb = rgb << 8 | (v * 255 + maxValue / 2) / maxValue
        }
        return rgb
    }

    /// OSC 8 `params;URI`: an empty URI ends the link. URIs are interned
    /// by hash into a 255-slot ring whose storage is reused, so steady-state
    /// link output does not allocate.
    private mutating func hyperlink(_ rest: UnsafeBufferPointer<UInt8>) {
        guard let semi = rest.firstIndex(of: 0x3B) else { return }
        let uri = UnsafeBufferPointer(rebasing: rest[(semi + 1)...])
        guard !uri.isEmpty, uri.count <= 2048 else {
            setLink(0)
            return
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a
        for b in uri {
            hash = (hash ^ UInt64(b)) &* 0x100_0000_01B3
        }
        if let id = hyperlinkIndex[hash], hyperlinks[Int(id) - 1].elementsEqual(uri) {
            setLink(id)
            return
        }
        let slot: Int
        if hyperlinks.count < 255 {
            hyperlinks.append(Array(uri))
            hyperlinkHashes.append(hash)
            hyperlinkLastRow.append(.max)
            slot = hyperlinks.count - 1
        } else {
            // Reuse only an id no cell still carries; otherwise the link
            // goes unlabelled rather than retargeting older cells.
            guard let free = reclaimHyperlinkSlot() else {
                setLink(0)
                return
            }
            slot = free
            if hyperlinkIndex[hyperlinkHashes[slot]] == UInt8(slot + 1) {
                hyperlinkIndex[hyperlinkHashes[slot]] = nil
            }
            hyperlinks[slot].removeAll(keepingCapacity: true)
            hyperlinks[slot].append(contentsOf: uri)
            hyperlinkHashes[slot] = hash
        }
        hyperlinkIndex[hash] = UInt8(slot + 1)
        hyperlinkLastRow[slot] = .max
        setLink(UInt8(slot + 1))
    }

    /// Absolute rows were renumbered (history cleared, reflow): recorded
    /// rows no longer apply, so only a scan can free a slot.
    mutating func forgetHyperlinkRows() {
        for i in hyperlinkLastRow.indices {
            hyperlinkLastRow[i] = .max
        }
    }

    /// Switches the pen's link.
    private mutating func setLink(_ id: UInt8) {
        penLinkWillChange(to: id)
        cursor.pen.link = id
    }

    /// Bookkeeping for any change of the pen's link (OSC 8, DECRC): the
    /// ending link can only have been written down to the current screen
    /// bottom; the starting one is live again.
    mutating func penLinkWillChange(to id: UInt8) {
        let old = Int(cursor.pen.link)
        guard old != Int(id) else { return }
        // A saved cursor still holding the link may write with it again.
        let held = savedPrimary.pen.link == UInt8(clamping: old) || savedAlternate.pen.link == UInt8(clamping: old)
        if old != 0, old <= hyperlinkLastRow.count {
            hyperlinkLastRow[old - 1] = isAlternateScreen || held
                ? .max : absoluteRow(viewportRow: 0) + viewportOffset + rows - 1
        }
        holdHyperlink(id)
    }

    /// Marks `id` live: no row bound applies and no free list holds it.
    mutating func holdHyperlink(_ id: UInt8) {
        guard id != 0, Int(id) <= hyperlinkLastRow.count else { return }
        hyperlinkLastRow[Int(id) - 1] = .max
        freeHyperlinkSlots.removeAll { $0 == Int(id) - 1 }
    }

    /// A slot whose id appears in no cell. Cheap path: its last possible row
    /// has left history. Otherwise a scan of every cell (screens and
    /// history), rate-limited while it keeps finding nothing.
    private mutating func reclaimHyperlinkSlot() -> Int? {
        let first = firstAbsoluteRow
        let saved = (Int(savedPrimary.pen.link) - 1, Int(savedAlternate.pen.link) - 1)
        if !isAlternateScreen, let slot = hyperlinkLastRow.indices.first(where: {
            hyperlinkLastRow[$0] < first && $0 + 1 != Int(cursor.pen.link) && $0 != saved.0 && $0 != saved.1
        }) {
            return slot
        }
        if let slot = freeHyperlinkSlots.popLast() {
            return slot
        }
        // With every slot's last row known and still in history, all ids are
        // genuinely live: a scan cannot help.
        let current = Int(cursor.pen.link) - 1
        guard hyperlinkLastRow.indices.contains(where: { $0 != current && hyperlinkLastRow[$0] == .max }) else {
            return nil
        }
        if hyperlinkScanCooldown > 0 {
            hyperlinkScanCooldown -= 1
            return nil
        }
        var used = InlineArray<256, Bool>(repeating: false)
        used[Int(cursor.pen.link)] = true
        used[Int(savedPrimary.pen.link)] = true
        used[Int(savedAlternate.pen.link)] = true
        let linkOffset = MemoryLayout<Cell>.offset(of: \Cell.attributes.link)!
        func mark(_ cells: UnsafeBufferPointer<Cell>, _ count: Int, _ used: inout InlineArray<256, Bool>) {
            guard let base = UnsafeRawPointer(cells.baseAddress) else { return }
            for x in 0 ..< min(count, cells.count) {
                used[Int(base.load(fromByteOffset: x &* 16 &+ linkOffset, as: UInt8.self))] = true
            }
        }
        for y in 0 ..< rows {
            mark(grid.cells(row: y), grid.extent(y), &used)
            mark(inactiveGrid.cells(row: y), inactiveGrid.extent(y), &used)
        }
        for i in 0 ..< grid.historyCount {
            let line = grid.historyLine(i).cells
            mark(line, line.count, &used)
        }
        for i in 0 ..< inactiveGrid.historyCount {
            let line = inactiveGrid.historyLine(i).cells
            mark(line, line.count, &used)
        }
        freeHyperlinkSlots = (0 ..< hyperlinks.count).filter { !used[$0 + 1] }.reversed()
        if freeHyperlinkSlots.isEmpty {
            hyperlinkScanCooldown = 255
            return nil
        }
        return freeHyperlinkSlots.popLast()
    }

    /// Target of hyperlink `id` (from `CellAttributes.link`).
    public func hyperlink(_ id: UInt8) -> String? {
        id > 0 && Int(id) <= hyperlinks.count ? String(decoding: hyperlinks[Int(id) - 1], as: UTF8.self) : nil
    }
}
