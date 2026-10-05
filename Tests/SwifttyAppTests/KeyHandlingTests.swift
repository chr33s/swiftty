import AppKit
@testable import Swiftty
import SwifttyCore
import Testing

/// The macOS app's input handling: NSEvent translation, bindings, menu
/// shortcuts and pointer shapes.
@MainActor
struct KeyHandlingTests {
    func key(_ code: UInt16, _ characters: String, unmodified: String? = nil, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: unmodified ?? characters, isARepeat: false, keyCode: code,
        ))
    }

    @Test func `special and control keys are encoded by the terminal`() throws {
        #expect(try TerminalView.terminalKey(for: key(126, "\u{F700}")) == KeyEvent(.up))
        #expect(try TerminalView.terminalKey(for: key(36, "\r", [.shift])) == KeyEvent(.enter, modifiers: .shift))
        let ctrlC = try TerminalView.terminalKey(for: key(8, "\u{3}", unmodified: "c", [.control]))
        #expect(ctrlC?.key == .character("c") && ctrlC?.modifiers == .control)
        #expect(ctrlC?.baseLayoutKey == "c")
        // Plain text goes to the input method instead.
        #expect(try TerminalView.terminalKey(for: key(0, "a")) == nil)
        #expect(try TerminalView.terminalKey(for: key(0, "å", unmodified: "a", [.option])) == nil)
    }

    @Test func `bindings match events`() throws {
        let bindings = Keybindings.defaults
        func action(_ event: NSEvent) -> KeyAction? {
            TerminalView.trigger(for: event).flatMap { bindings.action(for: $0) }
        }
        #expect(try action(key(8, "c", [.command])) == .copyToClipboard)
        #expect(try action(key(126, "\u{F700}", [.command])) == .jumpToPrompt(-1))
        #expect(try action(key(24, "+", unmodified: "+", [.command, .shift])) == .increaseFontSize(1))
        #expect(try action(key(5, "G", unmodified: "G", [.command, .shift])) == .navigateSearch(next: false))
        #expect(try action(key(0, "a")) == nil)
    }

    @Test func `menu shortcuts follow bindings`() throws {
        var bindings = Keybindings.defaults
        let copy = try #require(bindings.trigger(for: .copyToClipboard))
        let equivalent = try #require(AppDelegate.keyEquivalent(copy))
        #expect(equivalent.key == "c" && equivalent.modifiers == .command)
        _ = bindings.apply("super+arrow_up=unbind")
        _ = bindings.apply("ctrl+shift+arrow_up=jump_to_prompt:-1")
        let jumpTrigger = try #require(bindings.trigger(for: .jumpToPrompt(-1)))
        let jump = try #require(AppDelegate.keyEquivalent(jumpTrigger))
        #expect(try jump.key == String(Character(#require(UnicodeScalar(UInt16(NSUpArrowFunctionKey))))))
        #expect(jump.modifiers == [.control, .shift])
    }

    @Test func `modifier flags`() {
        #expect(TerminalView.modifiers([.command, .option, .shift, .control]) == [.command, .alt, .shift, .control])
    }

    @Test func `pointer shapes`() {
        _ = NSApplication.shared // cursors need the app's connection to the window server
        #expect(TerminalView.cursor(named: "pointer") == .pointingHand)
        #expect(TerminalView.cursor(named: "default") == .arrow)
        #expect(TerminalView.cursor(named: "no-such-shape") == .iBeam)
    }

    @Test func `appearance maps to a color scheme`() throws {
        #expect(try TerminalView.scheme(of: #require(NSAppearance(named: .aqua))) == .light)
        #expect(try TerminalView.scheme(of: #require(NSAppearance(named: .darkAqua))) == .dark)
    }
}
