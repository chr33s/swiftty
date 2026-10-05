import Foundation
import SwifttyCore
@testable import SwifttyMobile
import Testing

struct ActionDispatchTests {
    @Test func `viewport deltas`() {
        #expect(ActionDispatch.viewportDelta(for: .scrollToTop, rows: 24, history: 500) == 500)
        #expect(ActionDispatch.viewportDelta(for: .scrollToBottom, rows: 24, history: 500) == -500)
        #expect(ActionDispatch.viewportDelta(for: .scrollPageUp, rows: 24, history: 500) == 24)
        #expect(ActionDispatch.viewportDelta(for: .scrollPageDown, rows: 24, history: 500) == -24)
        #expect(ActionDispatch.viewportDelta(for: .scrollPageLines(3), rows: 24, history: 500) == -3)
        #expect(ActionDispatch.viewportDelta(for: .scrollPageLines(-3), rows: 24, history: 500) == 3)
        #expect(ActionDispatch.viewportDelta(for: .copyToClipboard, rows: 24, history: 500) == nil)
        #expect(ActionDispatch.viewportDelta(for: .jumpToPrompt(-1), rows: 24, history: 500) == nil)
    }

    @Test func `titles for the default bindings`() {
        let titles = Set(Keybindings.defaults.bindings.values.map(ActionDispatch.title(for:)))
        #expect(titles.isSuperset(of: ["Copy", "Paste", "Bigger", "Smaller", "Find…", "Previous Prompt", "Next Prompt", "Clear Screen"]))
        #expect(!titles.contains(""))
    }

    /// Hardware keys reach the default bindings, including shifted
    /// punctuation (Cmd-Shift-= types "+").
    @Test func `hardware keys find bindings`() throws {
        let bindings = Keybindings.defaults
        let copy = try #require(KeyTranslator.identity(usage: 6, modifiers: .command, base: "c", characters: "c"))
        #expect(bindings.action(for: copy) == .copyToClipboard)
        let plus = try #require(KeyTranslator.identity(usage: 0x2E, modifiers: [.command, .shift], base: "+", characters: "+"))
        #expect(bindings.action(for: plus) == .increaseFontSize(1))
        let up = try #require(KeyTranslator.identity(usage: KeyTranslator.Usage.up, modifiers: .command, base: ""))
        #expect(bindings.action(for: up) == .jumpToPrompt(-1))
        let findPrevious = try #require(KeyTranslator.identity(usage: 0x0A, modifiers: [.command, .shift], base: "g", characters: "G"))
        #expect(bindings.action(for: findPrevious) == .navigateSearch(next: false))
        let plain = try #require(KeyTranslator.identity(usage: 4, modifiers: [], base: "a", characters: "a"))
        #expect(bindings.action(for: plain) == nil)
    }

    /// Scroll and prompt-jump actions against real terminal state.
    @Test func `actions on terminal state`() {
        let session = TerminalSession(columns: 20, rows: 4)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        for _ in 0 ..< 6 {
            session.feed(shell.input(Array("echo x\r".utf8)))
        }
        session.mutate { state in
            let history = state.addressableRows - state.rows
            state.scrollViewport(by: ActionDispatch.viewportDelta(for: .scrollToTop, rows: state.rows, history: history)!)
        }
        let top = session.withState { $0.viewportOffset }
        #expect(top > 0)
        let jumped = session.mutate { $0.jumpToPrompt(1) }
        #expect(jumped)
        #expect(session.withState { $0.viewportOffset } < top)
    }
}

struct PointerShapeTests {
    @Test func `css names`() {
        #expect(PointerShape(cssName: "text") == .beam)
        #expect(PointerShape(cssName: "pointer") == .link)
        #expect(PointerShape(cssName: "default") == .system)
        #expect(PointerShape(cssName: "crosshair") == .crosshair)
        #expect(PointerShape(cssName: "ew-resize") == .resizeHorizontal)
        #expect(PointerShape(cssName: "row-resize") == .resizeVertical)
        #expect(PointerShape(cssName: "grab") == .move)
        #expect(PointerShape(cssName: "none") == .hidden)
        #expect(PointerShape(cssName: "Wait") == .system)
        #expect(PointerShape(cssName: "no-such-cursor") == .beam)
    }

    @Test func resolution() {
        #expect(PointerShape.resolve(applicationShape: "", overLink: false, tracking: false) == .beam)
        #expect(PointerShape.resolve(applicationShape: "", overLink: false, tracking: true) == .system)
        #expect(PointerShape.resolve(applicationShape: "crosshair", overLink: false, tracking: true) == .crosshair)
        #expect(PointerShape.resolve(applicationShape: "crosshair", overLink: true, tracking: false) == .link)
    }

