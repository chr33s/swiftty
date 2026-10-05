import Foundation
@testable import SwifttyCore
import Testing

struct ConfigurationTests {
    @Test func `parses Ghostty syntax`() {
        let config = Configuration.parse("""
        # comment
        font-family = "JetBrains Mono"
        font-size = 15
        font-feature = calt, -liga
        font-feature = ss01
        font-variation = wght=600
        font-synthetic-style = no-bold
        adjust-cell-height = 10%
        adjust-cell-width = 1
        background = #102030
        foreground = fff
        palette = 1=#ff0000
        selection-background = #333333
        background-opacity = 0.9
        background-blur = true
        minimum-contrast = 3
        cursor-style = block_hollow
        cursor-style-blink = false
        scrollback-limit = 2000000
        window-padding-x = 2,6
        copy-on-select = clipboard
        """)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontFamily == "JetBrains Mono" && config.fontSize == 15)
        #expect(config.fontFeatures == ["calt", "-liga", "ss01"])
        #expect(config.fontVariations == ["wght": 600])
        #expect(!config.fontSyntheticBold && config.fontSyntheticItalic)
        #expect(config.adjustCellHeight.fraction == 0.1 && config.adjustCellWidth.points == 1)
        let palette = config.palette()
        #expect(palette.background == 0x102030 && palette.foreground == 0xFFFFFF)
        #expect(palette.colors[1] == 0xFF0000 && palette.selectionBackground == 0x333333)
        #expect(config.backgroundOpacity == 0.9 && config.backgroundBlur == 20 && config.minimumContrast == 3)
        #expect(config.cursorStyle == .block && config.cursorHollow && config.cursorStyleBlink == false)
        #expect(config.scrollbackLimit == 2_000_000 && config.windowPaddingX == 6 && config.copyOnSelect)
        let font = config.fontDescriptor(scale: 2)
        #expect(font.family == "JetBrains Mono" && font.size == 15 && font.cellHeightAdjust == 0.1 && !font.synthesizeBold)
        #expect(config.renderOptions(scale: 2).paddingX == 12)
        #expect(config.sessionConfiguration().scrollbackLimitBytes == 2_000_000)
    }

    @Test func `reports problems and resets with empty values`() {
        let config = Configuration.parse("""
        font-size = huge
        no-such-key = 1
        just text
        font-size = 20
        font-size =
        """)
        #expect(config.diagnostics.count == 3)
        #expect(config.diagnostics[0].hasPrefix("config:1: font-size"))
        #expect(config.fontSize == 13)
    }

    @Test func `includes and themes`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("themes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #000011\npalette = 2=#00aa00\nfont-size = 99\n".write(
            to: dir.appendingPathComponent("themes/Night"), atomically: true, encoding: .utf8,
        )
        try "foreground = #eeeeee\n".write(to: dir.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        try """
        config-file = extra
        config-file = ?missing
        theme = light:Swiftty Light,dark:Night
        palette = 2=#00ff00
        """.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        var config = Configuration.load(from: dir.appendingPathComponent("config"))
        config.themeDirectories = [dir.appendingPathComponent("themes")]
        #expect(config.diagnostics.isEmpty)
        let dark = config.palette(for: .dark)
        #expect(dark.background == 0x000011)
        #expect(dark.foreground == 0xEEEEEE)
        #expect(dark.colors[2] == 0x00FF00) // the config overrides the theme
        #expect(config.fontSize == 13) // themes only carry colors
        #expect(config.palette(for: .light).background == 0xFAFAFA)
        #expect(config.missingThemes.isEmpty)
        config.theme = ThemeSelection(parsing: "Nope")
        #expect(config.missingThemes == ["Nope"])
    }

    @Test func `keybindings parse and match`() {
        var config = Configuration.parse("""
        keybind = ctrl+shift+t=text:hi\\n
        keybind = super+c=unbind
        keybind = performable:super+arrow_up=scroll_page_lines:-3
        keybind = super+bogus_key=reset
        keybind = global:super+x=reset
        """)
        #expect(config.diagnostics.count == 2)
        let b = config.keybindings
        #expect(b.action(for: KeyEvent(.character("T"), modifiers: [.control, .shift])) == .text("hi\n"))
        #expect(b.action(for: KeyEvent(.character("c"), modifiers: .command)) == nil)
        #expect(b.action(for: KeyEvent(.character("v"), modifiers: .command)) == .pasteFromClipboard)
        #expect(b.action(for: KeyEvent(.up, modifiers: .command)) == .scrollPageLines(-3))
        #expect(b.action(for: KeyEvent(.character("G"), modifiers: [.command, .shift])) == .navigateSearch(next: false))
        #expect(KeyAction.csi("2J").bytes == Array("\u{1B}[2J".utf8))
        _ = config.set("keybind", "clear")
        #expect(config.keybindings.bindings.isEmpty)
        _ = config.set("keybind", "")
        #expect(config.keybindings == .defaults)
    }

    @Test func `colors`() {
        #expect(Configuration.parseColor("#abc") == 0xAABBCC)
        #expect(Configuration.parseColor("123456") == 0x123456)
        #expect(Configuration.parseColor("White") == 0xFFFFFF)
        #expect(Configuration.parseColor("#12345") == nil)
    }

    @Test func `accessibility text`() {
        let session = TerminalSession(columns: 10, rows: 3)
        session.feed(Array("hello\r\n中x\r\nab".utf8))
        let text = AccessibilityText(session.snapshot())
        #expect(text.string == "hello\n中x\nab")
        #expect(text.lineRanges[1] == NSRange(location: 6, length: 2))
        #expect(text.cursorLine == 2 && text.cursorOffset == 11)
        #expect(text.line(forOffset: 7) == 1)
    }
}
