import CoreGraphics
import SwifttyCore
@testable import SwifttyMobile
import Testing

/// Encodes inputs the way the session would, with default modes.
private func encoded(_ inputs: [TerminalInput], keyboardFlags: UInt8 = 0) -> [UInt8] {
    var out: [UInt8] = []
    for input in inputs {
        InputEncoder.encode(input, modes: .initial, keyboardFlags: keyboardFlags, into: &out)
    }
    return out
}

private func bytes(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

typealias Usage = KeyTranslator.Usage

struct KeyTranslatorTests {
    @Test func `kitty hardware text`() throws {
        #expect(KeyTranslator.keyEvent(
            usage: 4, modifiers: [], charactersIgnoringModifiers: "a", characters: "a", keyboardFlags: 8,
        ) == nil)
        var input = HardwareTextInput()
        try input.begin(usage: 4, event: #require(KeyTranslator.identity(usage: 4, modifiers: [], base: "a", characters: "a")))
        let committed = input.commit("a", keyboardFlags: 8)
        let event = try #require(committed).event
        var bytes: [UInt8] = []
        #expect(InputEncoder.encode(.key(event), modes: .initial, keyboardFlags: 8, into: &bytes))
        #expect(String(decoding: bytes, as: UTF8.self) == "\u{1B}[97u")
        var released = event
        released.action = .release
        bytes.removeAll()
        #expect(InputEncoder.encode(.key(released), modes: .initial, keyboardFlags: 10, into: &bytes))
        #expect(String(decoding: bytes, as: UTF8.self) == "\u{1B}[97;1:3u")
        #expect(KeyTranslator.keyEvent(
            usage: 4,
            modifiers: .alt,
            charactersIgnoringModifiers: "a",
            characters: "",
            keyboardFlags: 8,
        ) == nil)
    }

    @Test func `kitty text can start composition`() throws {
        for flags: UInt8 in [1, 2, 4, 8, 16, 31] {
            for mods: KeyModifiers in [[], .shift, .alt] {
                #expect(KeyTranslator.keyEvent(
                    usage: 4,
                    modifiers: mods,
                    charactersIgnoringModifiers: "a",
                    characters: "a",
                    keyboardFlags: flags,
                ) == nil)
            }
            var input = HardwareTextInput()
            let event = try #require(KeyTranslator.identity(usage: 4, modifiers: [], base: "a", characters: "a"))
            input.begin(usage: 4, event: event)
            // The initial forwarded key starts marked text before committing.
            input.cancel()
            #expect(input.commit("あ", keyboardFlags: flags) == nil)
            // Even a composition that commits the original character stays text.
            input.begin(usage: 4, event: event)
            input.cancel()
            #expect(input.commit("a", keyboardFlags: flags) == nil)
        }
    }

    @Test func `hardware commits repeat and expire`() throws {
        var input = HardwareTextInput()
        let event = try #require(KeyTranslator.identity(usage: 4, modifiers: [], base: "a", characters: "a"))
        input.begin(usage: 4, event: event)
        let first = input.commit("a", keyboardFlags: 10)
        #expect(try #require(first).event.action == .press)
        let next = input.commit("a", keyboardFlags: 10)
        let repeated = try #require(next).event
        #expect(encoded([.key(repeated)], keyboardFlags: 10) == bytes("\u{1B}[97;1:2u"))
        input.cancel(usage: 5)
        #expect(input.commit("a", keyboardFlags: 8) != nil)
        input.cancel(usage: 4)
        #expect(input.commit("a", keyboardFlags: 8) == nil)
        input.begin(usage: 4, event: event)
        #expect(input.commit("dictated text", keyboardFlags: 8) == nil)
        #expect(input.commit("a", keyboardFlags: 8) == nil)
        input.begin(usage: 4, event: event)
        #expect(input.commit("a", keyboardFlags: 0) == nil)
    }

    @Test func `refinement flags preserve committed option text`() throws {
        let event = try #require(KeyTranslator.identity(usage: 4, modifiers: .alt, base: "a", characters: "å"))
        for flags: UInt8 in [0, 2, 4, 16, 6, 18, 20, 22] {
            var input = HardwareTextInput()
            input.begin(usage: 4, event: event)
            let committed = input.commit("å", keyboardFlags: flags)
            #expect(committed == nil)
            let inputs = committed.map { [TerminalInput.key($0.event)] } ?? KeyTranslator.inputs(forText: "å", modifiers: [])
            #expect(encoded(inputs, keyboardFlags: flags) == bytes("å"))
            #expect(KeyTranslator.keyEvent(
                usage: 4,
                modifiers: .command,
                charactersIgnoringModifiers: "a",
                characters: "a",
                keyboardFlags: flags,
            ) == nil)
            let control = try #require(KeyTranslator.keyEvent(
                usage: 4,
                modifiers: [.control, .shift],
                charactersIgnoringModifiers: "A",
                keyboardFlags: flags,
            ))
            #expect(control.modifiers == .control)
        }
        for flags: UInt8 in [1, 8, 9, 5, 31] {
            var input = HardwareTextInput()
            input.begin(usage: 4, event: event)
            #expect(input.commit("å", keyboardFlags: flags) != nil)
        }
    }

    @Test func `special keys`() throws {
        let cases: [(Int, Key)] = [
            (Usage.returnOrEnter, .enter), (Usage.keypadEnter, .enter), (Usage.tab, .tab),
            (Usage.backspace, .backspace), (Usage.escape, .escape), (Usage.up, .up), (Usage.down, .down),
            (Usage.left, .left), (Usage.right, .right), (Usage.home, .home), (Usage.end, .end),
            (Usage.pageUp, .pageUp), (Usage.pageDown, .pageDown), (Usage.deleteForward, .delete),
            (Usage.insert, .insert), (Usage.f1, .function(1)), (Usage.f1 + 11, .function(12)),
        ]
        for (usage, key) in cases {
            #expect(KeyTranslator.keyEvent(usage: usage, modifiers: [], charactersIgnoringModifiers: "") == KeyEvent(key))
        }
        let shiftTab = KeyTranslator.keyEvent(usage: Usage.tab, modifiers: .shift, charactersIgnoringModifiers: "\t")
        #expect(try encoded([.key(#require(shiftTab))]) == bytes("\u{1B}[Z"))
        let ctrlUp = KeyTranslator.keyEvent(usage: Usage.up, modifiers: .control, charactersIgnoringModifiers: "")
        #expect(try encoded([.key(#require(ctrlUp))]) == bytes("\u{1B}[1;5A"))
    }

    @Test func `text goes to the text system`() {
        // "a" is HID usage 4.
        #expect(KeyTranslator.keyEvent(usage: 4, modifiers: [], charactersIgnoringModifiers: "a") == nil)
        #expect(KeyTranslator.keyEvent(usage: 4, modifiers: .shift, charactersIgnoringModifiers: "a") == nil)
        #expect(KeyTranslator.keyEvent(usage: 4, modifiers: .alt, charactersIgnoringModifiers: "a") == nil)
        // Command shortcuts belong to the app, even on special keys.
        #expect(KeyTranslator.keyEvent(usage: 0x19, modifiers: .command, charactersIgnoringModifiers: "v") == nil)
        #expect(KeyTranslator.keyEvent(usage: Usage.up, modifiers: .command, charactersIgnoringModifiers: "") == nil)
    }

    @Test func `control combinations`() throws {
        let ctrlC = KeyTranslator.keyEvent(usage: 6, modifiers: .control, charactersIgnoringModifiers: "c")
        #expect(ctrlC == KeyEvent(.character("c"), modifiers: .control, baseLayoutKey: "c"))
        #expect(try encoded([.key(#require(ctrlC))]) == [0x03])
        // Shift is dropped and the letter folded: Ctrl-Shift-C is Ctrl-C.
        let shifted = KeyTranslator.keyEvent(usage: 6, modifiers: [.control, .shift], charactersIgnoringModifiers: "C")
        #expect(shifted == KeyEvent(.character("c"), modifiers: .control, baseLayoutKey: "c"))
        let space = KeyTranslator.keyEvent(usage: 0x2C, modifiers: .control, charactersIgnoringModifiers: " ")
        #expect(try encoded([.key(#require(space))]) == [0x00])
        let bracket = KeyTranslator.keyEvent(usage: 0x2F, modifiers: .control, charactersIgnoringModifiers: "[")
        #expect(try encoded([.key(#require(bracket))]) == [0x1B])
    }

    @Test func releases() throws {
        let release = KeyTranslator.releaseEvent(usage: 4, modifiers: .shift, charactersIgnoringModifiers: "A")
        #expect(release == KeyEvent(.character("a"), modifiers: .shift, action: .release, shiftedKey: "A", baseLayoutKey: "a"))
        #expect(KeyTranslator.releaseEvent(usage: Usage.leftControl, modifiers: .control, charactersIgnoringModifiers: "") == nil)
        let up = try #require(KeyTranslator.releaseEvent(usage: Usage.up, modifiers: [], charactersIgnoringModifiers: ""))
        // Legacy encoding has no releases; the kitty event-types flag (2)
        // with disambiguate (1) reports them.
        #expect(encoded([.key(up)]).isEmpty)
        #expect(encoded([.key(up)], keyboardFlags: 0b11) == bytes("\u{1B}[1;1:3A"))
    }

    /// Kitty flag 4: the shifted character and the US-layout key.
    @Test func `alternate keys`() throws {
        // Shift+2 on a US layout types "@".
        let at = try #require(KeyTranslator.identity(usage: 0x1F, modifiers: .shift, base: "2", characters: "@"))
        #expect(at.key == .character("2"))
        #expect(at.shiftedKey == "@")
        #expect(at.baseLayoutKey == "2")
        // On AZERTY the key at US "q" types "a".
        let azerty = try #require(KeyTranslator.identity(usage: 0x14, modifiers: [], base: "a", characters: "a"))
        #expect(azerty.key == .character("a"))
        #expect(azerty.baseLayoutKey == "q")
        #expect(azerty.shiftedKey == nil)
        // Ctrl+Shift+A: the typed character is a control code, so the
        // shifted key falls back to the capital.
        let ctrlShift = try #require(KeyTranslator.identity(usage: 4, modifiers: [.control, .shift], base: "a", characters: "\u{1}"))
        #expect(ctrlShift.shiftedKey == "A")
        #expect(KeyTranslator.usLayoutKey(usage: 0x38) == "/")
        #expect(KeyTranslator.usLayoutKey(usage: 0x27) == "0")
        #expect(KeyTranslator.usLayoutKey(usage: Usage.up) == nil)
        // Encoded with flags 1|4 (disambiguate, alternate keys).
        var out: [UInt8] = []
        InputEncoder.encode(
            .key(KeyEvent(.character("a"), modifiers: .control, baseLayoutKey: "q")),
            modes: .initial,
            keyboardFlags: 0b101,
            into: &out,
        )
        #expect(out == bytes("\u{1B}[97::113;5u"))
    }

    @Test func `text input`() {
        #expect(encoded(KeyTranslator.inputs(forText: "ls", modifiers: [])) == bytes("ls"))
        #expect(encoded(KeyTranslator.inputs(forText: "\n", modifiers: [])) == [0x0D])
        #expect(encoded(KeyTranslator.inputs(forText: "é", modifiers: [])) == bytes("é"))
        #expect(KeyTranslator.inputs(forText: "", modifiers: []).isEmpty)
        // A sticky Ctrl applies to software keyboard letters, including
        // capitals from auto-shift.
        #expect(encoded(KeyTranslator.inputs(forText: "c", modifiers: .control)) == [0x03])
        #expect(encoded(KeyTranslator.inputs(forText: "D", modifiers: .control)) == [0x04])
        // Alt sends ESC-prefixed text.
        #expect(encoded(KeyTranslator.inputs(forText: "b", modifiers: .alt)) == bytes("\u{1B}b"))
        #expect(encoded(KeyTranslator.inputs(forText: "\n", modifiers: .alt)) == bytes("\u{1B}\r"))
    }
}