    /// OSC 22 arrives as an event with the CSS name.
    @Test func `osc 22 event`() {
        final class Shapes: @unchecked Sendable {
            var names: [String] = []
        }
        let shapes = Shapes()
        let session = TerminalSession()
        // `feed` publishes events synchronously on the session queue.
        session.onEvent = { event in
            if case let .pointerShape(name) = event {
                shapes.names.append(name)
            }
        }
        session.feed(Array("\u{1B}]22;pointer\u{1B}\\".utf8))
        let shape = shapes.names.last
        #expect(shape.map(PointerShape.init(cssName:)) == .link)
    }
}

struct BlinkStateTests {
    @Test func `toggles while blinking`() {
        var blink = BlinkState()
        #expect(blink.cursorVisible && blink.textVisible)
        blink.tick(cursorBlinks: true, textBlinks: false)
        #expect(!blink.cursorVisible)
        #expect(blink.textVisible)
        blink.tick(cursorBlinks: true, textBlinks: true)
        #expect(blink.cursorVisible)
        #expect(!blink.textVisible)
        // Something that stops blinking is shown.
        blink.tick(cursorBlinks: false, textBlinks: false)
        #expect(blink.cursorVisible && blink.textVisible)
        blink.tick(cursorBlinks: true, textBlinks: true)
        blink.reset()
        #expect(blink == BlinkState())
    }

    @Test func `timer only when needed`() {
        #expect(BlinkState.needsTimer(cursorBlinks: true, textBlinks: false, focused: true, background: false))
        #expect(!BlinkState.needsTimer(cursorBlinks: true, textBlinks: false, focused: false, background: false))
        #expect(BlinkState.needsTimer(cursorBlinks: false, textBlinks: true, focused: false, background: false))
        #expect(!BlinkState.needsTimer(cursorBlinks: true, textBlinks: true, focused: true, background: true))
        #expect(!BlinkState.needsTimer(cursorBlinks: false, textBlinks: false, focused: true, background: false))
    }
}

struct LinkTests {
    @Test func `scheme filter`() {
        #expect(LinkPolicy.openableURL("https://ghostty.org")?.host == "ghostty.org")
        #expect(LinkPolicy.openableURL("HTTP://example.com/a?b=c") != nil)
        #expect(LinkPolicy.openableURL("mailto:someone@example.com") != nil)
        #expect(LinkPolicy.openableURL("ssh://host") != nil)
        #expect(LinkPolicy.openableURL("ftp://files.example.com") != nil)
        #expect(LinkPolicy.openableURL("file:///etc/passwd") == nil)
        #expect(LinkPolicy.openableURL("javascript:alert(1)") == nil)
        #expect(LinkPolicy.openableURL("myapp://do-something") == nil)
        #expect(LinkPolicy.openableURL("https:") == nil)
        #expect(LinkPolicy.openableURL("not a url") == nil)
    }

    @Test func `span in snapshot rows`() {
        let range = TerminalRange(start: TerminalPoint(row: 105, column: 3), end: TerminalPoint(row: 106, column: 2))
        let span = LinkPolicy.span(of: range, firstVisibleRow: 100)
        #expect(span == HighlightSpan(startRow: 5, startColumn: 3, endRow: 6, endColumn: 2))
    }

    @Test func `click to move keys`() {
        #expect(ClickToMove.keys(0).isEmpty)
        #expect(ClickToMove.keys(-2) == [KeyEvent(.left), KeyEvent(.left)])
        #expect(ClickToMove.keys(3).count == 3)
        #expect(ClickToMove.keys(3).allSatisfy { $0.key == .right })
    }
}

struct ConfigurationUseTests {
    /// What the frontend reads from a Ghostty-syntax config.
    @Test func `frontend settings`() throws {
        let config = Configuration.parse("""
        theme = light:Swiftty Light,dark:Swiftty Dark
        font-size = 15
        background-opacity = 0.8
        background-blur = 20
        cursor-style-blink = false
        keybind = ctrl+shift+f=start_search
        """)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontSize != Configuration().fontSize) // overrides Dynamic Type
        #expect(Configuration().fontSize == 13)
        #expect(config.palette(for: .light) != config.palette(for: .dark))
        #expect(config.backgroundOpacity < 1 && config.backgroundBlur > 0)
        #expect(config.cursorStyleBlink == false)
        let trigger = try #require(KeyTranslator.identity(usage: 0x09, modifiers: [.control, .shift], base: "f", characters: "\u{6}"))
        #expect(config.keybindings.action(for: trigger) == .startSearch)
    }
}
