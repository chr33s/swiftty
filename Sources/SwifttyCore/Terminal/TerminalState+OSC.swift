import Foundation

/// Operating system commands: titles, working directory, colours,
/// clipboard, notifications.
extension TerminalState {
    // MARK: OSC

    mutating func oscDispatch(_ data: UnsafeBufferPointer<UInt8>, terminatedByBell: Bool) {
        joinNext = false
        var command = 0
        var i = 0
        while i < data.count, data[i] != 0x3B {
            guard (0x30 ... 0x39).contains(data[i]) else { return }
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
        default: break // 1, 8, 133, ... are ignored
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
}
