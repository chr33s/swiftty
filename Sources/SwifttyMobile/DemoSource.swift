import Foundation
import SwifttyCore

/// A local stand-in for a remote host: an in-process line-editing "shell"
/// connected through the session's external transport. Input arrives from
/// `onWrite`; output goes back through `receive`.
///
/// The reference app ships this instead of a network client (spec §12):
/// connecting to real hosts is the embedding app's concern.
public final class DemoSource: @unchecked Sendable {
    public let session: TerminalSession
    /// Touched only from `onWrite`, which runs on the session queue.
    private var shell = DemoShell()

    public init(session: TerminalSession) {
        self.session = session
    }

    /// Attaches to the session and prints the banner and first prompt.
    public func start() {
        session.onWrite = { [weak self] bytes in
            guard let self else { return }
            let output = shell.input(bytes)
            if !output.isEmpty {
                session.receive(output)
            }
        }
        session.receive(DemoShell.banner + DemoShell.prompt)
    }

    public func stop() {
        session.onWrite = nil
    }
}

/// The demo's line editor and commands, as a pure byte transformer.
///
/// It behaves enough like a shell to exercise the frontend: OSC 133
/// prompt marks (so prompt jumps, command-output selection and
/// click-to-move work), cursor movement within the line, and commands
/// that print colors, Unicode and links.
public struct DemoShell: Sendable {
    static let promptText = "\u{1B}[1;32mdemo\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m$ "
    /// Prompt start mark, the prompt, and the command-line mark.
    public static let prompt = Array("\u{1B}]133;A\u{7}\(promptText)\u{1B}]133;B\u{7}".utf8)
    public static let banner = Array("""
    \u{1B}[1mswiftty\u{1B}[0m demo: a local echo shell, no real host.\r
    Type \u{1B}[1mhelp\u{1B}[0m for commands.\r\n\r\n
    """.utf8)

    /// The line being edited.
    public private(set) var line: [Unicode.Scalar] = []
    /// Cursor position in `line`.
    public private(set) var cursor = 0
    private var escape = EscapeState.none
    private var parameters: [UInt8] = []
    /// Bytes of an incomplete UTF-8 sequence.
    private var pending: [UInt8] = []

    private enum EscapeState { case none, escape, csi, ss3 }

    public init() {}

    public var lineText: String {
        String(String.UnicodeScalarView(line))
    }

    /// Consumes bytes from the terminal (typed keys, replies, pastes) and
    /// returns what the "host" prints back.
    public mutating func input(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for byte in bytes {
            switch escape {
            case .escape:
                escape = byte == 0x5B ? .csi : byte == 0x4F ? .ss3 : .none
                parameters.removeAll()
                continue
            case .csi:
                // Parameters and intermediates until a final byte. Covers
                // arrows, bracketed-paste markers, focus and kitty keys.
                if (0x40 ... 0x7E).contains(byte) {
                    escape = .none
                    out += editKey(final: byte, parameters: String(decoding: parameters, as: UTF8.self))
                } else {
                    parameters.append(byte)
                }
                continue
            case .ss3:
                escape = .none
                out += editKey(final: byte, parameters: "")
                continue
            case .none:
                break
            }
            switch byte {
            case 0x1B:
                escape = .escape
            case 0x0D, 0x0A:
                let command = lineText
                line.removeAll()
                cursor = 0
                out += Array("\r\n\u{1B}]133;C\u{7}".utf8)
                let (output, status) = run(command)
                out += output
                if !command.trimmingCharacters(in: .whitespaces).isEmpty || status != 0 {
                    out += Array("\u{1B}]133;D;\(status)\u{7}".utf8)
                }
                out += Self.prompt
            case 0x7F, 0x08:
                out += backspace()
            case 0x01: // Ctrl-A
                out += move(to: 0)
            case 0x05: // Ctrl-E
                out += move(to: line.count)
            case 0x03: // Ctrl-C
                line.removeAll()
                cursor = 0
                out += Array("^C\r\n".utf8) + Self.prompt
            case 0x15: // Ctrl-U: delete before the cursor
                let removed = cursor
                out += move(to: 0)
                line.removeFirst(removed)
                out += redrawTail()
            case 0x0C: // Ctrl-L
                let typed = line
                out += Array("\u{1B}[H\u{1B}[2J".utf8) + Self.prompt + Array(lineText.utf8)
                line = typed
                out += Self.left(width(line[cursor...]))
            case 0x20 ..< 0x80:
                out += insert(Unicode.Scalar(byte))
            case 0x80...:
                pending.append(byte)
                var decoder = UTF8()
                var iterator = pending.makeIterator()
                if case let .scalarValue(scalar) = decoder.decode(&iterator) {
                    pending.removeAll()
                    out += insert(scalar)
                } else if pending.count >= 4 || pending.first.map({ $0 & 0xC0 == 0x80 }) == true {
                    pending.removeAll() // invalid: drop it
                }
            default:
                break // other control characters
            }
        }
        return out
    }

    // MARK: Editing