struct StickyModifierTests {
    @Test func `latch lock release`() {
        var sticky = StickyModifiers()
        #expect(sticky.active.isEmpty)
        sticky.tap(.control)
        #expect(sticky.control == .latched)
        #expect(sticky.consume() == .control)
        #expect(sticky.control == .off) // a latch lasts one key
        #expect(sticky.consume().isEmpty)

        sticky.tap(.control)
        sticky.tap(.control)
        #expect(sticky.control == .locked)
        #expect(sticky.consume() == .control)
        #expect(sticky.consume() == .control) // a lock persists
        sticky.tap(.control)
        #expect(sticky.control == .off)
    }

    @Test func `independent modifiers`() {
        var sticky = StickyModifiers()
        sticky.tap(.alt)
        sticky.tap(.control)
        sticky.tap(.control)
        #expect(sticky.active == [.control, .alt])
        #expect(sticky.consume() == [.control, .alt])
        #expect(sticky.active == .control)
        #expect(sticky.state(of: .alt) == .off)
        sticky.reset()
        #expect(sticky == StickyModifiers())
    }

    @Test func `accessory keys`() {
        #expect(AccessoryKey.control.inputs(modifiers: []).isEmpty)
        #expect(AccessoryKey.control.modifier == .control)
        #expect(encoded(AccessoryKey.escape.inputs(modifiers: [])) == [0x1B])
        #expect(encoded(AccessoryKey.tab.inputs(modifiers: [])) == [0x09])
        #expect(encoded(AccessoryKey.up.inputs(modifiers: [])) == bytes("\u{1B}[A"))
        #expect(encoded(AccessoryKey.left.inputs(modifiers: .control)) == bytes("\u{1B}[1;5D"))
        #expect(encoded(AccessoryKey.symbol("|").inputs(modifiers: [])) == bytes("|"))
        #expect(encoded(AccessoryKey.symbol("\\").inputs(modifiers: .control)) == [0x1C])
        #expect(AccessoryKey.standard.prefix(4) == [.escape, .control, .alt, .tab])
    }
}

