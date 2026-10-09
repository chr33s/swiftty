import Foundation
@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

struct StreamContinuationTests {
    @Test(arguments: [
        "é", "漢", "😀", "\u{1B}(0q", "\u{1B}[38:2::11:22:33;1mX", "\u{1B}[2;3Hxy", "\u{1B}[5 q",
        "\u{1B}]0;title\u{07}", "\u{1B}]52;c;YQ==\u{1B}\\",
        "\u{1B}]0;already\u{07}é", "\u{1B}]52;c;YQ==\u{07}漢", "\u{1B}[6n😀",
    ].map(TestFixture.init), [false, true])
    func `pending continuation matches uninterrupted parsing at every boundary`(_ input: TestFixture<String>, _ fragmented: Bool) {
        let input = input.value
        let bytes = Array(input.utf8)
        let tail = Array("\u{1B}[0mZ\u{1B}[6n".utf8)
        for split in 0 ... bytes.count {
            let source = TerminalSession(columns: 20, rows: 3)
            let target = TerminalSession(columns: 20, rows: 3)
            let reference = TerminalSession(columns: 20, rows: 3)
            let writes = Mutex<[[UInt8]]>([]), expectedWrites = Mutex<[[UInt8]]>([])
            let events = Mutex<[TerminalEvent]>([]), expectedEvents = Mutex<[TerminalEvent]>([])
            target.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
            reference.onWrite = { bytes in expectedWrites.withLock { $0.append(bytes) } }
            target.onEvent = { event in events.withLock { $0.append(event) } }
            reference.onEvent = { event in expectedEvents.withLock { $0.append(event) } }
            reference.feed(bytes + tail)
            let prefix = Array(bytes[..<split])
            target.feed(prefix) // The capture replay already contains completed effects.
            if fragmented {
                for byte in prefix {
                    source.feed([byte])
                }
            } else {
                source.feed(prefix)
            }
            target.continueStream(from: source)
            target.continueStream(from: source) // Restoring the same pending state is idempotent.
            target.feed(Array(bytes[split...]) + tail)
            let actual = target.snapshot(), expected = reference.snapshot()
            #expect(
                TestFixture(actual.text) == TestFixture(expected.text),
                Comment(rawValue: escapedTestText("input=\(input.debugDescription) split=\(split)")),
            )
            let cursor = target.withState { $0.cursor }, expectedCursor = reference.withState { $0.cursor }
            #expect(cursor == expectedCursor)
            #expect(target.withState { $0.cursorStyle } == reference.withState { $0.cursorStyle })
            let cells = target.withState { state in (0 ..< 3).flatMap { y in (0 ..< 20).map { state.grid[$0, y] } } }
            let expectedCells = reference.withState { state in (0 ..< 3).flatMap { y in (0 ..< 20).map { state.grid[$0, y] } } }
            #expect(cells == expectedCells)
            // Publishing may combine replies from one feed into one write.
            #expect(writes.withLock { $0.flatMap(\.self) } == expectedWrites.withLock { $0.flatMap(\.self) })
            #expect(events.withLock { $0 } == expectedEvents.withLock { $0 })
        }
    }

    @Test(arguments: [4093, 4094, 4095, 8191])
    func `OSC continuation grows a fresh destination buffer without replaying a title`(_ length: Int) {
        let source = TerminalSession(columns: 8, rows: 3)
        let target = TerminalSession(columns: 8, rows: 3)
        let title = String(repeating: "x", count: length)
        let events = Mutex<[TerminalEvent]>([])
        target.onEvent = { event in events.withLock { $0.append(event) } }
        source.feed(Array(("\u{1B}]0;" + title).utf8))
        target.continueStream(from: source)
        target.continueStream(from: source)
        _ = target.snapshot()
        #expect(events.withLock { $0.isEmpty })
        target.feed(Array("\u{07}Z".utf8))
        #expect(TestFixture(target.snapshot().text) == TestFixture(["Z", "", ""]))
        #expect(events.withLock { $0 } == [.title(title)])
    }

    @Test(arguments: [
        ("\u{1B}# ", "8Z"),
        ("\u{1B}[6  ", "qZ"),
        ("\u{1B}P$ ", "qm\u{1B}\\Z"),
    ].map(TestFixture.init))
    func `multiple intermediate continuation stays discarded`(_ sample: TestFixture<(String, String)>) {
        let sample = sample.value
        let source = TerminalSession(columns: 8, rows: 3)
        let target = TerminalSession(columns: 8, rows: 3)
        let replies = Mutex<[[UInt8]]>([])
        target.onWrite = { bytes in replies.withLock { $0.append(bytes) } }
        source.feed(Array(sample.0.utf8))
        target.continueStream(from: source)
        target.feed(Array(sample.1.utf8))
        #expect(replies.withLock { $0.isEmpty })
        #expect(TestFixture(target.snapshot().text) == TestFixture(["Z", "", ""]))
        #expect(target.withState { $0.cursorStyle == .block })
    }

    @Test(arguments: [
        ("\u{1B}[" + String(repeating: "1;", count: 25), "31mZ"),
        ("\u{1B}P1000;" + String(repeating: "0;", count: 24), "+q544E\u{1B}\\Z"),
    ].map(TestFixture.init))
    func `parameter overflow continuation stays discarded`(_ sample: TestFixture<(String, String)>) {
        let sample = sample.value
        let source = TerminalSession(columns: 8, rows: 3)
        let target = TerminalSession(columns: 8, rows: 3)
        let replies = Mutex<[[UInt8]]>([])
        target.onWrite = { bytes in replies.withLock { $0.append(bytes) } }
        source.feed(Array(sample.0.utf8))
        target.continueStream(from: source)
        target.feed(Array(sample.1.utf8))
        #expect(replies.withLock { $0.isEmpty })
        #expect(TestFixture(target.snapshot().text) == TestFixture(["Z", "", ""]))
        #expect(target.withState { $0.cursor.pen == CellAttributes() })
        target.feed(Array("\u{1B}[31mY".utf8))
        #expect(target.withState { $0.cursor.pen.foreground == .palette(1) })
    }

    @Test func `oversized DCS continuation stays discarded`() {
        let source = TerminalSession(columns: 20, rows: 3)
        let target = TerminalSession(columns: 20, rows: 3)
        let replies = Mutex<[[UInt8]]>([])
        target.onWrite = { bytes in replies.withLock { $0.append(bytes) } }
        source.feed(Array("\u{1B}P$qm".utf8) + [UInt8](repeating: 0x78, count: 4096) + [0x1B])
        target.feed(Array("\u{1B}P$qm".utf8))
        target.continueStream(from: source)
        target.feed(Array("\\ok".utf8))
        #expect(replies.withLock { $0.isEmpty })
        #expect(TestFixture(target.snapshot().text) == TestFixture(["ok", "", ""]))
    }

    @Test(arguments: [
        ("\u{1B}P$qm\u{1B}\\", "\u{1B}P1$r0m\u{1B}\\"),
        ("\u{1B}P+q544E\u{1B}\\", "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\"),
        ("\u{1B}P$q\u{7F}m\u{7F}\u{1B}\\", "\u{1B}P1$r0m\u{1B}\\"),
        ("\u{1B}P+q54\u{7F}4E\u{1B}\\", "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\"),
    ].map(TestFixture.init))
    func `DCS continuation preserves the request at every byte boundary`(_ sample: TestFixture<(String, String)>) {
        let sample = sample.value
        let bytes = Array(sample.0.utf8)
        for split in 0 ..< bytes.count {
            let source = TerminalSession(columns: 20, rows: 3)
            let target = TerminalSession(columns: 20, rows: 3)
            let replies = Mutex<[[UInt8]]>([])
            target.onWrite = { bytes in replies.withLock { $0.append(bytes) } }
            target.feed(Array("\u{1B}P$qr".utf8)) // An unrelated pending request must be replaced.
            source.feed(Array(bytes[..<split]))
            target.continueStream(from: source)
            target.feed(Array(bytes[split...]))
            #expect(replies.withLock { $0 } == [Array(sample.1.utf8)])
            target.feed(Array("ok".utf8))
            #expect(TestFixture(target.snapshot().text) == TestFixture(["ok", "", ""]))
        }
    }

    @Test func `control mode continuation announces ownership and streams only new bytes`() {
        let source = TerminalSession(columns: 20, rows: 3)
        let target = TerminalSession(columns: 20, rows: 3)
        let data = Mutex<[[UInt8]]>([]), events = Mutex<[TerminalEvent]>([])
        target.onControlModeData = { bytes in data.withLock { $0.append(bytes) } }
        target.onEvent = { event in events.withLock { $0.append(event) } }
        source.feed(Array("\u{1B}P1000p%begin\n".utf8))
        target.continueStream(from: source)
        #expect(target.withState { $0.isControlMode })
        target.feed(Array("%exit\n\u{1B}\\ok".utf8))
        #expect(TestFixture(data.withLock { $0 }) == TestFixture([Array("%exit\n".utf8)]))
        #expect(events.withLock { $0 } == [.controlModeStarted, .controlModeEnded])
        #expect(!target.withState { $0.isControlMode })
        #expect(TestFixture(target.snapshot().text) == TestFixture(["ok", "", ""]))
    }

    @Test func `ground continuation ends the destination control mode`() {
        let source = TerminalSession(columns: 20, rows: 3)
        let target = TerminalSession(columns: 20, rows: 3)
        let events = Mutex<[TerminalEvent]>([])
        target.onEvent = { event in events.withLock { $0.append(event) } }
        target.feed(Array("\u{1B}P1000p%begin\n".utf8))
        target.continueStream(from: source)
        target.feed(Array("ok".utf8))
        #expect(!target.withState { $0.isControlMode })
        #expect(events.withLock { $0 } == [.controlModeStarted, .controlModeEnded])
        #expect(TestFixture(target.snapshot().text) == TestFixture(["ok", "", ""]))
    }
}
