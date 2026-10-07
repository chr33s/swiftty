import Foundation
@testable import SwifttyCore
import Testing

/// OSC 7501 framing and validation.
struct ProgramStatusParserTests {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    func vt() -> VT {
        var vt = VT(20, 3)
        vt.state.programStatusEnabled = true
        return vt
    }

    func osc(_ body: String, bell: Bool = false) -> String {
        "\u{1B}]7501;\(body)" + (bell ? "\u{07}" : "\u{1B}\\")
    }

    /// The single record after feeding `body`, or nil if none was stored.
    func record(_ body: String) -> ProgramStatusRecord? {
        var vt = vt()
        vt.feed(osc(body))
        return vt.state.programStatus.records.first
    }

    func parse(_ body: String) -> ProgramStatusCommand? {
        Array(body.utf8).withUnsafeBufferPointer { ProgramStatusCommand($0) }
    }

    @Test func `minimal report addresses the root`() {
        let r = record("state=working")
        #expect(r == ProgramStatusRecord(id: "", state: .working, revision: 1))
    }

    @Test func `every state`() {
        let states: [(String, ProgramStatusState)] = [
            ("idle", .idle),
            ("working", .working),
            ("done", .done),
            ("blocked", .blocked),
            ("error", .error),
        ]
        for (name, state) in states {
            #expect(record("state=\(name)")?.state == state)
        }
        #expect(parse("state=clear") == .clear(id: nil))
        #expect(parse("state=clear:id=a/b") == .clear(id: "a/b"))
    }

    @Test func `every kind`() {
        #expect(record("state=blocked:kind=permission")?.kind == .permission)
        #expect(record("state=blocked:kind=question")?.kind == .question)
        #expect(record("state=blocked:kind=auth")?.kind == .auth)
        // Unknown kinds are absent; the report still applies.
        let unknown = record("state=blocked:kind=coffee")
        #expect(unknown?.state == .blocked && unknown?.kind == nil)
        // Kind is read only for blocked.
        #expect(record("state=working:kind=question")?.kind == nil)
    }