struct ScrollTests {
    @Test func `accumulator carries fractions`() {
        var acc = ScrollAccumulator()
        #expect(acc.add(0.4) == 0)
        #expect(acc.add(0.4) == 0)
        #expect(acc.add(0.4) == 1)
        #expect(abs(acc.remainder - 0.2) < 1e-9)
        #expect(acc.add(-2.5) == -2)
        #expect(abs(acc.remainder + 0.3) < 1e-9)
        acc.reset()
        #expect(acc.remainder == 0)
    }

    @Test func `momentum decays`() {
        var m = ScrollMomentum(velocity: 100)
        #expect(m.isActive)
        let first = m.step(1.0 / 60)
        #expect(first > 0 && first < 100.0 / 60)
        #expect(m.velocity < 100)
        // Integrating in small or large steps travels the same distance.
        var a = ScrollMomentum(velocity: 100), b = ScrollMomentum(velocity: 100)
        var da: CGFloat = 0
        for _ in 0 ..< 10 {
            da += a.step(0.01)
        }
        let db = b.step(0.1)
        #expect(abs(da - db) < 1e-6)
        // Total distance is v0 / (−1000 ln r) ≈ 50 lines at 100 lines/s.
        var total: CGFloat = 0
        var steps = 0
        while m.isActive, steps < 10000 {
            total += m.step(1.0 / 60)
            steps += 1
        }
        #expect(!m.isActive)
        #expect(abs(total + first - 49.95) < 1.5)
        #expect(steps < 600) // stops within ten seconds
    }