    private func width(_ scalars: some Sequence<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + max(0, UnicodeWidth.width($1.value)) }
    }

    private static func left(_ n: Int) -> [UInt8] {
        n > 0 ? Array("\u{1B}[\(n)D".utf8) : []
    }

    private static func right(_ n: Int) -> [UInt8] {
        n > 0 ? Array("\u{1B}[\(n)C".utf8) : []
    }

    /// Clears from the cursor, reprints the rest of the line and returns
    /// to the cursor.
    private func redrawTail() -> [UInt8] {
        let tail = line[cursor...]
        return Array("\u{1B}[K".utf8) + Array(String(String.UnicodeScalarView(tail)).utf8) + Self.left(width(tail))
    }

    private mutating func insert(_ scalar: Unicode.Scalar) -> [UInt8] {
        line.insert(scalar, at: cursor)
        cursor += 1
        let tail = line[cursor...]
        return Array(String(scalar).utf8) + Array(String(String.UnicodeScalarView(tail)).utf8) + Self.left(width(tail))
    }

    private mutating func backspace() -> [UInt8] {
        guard cursor > 0 else { return [0x07] } // bell
        let w = width([line[cursor - 1]])
        cursor -= 1
        line.remove(at: cursor)
        return Self.left(max(1, w)) + redrawTail()
    }

    private mutating func move(to target: Int) -> [UInt8] {
        let target = min(max(target, 0), line.count)
        defer { cursor = target }
        return target < cursor ? Self.left(width(line[target ..< cursor])) : Self.right(width(line[cursor ..< target]))
    }

    /// Arrows, Home, End and Delete.
    private mutating func editKey(final: UInt8, parameters: String) -> [UInt8] {
        switch final {
        case UInt8(ascii: "D"): return move(to: cursor - 1)
        case UInt8(ascii: "C"): return move(to: cursor + 1)
        case UInt8(ascii: "H"): return move(to: 0)
        case UInt8(ascii: "F"): return move(to: line.count)
        case UInt8(ascii: "~") where parameters == "3":
            if cursor < line.count {
                line.remove(at: cursor)
                return redrawTail()
            }
            return [0x07]
        default: return []
        }
    }

    // MARK: Commands

    private func run(_ text: String) -> (output: [UInt8], status: Int) {
        let words = text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard let command = words.first else { return ([], 0) }
        let rest = words.count > 1 ? String(words[1]) : ""
        let output: String = switch command {
        case "help":
            """
            Commands:\r
              help      this list\r
              echo ...  print the arguments\r
              colors    SGR colour table, underline styles, blink\r
              unicode   wide characters, emoji and box drawing\r
              links     an OSC 8 hyperlink and a plain URL\r
              clear     clear the screen (also Ctrl-L)\r

            """
        case "echo": rest + "\r\n"
        case "clear": "\u{1B}[H\u{1B}[2J"
        case "colors": Self.colorTable()
        case "links":
            """
            OSC 8: \u{1B}]8;;https://ghostty.org\u{1B}\\Ghostty\u{1B}]8;;\u{1B}\\ \
            \u{1B}]8;;https://www.swift.org\u{1B}\\Swift\u{1B}]8;;\u{1B}\\\r
            URL:   https://github.com/ghostty-org/ghostty\r

            """
        case "unicode":
            """
            CJK: 漢字かなカナ 한글  emoji: 🙂 👍🏽 👩‍💻 🇿🇦\r
            ┌──┬──┐ ╭──╮ ▁▂▃▄▅▆▇█ ⣿⡇ \u{E0B0}\r
            └──┴──┘ ╰──╯ ░▒▓ ←↑→↓\r

            """
        default: "\(command): command not found\r\n"
        }
        let known: Set<Substring> = ["help", "echo", "clear", "colors", "links", "unicode"]
        return (Array(output.utf8), known.contains(command) ? 0 : 127)
    }

    static func colorTable() -> String {
        var s = ""
        for base in [0, 8] {
            for n in base ..< base + 8 {
                s += "\u{1B}[48;5;\(n)m \(String(format: "%3d", n)) "
            }
            s += "\u{1B}[0m\r\n"
        }
        // The 6×6×6 cube, one green level per row pair.
        for g in 0 ..< 6 {
            for r in 0 ..< 6 {
                for b in 0 ..< 6 {
                    s += "\u{1B}[48;5;\(16 + r * 36 + g * 6 + b)m "
                }
            }
            s += "\u{1B}[0m\r\n"
        }
        for n in 232 ..< 256 {
            s += "\u{1B}[48;5;\(n)m "
        }
        s += "\u{1B}[0m\r\n"
        for i in 0 ..< 36 {
            let v = i * 255 / 35
            s += "\u{1B}[48;2;\(v);\(255 - v);128m "
        }
        s += "\u{1B}[0m\r\n"
        s += "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m "
        s += "\u{1B}[9mstrike\u{1B}[0m \u{1B}[7minverse\u{1B}[0m \u{1B}[2mfaint\u{1B}[0m\r\n"
        s += "\u{1B}[4:3mcurly\u{1B}[0m \u{1B}[4:3;58;2;255;85;85mred curly\u{1B}[0m \u{1B}[4:4mdotted\u{1B}[0m "
        s += "\u{1B}[4:5mdashed\u{1B}[0m \u{1B}[4:2;58;5;39mdouble\u{1B}[0m \u{1B}[5mblink\u{1B}[0m\r\n"
        return s
    }
}