    @Test func `all fields`() {
        let r =
            record(
                "state=blocked:id=agent/tool:kind=question:progress=40:app=claude:title=\(b64("Approve?")):msg=\(b64("Run rm -rf build?"))",
            )
        #expect(r == ProgramStatusRecord(
            id: "agent/tool", state: .blocked, kind: .question, progress: 40, app: "claude",
            title: "Approve?", message: "Run rm -rf build?", revision: 1,
        ))
    }

    @Test func `BEL and ST terminators`() {
        var vt = vt()
        vt.feed(osc("state=working:id=a", bell: true))
        vt.feed(osc("state=done:id=b", bell: false))
        #expect(vt.state.programStatus.records.map(\.id) == ["a", "b"])
    }

    @Test func `split writes at every boundary`() {
        let full = Array(osc("state=working:id=build:title=\(b64("héllo"))").utf8)
        for cut in 1 ..< full.count {
            var vt = vt()
            vt.feed(bytes: Array(full[..<cut]))
            // Nothing until terminated; like every OSC, ESC alone ends it.
            if cut < full.count - 1 {
                #expect(vt.state.programStatus.records.isEmpty)
            }
            vt.feed(bytes: Array(full[cut...]))
            #expect(vt.state.programStatus.records.first?.title == "héllo")
        }
    }

    @Test func `multiple sequences per write`() {
        var vt = vt()
        vt.feed("x" + osc("state=working:id=a") + "y" + osc("state=error:id=b", bell: true) + osc("state=clear:id=a"))
        #expect(vt.state.programStatus.records.map(\.id) == ["b"])
        #expect(vt.lines[0].hasPrefix("xy"))
    }

    @Test func `repeated keys take the last value`() {
        let r = record("state=done:state=working:progress=10:progress=20:app=a:app=b")
        #expect(r?.state == .working && r?.progress == 20 && r?.app == "b")
        #expect(record("state=working:id=a:id=b")?.id == "b")
        // An invalid id anywhere discards the report.
        #expect(record("state=working:id=a//b:id=b") == nil)
    }

    @Test func `unknown keys and malformed pairs are ignored`() {
        let r = record("future=1:junk::=x:state=working:noequals")
        #expect(r?.state == .working)
        // Keys outside `[a-z]+` and values outside the value set are skipped.
        let skipped = record("state=working:State=done:st4te=done:state=do ne:app=x;y:kind=a*b")
        #expect(skipped?.state == .working && skipped?.app == nil)
        // A text value outside the set is absent; the report applies.
        let text = record("state=done:title=YW I:msg=YW*I")
        #expect(text?.state == .done && text?.title == nil && text?.message == nil)
        // A semicolon inside the body makes its pair malformed.
        #expect(parse("state=working;x") == nil)
    }

    @Test func `missing or unknown state discards`() {
        #expect(parse("id=a") == nil)
        #expect(parse("state=Working") == nil) // case-sensitive
        #expect(parse("state=") == nil)
        #expect(parse("") == nil)
    }

    @Test func `ids`() {
        #expect(record("state=idle:id=a")?.id == "a")
        #expect(record("state=idle:id=a.b_c-D9/x")?.id == "a.b_c-D9/x")
        #expect(record("state=idle:id=c++/build")?.id == "c++/build")
        for bad in ["", "/", "a/", "/a", "a//b", "a b", "é", "a\\b", "a=b"] {
            #expect(parse("state=idle:id=\(bad)") == nil, "\(bad)")
            #expect(parse("state=clear:id=\(bad)") == nil, "clear \(bad)")
        }
    }

    @Test func `id depth and length limits`() {
        let eight = (1 ... 8).map { "s\($0)" }.joined(separator: "/")
        #expect(parse("state=idle:id=\(eight)") != nil)
        #expect(parse("state=idle:id=\(eight)/s9") == nil)
        let segment = String(repeating: "a", count: 32)
        #expect(parse("state=idle:id=\(segment)") != nil)
        #expect(parse("state=idle:id=\(segment)a") == nil)
        // 4 × 32 + 3 slashes = 131 > 128.
        let long = Array(repeating: segment, count: 4).joined(separator: "/")
        #expect(parse("state=idle:id=\(long)") == nil)
        let max = Array(repeating: String(repeating: "a", count: 31), count: 3).joined(separator: "/") + "/" + segment // 128
        #expect(max.utf8.count == 128)
        #expect(parse("state=idle:id=\(max)") != nil)
    }

    @Test func `field limits`() {
        let key = String(repeating: "k", count: 16)
        #expect(parse("state=idle:\(key)=1") != nil)
        #expect(parse("state=idle:\(key)k=1") == nil)
        let app = String(repeating: "a", count: 32)
        #expect(parse("state=idle:app=\(app)") != nil)
        #expect(parse("state=idle:app=\(app)a") == nil)
        // Outside `[A-Za-z0-9_.+-]`: absent, the report still applies.
        for bad in ["a b", "a\u{7F}", "a!", "é", "a/b"] {
            let r = record("state=idle:app=\(bad)")
            #expect(r?.state == .idle && r?.app == nil, "\(bad)")
        }
        #expect(record("state=idle:app=g++_1.2-x")?.app == "g++_1.2-x")
        #expect(record("state=idle:app=a:app=a/b")?.app == nil) // last value wins, absent
        #expect(record("state=idle:app=a:app=a b")?.app == "a") // malformed pair skipped

        #expect(parse("state=idle:title=\(b64(String(repeating: "t", count: 192)))") != nil)
        #expect(parse("state=idle:title=\(b64(String(repeating: "t", count: 193)))") == nil)
        #expect(parse("state=idle:msg=\(b64(String(repeating: "m", count: 2048)))") != nil)
        #expect(parse("state=idle:msg=\(b64(String(repeating: "m", count: 2049)))") == nil)
        // Encoded limit applies before decoding.
        #expect(parse("state=idle:title=\(String(repeating: "QUJD", count: 64))A") == nil)
    }

    /// The limit covers the whole sequence, `ESC ]` through the terminator.
    @Test(arguments: [false, true]) func `sequence limit plus and minus one byte`(bell: Bool) {
        func sequence(bytes: Int) -> String {
            let empty = osc("state=working:pad=", bell: bell)
            return osc("state=working:pad=" + String(repeating: "x", count: bytes - empty.utf8.count), bell: bell)
        }
        var vt = vt()
        #expect(sequence(bytes: 4096).utf8.count == 4096)
        vt.feed(sequence(bytes: 4096))
        #expect(vt.state.programStatus.records.count == 1)
        vt.feed(osc("state=clear"))
        vt.feed(sequence(bytes: 4097))
        #expect(vt.state.programStatus.records.isEmpty)
        // The parser recovers for the next sequence.
        vt.feed(osc("state=done"))
        #expect(vt.state.programStatus.records.first?.state == .done)
    }

    @Test func `support query reply repeats the query`() {
        var vt = vt()
        vt.feed("\u{1B}]7501;?\u{07}")
        #expect(vt.takeOutput() == "\u{1B}]7501;?\u{07}")
        vt.feed("\u{1B}]7501;?\u{1B}\\")
        #expect(vt.takeOutput() == "\u{1B}]7501;?\u{1B}\\")
    }

    @Test func `terminfo Pst capability advertised only while enabled`() {
        let query = "\u{1B}P+q\(TerminalState.hex("Pst"))\u{1B}\\"
        var vt = vt()
        vt.feed(query)
        #expect(vt.takeOutput() == "\u{1B}P1+r\(TerminalState.hex("Pst"))=\(TerminalState.hex("\\E]7501;%p1%s\\E\\\\"))\u{1B}\\")
        vt.state.programStatusEnabled = false
        vt.feed(query)
        #expect(vt.takeOutput() == "\u{1B}P0+r\(TerminalState.hex("Pst"))\u{1B}\\")
    }

    @Test func `oversized report is dropped, not truncated`() {
        // Truncation at 4096 would leave a valid prefix ending in `id=a`.
        var vt = vt()
        let body = "state=working:id=a" + String(repeating: "a", count: 5000)
        vt.feed(osc(body))
        #expect(vt.state.programStatus.records.isEmpty)
    }

    @Test func `progress edge cases`() {
        #expect(record("state=working:progress=0")?.progress == 0)
        #expect(record("state=working:progress=100")?.progress == 100)
        #expect(record("state=blocked:progress=7")?.progress == 7)
        for bad in ["101", "-1", "+5", "1.5", "", "abc", "0100", "999999999999"] {
            let r = record("state=working:progress=\(bad)")
            #expect(r?.state == .working && r?.progress == nil, "\(bad)")
        }
        // Only working and blocked carry progress.
        #expect(record("state=done:progress=50")?.progress == nil)
        #expect(record("state=idle:progress=50")?.progress == nil)
    }

    @Test func `padded and unpadded base64`() {
        // "ab" → YWI= ; "a" → YQ==
        #expect(record("state=idle:title=YWI=")?.title == "ab")
        #expect(record("state=idle:title=YWI")?.title == "ab")
        #expect(record("state=idle:title=YQ==")?.title == "a")
        #expect(record("state=idle:title=YQ")?.title == "a")
        #expect(record("state=idle:title=")?.title == nil) // empty is absent
    }

    @Test func `invalid base64 discards`() {
        for bad in ["Y", "YQ=", "Y===", "=YWI", "YQ==YQ==", "YW,I", "YW-I"] {
            #expect(parse("state=idle:title=\(bad)") == nil, "\(bad)")
        }
        // Nonzero leftover bits are tolerated, as by standard decoders.
        #expect(record("state=idle:title=YR==")?.title == "a")
    }

    @Test func `invalid UTF-8 discards`() {
        let bad = Data([0x61, 0xFF, 0x62]).base64EncodedString()
        #expect(parse("state=idle:msg=\(bad)") == nil)
        let surrogate = Data([0xED, 0xA0, 0x80]).base64EncodedString()
        #expect(parse("state=idle:msg=\(surrogate)") == nil)
    }

    @Test func `control characters discard`() {
        for text in ["a\u{1B}[31mb", "line\nbreak", "tab\there", "del\u{7F}", "c1\u{9B}x", "nul\u{0}"] {
            #expect(parse("state=idle:title=\(b64(text))") == nil, "\(text.debugDescription)")
        }
    }

    @Test func `unicode text`() {
        let r = record("state=done:title=\(b64("✅ Build 完了")):msg=\(b64("👩‍💻 <b>not markup</b>"))")
        #expect(r?.title == "✅ Build 完了")
        #expect(r?.message == "👩‍💻 <b>not markup</b>")
    }

    @Test func `disabled terminal ignores reports`() {
        var vt = VT(20, 3)
        vt.feed(osc("state=working"))
        #expect(vt.state.programStatus.records.isEmpty)
        #expect(vt.state.takeProgramStatusChange() == nil)
    }
}