    @Test func `slow flings do not move`() {
        var m = ScrollMomentum(velocity: 1)
        #expect(!m.isActive)
        #expect(m.step(1) == 0)
        var negative = ScrollMomentum(velocity: -40)
        #expect(negative.step(0.016) < 0)
        negative.stop()
        #expect(!negative.isActive)
    }

    @Test func routing() {
        #expect(ScrollRouting(modes: .initial) == .viewport)
        #expect(ScrollRouting(modes: Modes.initial.union(.alternateScreen)) == .arrows)
        #expect(ScrollRouting(modes: [.alternateScreen]) == .viewport)
        #expect(ScrollRouting(modes: Modes.initial.union([.alternateScreen, .mouseNormal])) == .wheel)
        #expect(ScrollRouting(modes: [.mouseAny]) == .wheel)
    }
}

struct GeometryAndSelectionTests {
    let geometry = GridGeometry(scale: 3, padding: CGPoint(x: 24, y: 24), cellSize: CGSize(width: 24, height: 48))

    @Test func `cells from points`() {
        #expect(geometry.cell(at: CGPoint(x: 8, y: 8)) == (0, 0))
        #expect(geometry.cell(at: CGPoint(x: 16, y: 24)) == (1, 1))
        #expect(geometry.cell(at: CGPoint(x: 0, y: 0)) == (-1, -1)) // in the padding
        #expect(geometry.lineHeight == 16)
        let rect = geometry.rect(column: 2, row: 1)
        #expect(rect == CGRect(x: 24, y: 24, width: 8, height: 16))
        #expect(geometry.cell(at: CGPoint(x: rect.midX, y: rect.midY)) == (2, 1))
    }

