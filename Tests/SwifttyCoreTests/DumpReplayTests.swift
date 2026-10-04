@testable import SwifttyCore
import Testing

struct DumpReplayTests {
    @Test func `replay ends on fresh line`() {
        var vt = VT(49, 10)
        vt.feed("total 8\n" + String(repeating: "x", count: 30) + " .shellrc\n")
        let dump = vt.state.dumpPrimaryANSI()
        var copy = VT(37, 10)
        copy.feed(bytes: dump)
        copy.feed("bold")
        #expect(copy.lines.prefix(4) == ["total 8", "       xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", " .shellrc", "bold"])
    }
}
