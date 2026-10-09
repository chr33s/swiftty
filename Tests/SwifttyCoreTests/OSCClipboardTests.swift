@testable import SwifttyCore
import Testing
import TestSupport

struct OSCClipboardTests {
    @Test(arguments: ["aGVs\tbG8=", "aGVs\nbG8=", "Y\0Q==", "YQ===", "===="].map(TestFixture.init), ["52", "00052"].map(TestFixture.init))
    func `invalid clipboard continuation stays rejected`(_ payload: TestFixture<String>, _ command: TestFixture<String>) {
        let payload = payload.value
        let command = command.value
        let bytes = Array(("\u{1B}]\(command);c;" + payload + "\u{1B}\\").utf8)
        for split in 0 ..< bytes.count {
            var source = VT(8, 3), target = VT(8, 3)
            source.feed(bytes: Array(bytes[..<split]))
            #expect(source.state.takeEvents().isEmpty)
            target.feed("\u{1B}]52;c;YQ")
            target.parser.restore(source.parser.continuation)
            target.feed(bytes: Array(bytes[split...]))
            #expect(target.state.takeEvents().isEmpty)
            target.feed("\u{1B}]52;c;b2s=\u{07}")
            #expect(TestFixture(target.state.takeEvents()) == TestFixture([.clipboard("ok")]))
        }
    }

    @Test func `window titles continue to ignore C0 controls`() {
        var vt = VT(8, 3)
        vt.feed("\u{1B}]0;a\tb\nc\u{07}")
        #expect(vt.state.takeEvents() == [.title("abc")])
    }

    @Test(arguments: [
        ("", ""), ("aGVsbG8=", "hello"), ("YQBi", "a\0b"),
        ("dW5wYWRkZWQ", "unpadded"), ("YQ", "a"), ("YWI", "ab"),
    ].map(TestFixture.init), ["\u{07}", "\u{1B}\\"].map(TestFixture.init))
    func `clipboard writes accept complete and unpadded payloads`(
        _ fixture: TestFixture<(String, String)>,
        _ terminator: TestFixture<String>,
    ) {
        let fixture = fixture.value
        let terminator = terminator.value
        var vt = VT(8, 3)
        vt.feed("\u{1B}]52;c;" + fixture.0 + terminator)
        #expect(TestFixture(vt.state.takeEvents()) == TestFixture([.clipboard(fixture.1)]))
    }

    @Test(arguments: [
        "?", "***", "SGVs!!!bG8=", "aGVs bG8=", "aGVs\tbG8=", "aGVs\nbG8=",
        "YQ=", "YQ===", "YQ====", "====", "YQ==Yg==", "A", "AAA==", "YQ== ", "YQ-_",
    ].map(TestFixture.init), ["\u{07}", "\u{1B}\\"].map(TestFixture.init))
    func `invalid clipboard payloads are discarded entirely`(_ payload: TestFixture<String>, _ terminator: TestFixture<String>) {
        let payload = payload.value
        let terminator = terminator.value
        var vt = VT(8, 3)
        vt.feed("\u{1B}]52;c;" + payload + terminator)
        #expect(vt.state.takeEvents().isEmpty)
        vt.feed("\u{1B}]52;c;b2s=" + terminator + "X")
        #expect(TestFixture(vt.state.takeEvents()) == TestFixture([.clipboard("ok")]))
        #expect(TestFixture(vt.lines) == TestFixture(["X", "", ""]))
    }

    @Test(
        arguments: [("", ""), ("YQBi", "a\0b"), ("YQ", "a"), ("aGVsbG8=", "hello")].map(TestFixture.init),
        ["\u{07}", "\u{1B}\\"].map(TestFixture.init),
    )
    func `fragmented clipboard writes emit one event at the OSC boundary`(
        _ fixture: TestFixture<(String, String)>,
        _ terminator: TestFixture<String>,
    ) {
        let fixture = fixture.value
        let terminator = terminator.value
        let bytes = Array(("\u{1B}]52;c;" + fixture.0 + terminator).utf8)
        // VT parsing exits OSC on ESC, before the backslash of ST arrives.
        let boundary = bytes.count - terminator.utf8.count
        for split in 0 ..< bytes.count {
            var vt = VT(8, 3)
            vt.feed(bytes: Array(bytes[..<split]))
            var events = vt.state.takeEvents()
            #expect(TestFixture(events) == TestFixture(split > boundary ? [.clipboard(fixture.1)] : []))
            for index in split ..< bytes.count {
                vt.feed(bytes: [bytes[index]])
                events += vt.state.takeEvents()
                #expect(TestFixture(events) == TestFixture(index >= boundary ? [.clipboard(fixture.1)] : []))
            }
            #expect(TestFixture(events) == TestFixture([.clipboard(fixture.1)]))
            vt.feed("X")
            #expect(vt.state.takeEvents().isEmpty)
            #expect(TestFixture(vt.lines) == TestFixture(["X", "", ""]))
        }
    }
}