    @Test func `extend keeps the starting word`() {
        let origin = (start: TerminalPoint(row: 5, column: 4), end: TerminalPoint(row: 5, column: 8))
        let forward = SelectionMath.extend(origin: origin, to: (TerminalPoint(row: 6, column: 0), TerminalPoint(row: 6, column: 3)))
        #expect(forward == Selection(anchor: origin.start, head: TerminalPoint(row: 6, column: 3)))
        let backward = SelectionMath.extend(origin: origin, to: (TerminalPoint(row: 2, column: 1), TerminalPoint(row: 2, column: 6)))
        #expect(backward == Selection(anchor: origin.end, head: TerminalPoint(row: 2, column: 1)))
        #expect(backward.start == TerminalPoint(row: 2, column: 1) && backward.end == origin.end)
        let rect = SelectionMath.extend(origin: origin, to: origin, rectangle: true)
        #expect(rect.rectangle)
    }

    @Test func `edge scrolling`() {
        #expect(SelectionMath.edgeScroll(row: -1, rows: 24) == 1)
        #expect(SelectionMath.edgeScroll(row: 0, rows: 24) == 0)
        #expect(SelectionMath.edgeScroll(row: 23, rows: 24) == 0)
        #expect(SelectionMath.edgeScroll(row: 24, rows: 24) == -1)
    }

    /// The long-press-then-drag flow against real terminal state.
    @Test func `word selection on terminal state`() {
        let session = TerminalSession(columns: 20, rows: 3)
        session.feed(bytes("hello brave world"))
        let origin = session.withState { state in
            state.wordRange(at: TerminalPoint(row: state.absoluteRow(viewportRow: 0), column: 8))
        }
        let text = session.mutate { state in
            let target = state.wordRange(at: TerminalPoint(row: state.absoluteRow(viewportRow: 0), column: 14))
            state.setSelection(SelectionMath.extend(origin: origin, to: target))
            return state.selectionText
        }
        #expect(text == "brave world")
        let back = session.mutate { state in
            let target = state.wordRange(at: TerminalPoint(row: state.absoluteRow(viewportRow: 0), column: 1))
            state.setSelection(SelectionMath.extend(origin: origin, to: target))
            return state.selectionText
        }
        #expect(back == "hello brave")
    }
}
