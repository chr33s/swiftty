@testable import SwifttyCore
import Testing

struct InputEncoderTests {
    func encode(_ input: TerminalInput, _ modes: Modes = .initial) -> String? {
        var out: [UInt8] = []
        guard InputEncoder.encode(input, modes: modes, into: &out) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    @Test func `text and control keys`() {
        #expect(encode(.text("héllo")) == "héllo")
        #expect(encode(.key(KeyEvent(.character("c"), modifiers: .control))) == "\u{03}")
        #expect(encode(.key(KeyEvent(.character("["), modifiers: .control))) == "\u{1B}")
        #expect(encode(.key(KeyEvent(.character(" "), modifiers: .control))) == "\u{00}")
        #expect(encode(.key(KeyEvent(.character("x"), modifiers: .alt))) == "\u{1B}x")
        #expect(encode(.key(KeyEvent(.enter))) == "\r")
        #expect(encode(.key(KeyEvent(.backspace))) == "\u{7F}")
        #expect(encode(.key(KeyEvent(.tab, modifiers: .shift))) == "\u{1B}[Z")
    }

    @Test func `cursor keys respect DECCKM`() {
        #expect(encode(.key(KeyEvent(.up))) == "\u{1B}[A")
        #expect(encode(.key(KeyEvent(.up)), [.cursorKeys]) == "\u{1B}OA")
        #expect(encode(.key(KeyEvent(.left, modifiers: [.control, .shift]))) == "\u{1B}[1;6D")
        #expect(encode(.key(KeyEvent(.home)), [.cursorKeys]) == "\u{1B}OH")
    }

    @Test func `function and editing keys`() {
        #expect(encode(.key(KeyEvent(.function(1)))) == "\u{1B}OP")
        #expect(encode(.key(KeyEvent(.function(5)))) == "\u{1B}[15~")
        #expect(encode(.key(KeyEvent(.function(12), modifiers: .shift))) == "\u{1B}[24;2~")
        #expect(encode(.key(KeyEvent(.delete))) == "\u{1B}[3~")
        #expect(encode(.key(KeyEvent(.pageUp, modifiers: .alt))) == "\u{1B}[5;3~")
    }

    @Test func paste() {
        #expect(encode(.paste("a\nb")) == "a\rb")
        #expect(encode(.paste("a\u{1B}b"), [.bracketedPaste]) == "\u{1B}[200~ab\u{1B}[201~")
    }

    @Test func mouse() {
        #expect(encode(.mouse(MouseEvent(.press, .left, column: 0, row: 0))) == nil)
        #expect(encode(.mouse(MouseEvent(.press, .left, column: 4, row: 2)), [.mouseNormal, .mouseSGR]) == "\u{1B}[<0;5;3M")
        #expect(encode(.mouse(MouseEvent(.release, .left, column: 4, row: 2)), [.mouseNormal, .mouseSGR]) == "\u{1B}[<0;5;3m")
        #expect(encode(.mouse(MouseEvent(.press, .wheelUp, column: 0, row: 0, modifiers: .control)), [.mouseNormal, .mouseSGR]) ==
            "\u{1B}[<80;1;1M")
        #expect(encode(.mouse(MouseEvent(.motion, .none, column: 0, row: 0)), [.mouseNormal]) == nil)
        #expect(encode(.mouse(MouseEvent(.motion, .left, column: 1, row: 1)), [.mouseButton, .mouseSGR]) == "\u{1B}[<32;2;2M")
        let legacy = encode(.mouse(MouseEvent(.press, .right, column: 1, row: 2)), [.mouseNormal])
        #expect(legacy == "\u{1B}[M\u{22}\u{22}\u{23}")
    }

    @Test func focus() {
        #expect(encode(.focus(true)) == nil)
        #expect(encode(.focus(false), [.focusEvents]) == "\u{1B}[O")
    }
}

struct KittyKeyboardTests {
    @Test func `push query and disambiguate`() {
        var vt = VT()
        vt.feed("\(CSI)?u")
        #expect(vt.takeOutput() == "\(CSI)?0u")
        vt.feed("\(CSI)>1u\(CSI)?u")
        #expect(vt.takeOutput() == "\(CSI)?1u")
        let flags = vt.state.keyboardFlags
        func enc(_ e: KeyEvent) -> String {
            var out: [UInt8] = []
            InputEncoder.encode(.key(e), modes: .initial, keyboardFlags: flags, into: &out)
            return String(decoding: out, as: UTF8.self)
        }
        #expect(enc(KeyEvent(.enter, modifiers: .shift)) == "\(CSI)13;2u")
        #expect(enc(KeyEvent(.enter)) == "\r")
        #expect(enc(KeyEvent(.escape)) == "\(CSI)27u")
        #expect(enc(KeyEvent(.character("c"), modifiers: .control)) == "\(CSI)99;5u")
        #expect(enc(KeyEvent(.up)) == "\(CSI)A")
        vt.feed("\(CSI)<u\(CSI)?u")
        #expect(vt.takeOutput() == "\(CSI)?0u")
    }
}

struct KittyKeyboardLevelsTests {
    func enc(_ e: KeyEvent, _ flags: UInt8) -> String {
        var out: [UInt8] = []
        InputEncoder.encode(.key(e), modes: .initial, keyboardFlags: flags, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    @Test func `event types`() {
        #expect(enc(KeyEvent(.character("a"), modifiers: .control, action: .repeat), 3) == "\(CSI)97;5:2u")
        #expect(enc(KeyEvent(.character("a"), modifiers: .control, action: .release), 3) == "\(CSI)97;5:3u")
        #expect(enc(KeyEvent(.character("a"), action: .release, text: "a"), 3) == "")
        #expect(enc(KeyEvent(.up, action: .release), 3) == "\(CSI)1;1:3A")
        #expect(enc(KeyEvent(.up, action: .release), 1) == "")
        #expect(enc(KeyEvent(.character("a"), action: .release), 0) == "")
    }

    @Test func `all keys and text`() {
        #expect(enc(KeyEvent(.character("a"), text: "a"), 8) == "\(CSI)97u")
        #expect(enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 8) == "\(CSI)97;2u")
        #expect(enc(KeyEvent(.enter), 8) == "\(CSI)13u")
        #expect(enc(KeyEvent(.character("a"), text: "a"), 24) == "\(CSI)97;1;97u")
        #expect(enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 24) == "\(CSI)97;2;65u")
        #expect(enc(KeyEvent(.character("a"), modifiers: .shift, text: "A"), 1) == "A")
        #expect(enc(KeyEvent(.function(5), modifiers: .alt), 1) == "\(CSI)15;3~")
    }
}

struct KittyFlagGatingTests {
    func enc(_ e: KeyEvent, _ flags: UInt8) -> String {
        var out: [UInt8] = []
        InputEncoder.encode(.key(e), modes: .initial, keyboardFlags: flags, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    @Test func repeatsCarryNoEventFieldWithoutFlag2() {
        #expect(enc(KeyEvent(.up, action: .repeat), 1) == "\(CSI)A")
        #expect(enc(KeyEvent(.character("a"), modifiers: .control, action: .repeat), 1) == "\(CSI)97;5u")
    }

    @Test func flagsWithoutDisambiguateStayLegacy() {
        #expect(enc(KeyEvent(.character("c"), modifiers: .control), 2) == "\u{03}")
        #expect(enc(KeyEvent(.escape), 16) == "\u{1B}")
        #expect(enc(KeyEvent(.escape, action: .release), 2) == "")
    }
}
