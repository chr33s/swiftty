import Dispatch
import SwifttyCore
import Synchronization
import Testing
import TestSupport

private final class CallbackLifetime: Sendable {
    let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit {
        onRelease()
    }
}

struct SessionCallbackTests {
    @Test(arguments: ["receive", "generated", "feed", "span"])
    func `program output observers see each transport chunk before parsing`(_ transport: String) {
        let session = TerminalSession(columns: 20, rows: 3)
        session.feed(Array("old".utf8))
        let chunks = [[UInt8(0xC3)], [UInt8(0xA9)], Array("\u{1B}[6n!".utf8)]
        let received = Mutex<[[UInt8]]>([])
        let before = Mutex<[String]>([])
        let replies = Mutex<[[UInt8]]>([])
        session.onProgramOutput = { [weak session] bytes in
            received.withLock { $0.append(bytes) }
            before.withLock { $0.append(session?.withState { $0.screenLines[0] } ?? "missing session") }
        }
        session.onTerminalReply = { bytes in
            #expect(received.withLock { $0 } == chunks)
            replies.withLock { $0.append(bytes) }
        }
        for chunk in [[]] + chunks + [[]] {
            switch transport {
            case "receive": session.receive(chunk)
            case "generated": session.receive { _ in chunk }
            case "feed": session.feed(chunk)
            default: session.feed(chunk.span)
            }
        }
        session.queue.sync {}
        #expect(received.withLock { $0 } == chunks)
        #expect(before.withLock { $0 } == ["old", "old", "oldé"])
        #expect(TestFixture(replies.withLock { $0 }) == TestFixture([Array("\u{1B}[1;5R".utf8)]))
        #expect(session.withState { $0.screenLines[0] } == "oldé!")
    }

    @Test(arguments: [
        ("\u{1B}P1000p%exit\n\u{1B}\\\u{7}", ["start", "data:%exit\n", "end", "bell"]),
        ("\u{1B}P1000p%exit\n\u{1B}\\\u{1B}]2;after\u{7}", ["start", "data:%exit\n", "end", "title:after"]),
        ("\u{1B}P1000pfirst\n\u{18}\u{7}", ["start", "data:first\n", "end", "bell"]),
        ("\u{1B}P1000pfirst\n\u{1B}\\\u{1B}P1000psecond\n\u{1B}\\", ["start", "data:first\n", "end", "start", "data:second\n", "end"]),
        ("\u{1B}P1000p\u{1B}\\\u{1B}P1000psecond\n\u{1B}\\\u{7}", ["start", "end", "start", "data:second\n", "end", "bell"]),
        ("\u{1B}P1000pfirst\n\u{1B}\\\u{1B}P1000psecond\n", ["start", "data:first\n", "end", "start", "data:second\n"]),
    ].map(TestFixture.init), [false, true])
    func `control mode callbacks preserve stream boundaries and following events`(
        _ fixture: TestFixture<(String, [String])>,
        _ split: Bool,
    ) {
        let fixture = fixture.value
        let session = TerminalSession(columns: 20, rows: 3)
        let trace = Mutex<[String]>([])
        session.onEvent = { event in
            let entry: String
            switch event {
            case .controlModeStarted: entry = "start"
            case .controlModeEnded: entry = "end"
            case .bell: entry = "bell"
            case let .title(title): entry = "title:" + title
            default:
                Issue.record(Comment(rawValue: escapedTestText("unexpected event: \(event)")))
                return
            }
            trace.withLock { $0.append(entry) }
        }
        session.onControlModeData = { bytes in
            trace.withLock { entries in
                let text = String(decoding: bytes, as: UTF8.self)
                if entries.last?.hasPrefix("data:") == true {
                    entries[entries.count - 1] += text
                } else {
                    entries.append("data:" + text)
                }
            }
        }
        if split {
            for byte in fixture.0.utf8 {
                session.feed([byte])
            }
        } else {
            session.feed(Array(fixture.0.utf8))
        }
        #expect(trace.withLock { $0 } == fixture.1)
    }

    @Test(arguments: ["modes", "keyboardFlags", "programStatus"])
    func `read only session properties can be queried from state callbacks`(_ property: String) {
        let session = TerminalSession(columns: 20, rows: 3)
        let received = Mutex(0)
        session.onStateChange = { [weak session] state in
            guard let session else { return }
            switch property {
            case "modes": #expect(session.modes == state.modes)
            case "keyboardFlags": #expect(session.keyboardFlags == state.keyboardFlags)
            default: #expect(session.programStatusSnapshot == state.programStatus.snapshot)
            }
            received.withLock { $0 += 1 }
        }
        session.feed(Array("\u{1B}[=10u\u{1B}[?25lx".utf8))
        #expect(received.withLock { $0 } == 1)
    }

