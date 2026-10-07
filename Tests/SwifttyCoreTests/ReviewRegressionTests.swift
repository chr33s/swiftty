import Foundation
@testable import SwifttyCore
import Synchronization
import Testing

struct ReviewRegressionTests {
    @Test func `cursor changes schedule updates`() {
        let session = TerminalSession(columns: 10, rows: 6)
        let updates = Mutex(0)
        session.onUpdate = { updates.withLock { $0 += 1 } }
        _ = session.snapshot()
        for sequence in ["\u{1B}[5;6H", "\u{1B}[?25l", "\u{1B}[6 q", "\u{1B}[?12h"] {
            let before = updates.withLock { $0 }
            session.feed(Array(sequence.utf8))
            #expect(updates.withLock { $0 } == before + 1)
            #expect(session.snapshot().damage.isEmpty)
        }
        let before = updates.withLock { $0 }
        session.feed(Array("\u{1B}[5;6H".utf8))
        #expect(updates.withLock { $0 } == before)
        session.feed(Array("\u{1B}[?2026h\u{1B}[1;1H".utf8))
        #expect(updates.withLock { $0 } == before)
        #expect(session.snapshot().cursor.x == 5)
        session.feed(Array("\u{1B}[?2026l".utf8))
        #expect(updates.withLock { $0 } == before + 1)
        #expect(session.snapshot().cursor.x == 0)
    }

    @Test func `keyboard stacks follow screens`() {
        var vt = VT(10, 2)
        vt.feed("\u{1B}[>1u\u{1B}[?1049h")
        #expect(vt.state.keyboardFlags == 0)
        vt.feed("\u{1B}[>8u\u{1B}[?1049l")
        #expect(vt.state.keyboardFlags == 1)
        vt.feed("\u{1B}[?1049h")
        #expect(vt.state.keyboardFlags == 8)
        vt.feed("\u{1B}[<u")
        #expect(vt.state.keyboardFlags == 0)
        vt.feed("\u{1B}c\u{1B}[?1049h")
        #expect(vt.state.keyboardFlags == 0)
    }

    @Test func `super keys use kitty encoding`() {
        for (action, flags, expected) in [
            (KeyEvent.Action.press, UInt8(1), "\u{1B}[97;9u"),
            (.release, 3, "\u{1B}[97;9:3u"),
        ] {
            var bytes: [UInt8] = []
            #expect(InputEncoder.encode(
                .key(KeyEvent(.character("a"), modifiers: .command, action: action)),
                modes: .initial,
                keyboardFlags: flags,
                into: &bytes,
            ))
            #expect(String(decoding: bytes, as: UTF8.self) == expected)
        }
    }

    @Test func `empty booleans restore defaults`() {
        var config = Configuration
            .parse("copy-on-select = true\nmouse-hide-while-typing = true\nlink-url = false\ncursor-click-to-move = false")
        config.apply("copy-on-select =\nmouse-hide-while-typing =\nlink-url =\ncursor-click-to-move =")
        let defaults = Configuration()
        #expect(config.copyOnSelect == defaults.copyOnSelect)
        #expect(config.mouseHideWhileTyping == defaults.mouseHideWhileTyping)
        #expect(config.linkURL == defaults.linkURL)
        #expect(config.cursorClickToMove == defaults.cursorClickToMove)
    }

    @Test func `tilde includes resolve from files`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let include = dir.appendingPathComponent("shared")
        try "font-size = 19".write(to: include, atomically: true, encoding: .utf8)
        let parents = String(repeating: "/..", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1)
        let path = "~" + parents + include.path
        for prefix in ["", "?"] {
            let url = dir.appendingPathComponent("config")
            try "config-file = \(prefix)\(path)".write(to: url, atomically: true, encoding: .utf8)
            let config = Configuration.load(from: url)
            #expect(config.diagnostics.isEmpty)
            #expect(config.fontSize == 19)
        }
    }

    @Test func `dumps preserve underlines`() {
        var vt = VT(20, 2)
        vt.feed("\u{1B}[4:3;58:2::255:0:0mA\u{1B}[4:4;58;5;123mB\u{1B}[4:5;59mC\u{1B}[4:2mD\u{1B}[4mE\u{1B}[0mF")
        var copy = VT(20, 2)
        copy.feed(bytes: vt.state.dumpPrimaryANSI())
        for x in 0 ..< 6 {
            let original = vt.state.grid[x, 0].attributes
            let restored = copy.state.grid[x, 0].attributes
            #expect(original.flags == restored.flags)
            #expect(vt.state.underlineColor(original.underlineColor) == copy.state.underlineColor(restored.underlineColor))
        }
    }
}