    @Test func `queued output uses the state at parsing time and skips empty output`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let batches = Mutex(0)
        session.onStateChange = { _ in batches.withLock { $0 += 1 } }
        session.receive { _ in [] }
        session.queue.sync {}
        #expect(batches.withLock { $0 } == 0)
        session.resize(columns: 12, rows: 3)
        session.receive { [weak session] state in
            #expect(state.columns == 12)
            #expect(session?.withState { $0.columns } == state.columns)
            return Array("\(state.columns)".utf8)
        }
        let snapshot = session.snapshot()
        #expect(TestFixture(snapshot.text[0]) == TestFixture("12"))
        #expect(batches.withLock { $0 } == 2)
    }

    @Test func `callbacks can read state on their own session queue`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let received = Mutex(0)
        session.onStateChange = { [weak session] state in
            guard let session else { return }
            let columns = session.withState { $0.columns }
            #expect(columns == state.columns)
            received.withLock { $0 += 1 }
        }
        session.feed(Array("x".utf8))
        #expect(received.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func `new redraw handlers receive updates despite an undrawn prior batch`(_ hadHandler: Bool) {
        let session = TerminalSession(columns: 20, rows: 3)
        let previous = Mutex(0)
        let current = Mutex(0)
        if hadHandler {
            session.onUpdate = { previous.withLock { $0 += 1 } }
        }
        session.feed(Array("old".utf8))
        session.onUpdate = { current.withLock { $0 += 1 } }
        session.feed(Array("new".utf8))
        #expect(previous.withLock { $0 } == (hadHandler ? 1 : 0))
        #expect(current.withLock { $0 } == 1)
        session.feed(Array("more".utf8))
        #expect(current.withLock { $0 } == 1) // Coalesce for the current handler.
        _ = session.snapshot()
        session.feed(Array("x".utf8))
        #expect(current.withLock { $0 } == 2)
    }

    @Test func `releasing a replaced callback can change another handler`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let released = Mutex(false)
        session.onEvent = { _ in }
        func install() {
            let owner = CallbackLifetime { [weak session] in
                session?.onEvent = nil
                released.withLock { $0 = true }
            }
            session.onWrite = { [owner] _ in withExtendedLifetime(owner) {} }
        }
        install()
        session.onWrite = nil
        #expect(released.withLock { $0 })
        #expect(session.onEvent == nil)
    }

    @Test func `callbacks can be replaced while the session delivers input and output`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let count = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            session.onUpdate = { count.withLock { $0 += index } }
            session.onEvent = { _ in count.withLock { $0 += index } }
            session.onWrite = { _ in count.withLock { $0 += index } }
            session.onTerminalReply = { _ in count.withLock { $0 += index } }
            session.onProgramStatusChange = { _ in count.withLock { $0 += index } }
            session.onStateChange = { _ in count.withLock { $0 += index } }
            session.onProgramOutput = { _ in count.withLock { $0 += index } }
            session.onControlModeData = { _ in count.withLock { $0 += index } }
            _ = session.onUpdate
            _ = session.onEvent
            _ = session.onWrite
            _ = session.onTerminalReply
            _ = session.onProgramStatusChange
            _ = session.onStateChange
            _ = session.onProgramOutput
            _ = session.onControlModeData
            session.receive([0x07])
            session.send(.bytes([42]))
        }
        session.queue.sync {}
        let finalWrites = Mutex<[UInt8]>([])
        session.onWrite = { bytes in finalWrites.withLock { $0 += bytes } }
        session.send(.bytes([99]))
        session.queue.sync {}
        #expect(finalWrites.withLock { $0 } == [99])
        #expect(count.withLock { $0 } > 0)
    }

    @Test func `a callback can remove itself while running`() {
        let session = TerminalSession(columns: 20, rows: 3)
        let writes = Mutex<[UInt8]>([])
        session.onWrite = { [weak session] bytes in
            session?.onWrite = nil
            writes.withLock { $0 += bytes }
        }
        session.send(.bytes([1]))
        session.send(.bytes([2]))
        session.queue.sync {}
        #expect(writes.withLock { $0 } == [1])
    }
}
