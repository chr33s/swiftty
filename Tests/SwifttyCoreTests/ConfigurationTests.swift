import Darwin
import Foundation
@testable import SwifttyCore
import Testing
import TestSupport

struct ConfigurationTests {
    @Test func `working directory modes resolve at session creation`() {
        #expect(Configuration.parse("working-directory=home").sessionConfiguration().workingDirectory == NSHomeDirectory())
        #expect(Configuration.parse("working-directory=inherit").sessionConfiguration().workingDirectory == nil)
        #expect(Configuration.parse("working-directory=~/folder").sessionConfiguration().workingDirectory == NSHomeDirectory() + "/folder")
        #expect(Configuration.parse("working-directory=/tmp/folder").sessionConfiguration().workingDirectory == "/tmp/folder")
    }

    @Test(arguments: ["/tmp\u{0}folder", "home\u{0}", "inherit\u{0}"].map(TestFixture.init))
    func `invalid configured working directories preserve earlier values`(_ path: TestFixture<String>) {
        let path = path.value
        var config = Configuration.parse("working-directory=/tmp")
        #expect(config.set("working-directory", path) != nil)
        #expect(config.workingDirectory == "/tmp")
        let parsed = Configuration.parse("working-directory=/tmp\nworking-directory=\(path)")
        #expect(parsed.diagnostics.count == 1)
        #expect(parsed.sessionConfiguration().workingDirectory == "/tmp")
    }

    @Test func `launch defaults select home without overriding explicit inheritance`() {
        var config = Configuration()
        #expect(config.resolvedWorkingDirectory(defaultsToHome: true) == NSHomeDirectory())
        #expect(config.resolvedWorkingDirectory(defaultsToHome: false) == nil)
        config.workingDirectory = "inherit"
        #expect(config.resolvedWorkingDirectory(defaultsToHome: true) == nil)
        config.workingDirectory = "home"
        #expect(config.resolvedWorkingDirectory(defaultsToHome: false) == NSHomeDirectory())
        config.workingDirectory = "relative-folder"
        #expect(config.resolvedWorkingDirectory(defaultsToHome: true) == "relative-folder")
        #expect(config.set("working-directory", "") == nil)
        #expect(config.resolvedWorkingDirectory(defaultsToHome: true) == NSHomeDirectory())
    }

    @Test(arguments: ["/bin/echo \"$HOME\" *.txt", "shell:/bin/echo \"$HOME\" *.txt", "  shell: /bin/echo \"$HOME\" *.txt  "])
    func `configured shell commands retain their expansion syntax`(_ command: String) {
        var config = Configuration()
        config.command = command
        #expect(config.sessionConfiguration().command == [
            "/bin/bash", "--noprofile", "--norc", "-c", "exec -l /bin/echo \"$HOME\" *.txt",
        ])
    }

    @Test(arguments: [
        ("direct:/bin/echo $HOME *.txt", ["/bin/echo", "$HOME", "*.txt"]),
        ("  direct: /bin/echo a  b  ", ["/bin/echo", "a", "", "b"]),
        ("direct:/bin/echo 'a b'", ["/bin/echo", "'a", "b'"]),
        ("direct:\u{300}tool literal", ["\u{300}tool", "literal"]),
        ("direct:", [""]),
    ])
    func `configured direct commands preserve space separated arguments`(_ command: String, _ expected: [String]) {
        var config = Configuration()
        config.command = command
        #expect(config.sessionConfiguration().command == expected)
        #expect(Configuration().sessionConfiguration().command == nil)
    }

    @Test(arguments: [
        (Double(-20), Double(1)), (0, 1), (0.5, 1), (1, 1), (20, 20), (200, 200), (201, 200),
        (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1), (.nan, 13),
    ])
    func `font descriptors bound configured sizes and explicit overrides`(_ input: Double, _ expected: Double) {
        var config = Configuration()
        config.fontSize = input
        #expect(config.fontDescriptor(scale: 2).size == CGFloat(expected))
        #expect(config.fontDescriptor(scale: 2, size: input).size == CGFloat(expected))
        #expect(config.fontDescriptor(scale: 2, size: 30).size == 30)
    }

    @Test(arguments: ["\u{300}name", "name\u{600}"])
    func `configuration delimiters preserve combining and prepend scalars`(_ value: String) {
        for line in ["command=\(value)", "command=\"\(value)\""] {
            let config = Configuration.parse("#\u{300}comment\n" + line)
            #expect(config.diagnostics.isEmpty)
            #expect(config.command == value)
        }
        #expect(Configuration.unquote("\"\(value)\"") == value)
        let selection = ThemeSelection(parsing: "light:\(value),dark:\(value)")
        #expect(selection?.light == value)
        #expect(selection?.dark == value)
    }

    @Test(arguments: [
        " light : Swiftty Light , dark : Swiftty Dark ",
        "dark: Swiftty Dark, light: Swiftty Light",
        "light:Swiftty Light,dark:Swiftty Dark,",
        "light:Swiftty Dark,light:Swiftty Light,dark:Swiftty Dark",
    ])
    func `appearance theme names trim whitespace and resolve`(_ value: String) {
        let config = Configuration.parse("theme=" + value)
        #expect(config.diagnostics.isEmpty)
        #expect(config.theme?.light == "Swiftty Light")
        #expect(config.theme?.dark == "Swiftty Dark")
        #expect(config.missingThemes.isEmpty)
        #expect(config.palette(for: .light).background == 0xFAFAFA)
        #expect(config.palette(for: .dark).background == 0x282C34)
    }

    @Test(arguments: [
        "light:A",
        "dark:B",
        "light:A,other:B",
        "light:A,dark=B",
        "light:A,,dark:B",
        "light:A,dark:\"B",
        "light:A,dark:B\\",
        #"light:A,dark:"B""C""#
    ])
    func `invalid theme pairs preserve the configured theme`(_ value: String) {
        var config = Configuration.parse("theme=Swiftty Dark")
        let original = config
        #expect(config.set("theme", value) != nil)
        #expect(config == original)
        let parsed = Configuration.parse("theme=Swiftty Dark\ntheme=" + value)
        #expect(parsed.theme == original.theme)
        #expect(parsed.diagnostics.count == 1)
    }

    @Test func `quoted appearance theme filenames preserve commas and escapes`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let light = "Day, Bright"
        let dark = "Night, \"Dark\""
        try "background=#123456".write(to: directory.appendingPathComponent(light), atomically: true, encoding: .utf8)
        try "background=#654321".write(to: directory.appendingPathComponent(dark), atomically: true, encoding: .utf8)
        var config = Configuration.parse(#"theme=light:"Day, Bright",dark:"Night, \"Dark\"""#)
        config.themeDirectories = [directory]
        #expect(config.diagnostics.isEmpty)
        #expect(config.theme?.light == light)
        #expect(config.theme?.dark == dark)
        #expect(config.missingThemes.isEmpty)
        #expect(config.palette(for: .light).background == 0x123456)
        #expect(config.palette(for: .dark).background == 0x654321)
        #expect(config.set("theme", "") == nil)
        #expect(config.theme == nil)
    }

    @Test func `optional include paths preserve a leading combining mark`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "\u{300}settings"
        try "font-size=19".write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        var config = Configuration()
        config.apply("config-file=?" + filename, directory: directory)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontSize == 19)
        config.apply("config-file=?\u{300}missing", directory: directory)
        #expect(config.diagnostics.isEmpty)
    }

    @Test func `includes override their parent in order after parsing`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "font-size=21\nconfig-file=nested\nfont-size=22".write(
            to: directory.appendingPathComponent("first"),
            atomically: true,
            encoding: .utf8,
        )
        try "font-size=23".write(to: directory.appendingPathComponent("nested"), atomically: true, encoding: .utf8)
        try "font-size=24".write(to: directory.appendingPathComponent("second"), atomically: true, encoding: .utf8)
        var config = Configuration.parse("config-file=first\nfont-size=19", directory: directory)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontSize == 23)
        config.apply("config-file=first\nconfig-file=second\nfont-size=20", directory: directory)
        #expect(config.fontSize == 23)
    }

    @Test func `quoted question mark includes are required literal filenames`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "font-size=27".write(to: directory.appendingPathComponent("?settings"), atomically: true, encoding: .utf8)
        let config = Configuration.parse("config-file=\"?settings\"\nconfig-file=\"?missing\"", directory: directory)
        #expect(config.fontSize == 27)
        #expect(config.diagnostics == [directory.appendingPathComponent("?missing").path + ": cannot read"])
    }

    @Test(.enabled(if: geteuid() != 0)) func `root configuration reports an inaccessible parent directory`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try "font-size=22".write(to: root, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let config = Configuration.load(from: root)
        #expect(config.fontSize == Configuration().fontSize)
        #expect(config.diagnostics == [root.path + ": cannot read"])
    }

    @Test(arguments: ["missing", "invalid", "folder"])
    func `root configuration suppresses only missing file errors`(_ kind: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("config")
        if kind == "invalid" {
            try Data([0xFF]).write(to: root)
        } else if kind == "folder" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let config = Configuration.load(from: root)
        #expect(config.fontSize == Configuration().fontSize)
        #expect(config.diagnostics == (kind == "missing" ? [] : [root.path + ": cannot read"]))
    }

    @Test func `optional includes only suppress missing file errors`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0xFF]).write(to: directory.appendingPathComponent("invalid"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let config = Configuration.parse("config-file=?missing\nconfig-file=?invalid\nconfig-file=?folder", directory: directory)
        #expect(config.diagnostics == ["invalid", "folder"].map { directory.appendingPathComponent($0).path + ": cannot read" })
    }

    @Test func `include cycles and repeated files stop before reapplying a file`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root")
        try "config-file=child\nfont-family=Menlo".write(to: root, atomically: true, encoding: .utf8)
        try "config-file=alias\nfont-family=Courier".write(to: directory.appendingPathComponent("child"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"), withDestinationURL: root)
        let config = Configuration.load(from: root)
        #expect(config.fontFamily == "Courier")
        #expect(config.diagnostics.count == 1)
        #expect(config.diagnostics.first?.contains("include cycle") == true)
        try "font-feature=liga".write(to: directory.appendingPathComponent("repeat"), atomically: true, encoding: .utf8)
        let repeated = Configuration.parse("config-file=repeat\nconfig-file=repeat", directory: directory)
        #expect(repeated.diagnostics.count == 1)
        #expect(repeated.diagnostics.first?.contains("include cycle") == true)
        #expect(repeated.fontFeatures == ["liga"])
    }

    @Test func `empty palette values restore theme colors without resetting other colors`() {
        var config = Configuration.parse("theme=Swiftty Light\nbackground=#123456\npalette=1=#010203\npalette=255=#040506")
        #expect(config.colors.palette.count == 2)
        #expect(config.set("palette", "") == nil)
        #expect(config.colors.palette.isEmpty)
        #expect(config.colors.background == 0x123456)
        var expected = Configuration.parse("theme=Swiftty Light").palette()
        expected.background = 0x123456
        #expect(config.palette() == expected)
        config.apply("palette=2=#112233\npalette=\"\"\npalette=3=#445566")
        #expect(config.diagnostics.isEmpty)
        #expect(config.colors.palette == [3: 0x445566])
        #expect(TestFixture(Themes.parse("palette=1=#010203\npalette=\nforeground=#123456").palette.isEmpty) == TestFixture(true))
    }

    @Test func `empty include values clear pending files and allow later includes`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "font-size=22".write(to: directory.appendingPathComponent("new"), atomically: true, encoding: .utf8)
        let config = Configuration.parse("config-file=missing\nconfig-file=\"\"\nfont-size=19\nconfig-file=new", directory: directory)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontSize == 22)
        try "config-file=\nconfig-file=new".write(to: directory.appendingPathComponent("clear"), atomically: true, encoding: .utf8)
        let nested = Configuration.parse("config-file=clear\nconfig-file=missing", directory: directory)
        #expect(nested.diagnostics.isEmpty)
        #expect(nested.fontSize == 22)
    }

    @Test func `nested includes join the end of the pending file queue`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "font-feature=liga\nconfig-file=nested".write(to: directory.appendingPathComponent("first"), atomically: true, encoding: .utf8)
        try "font-feature=calt".write(to: directory.appendingPathComponent("second"), atomically: true, encoding: .utf8)
        try "font-feature=ss01".write(to: directory.appendingPathComponent("nested"), atomically: true, encoding: .utf8)
        let config = Configuration.parse("config-file=first\nconfig-file=second", directory: directory)
        #expect(config.diagnostics.isEmpty)
        #expect(config.fontFeatures == ["liga", "calt", "ss01"])
    }

    @Test func `long include chains load without recursion and still detect cycles`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0 ..< 20 {
            let next = i == 19 ? 0 : i + 1
            try "font-size=\(i + 10)\nconfig-file=\(next)".write(
                to: directory.appendingPathComponent(String(i)),
                atomically: true,
                encoding: .utf8,
            )
        }
        let config = Configuration.load(from: directory.appendingPathComponent("0"))
        #expect(config.fontSize == 29)
        #expect(config.diagnostics == [directory.appendingPathComponent("0").path + ": include cycle"])
    }

    @Test func `shader paths resolve against the declaring configuration file`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "custom-shader=effect.metal".write(to: nested.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "shader source".write(to: nested.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        try "config-file=nested/config\ncustom-shader=root.metal".write(
            to: directory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8,
        )
        var config = Configuration.load(from: directory.appendingPathComponent("config"))
        #expect(config.diagnostics.isEmpty)
        #expect(config.customShader == nested.appendingPathComponent("effect.metal").path)
        let shader = try #require(config.customShader)
        #expect(try String(contentsOfFile: shader, encoding: .utf8) == "shader source")
        config.apply("font-size=17", directory: directory)
        #expect(config.customShader == shader)
        config.apply("custom-shader=next.metal", directory: directory)
        #expect(config.customShader == directory.appendingPathComponent("next.metal").path)
        config.apply("custom-shader=", directory: directory)
        #expect(config.customShader == nil)
    }

    @Test func `shader path parsing preserves absolute home and context free paths`() {
        let directory = URL(fileURLWithPath: "/tmp/swiftty-config")
        for path in ["/tmp/effect.metal", "~/effect.metal"] {
            let config = Configuration.parse("custom-shader=" + path, directory: directory)
            #expect(config.customShader == (path as NSString).expandingTildeInPath)
        }
        #expect(Configuration.parse("custom-shader=effect.metal").customShader == "effect.metal")
        var config = Configuration()
        #expect(config.set("custom-shader", "effect.metal") == nil)
        #expect(config.customShader == "effect.metal")
        #expect(Configuration.parse("custom-shader=\"effect file.metal\"", directory: directory).customShader == directory
            .appendingPathComponent("effect file.metal").path)
    }

    @Test func `relative theme paths recognize a slash before a combining mark`() throws {
        let folder = "swiftty-theme-test-" + UUID().uuidString
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "\u{300}theme"
        try "background=#123456".write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        #expect(Themes.colors(named: folder + "/" + filename, searching: [])?.background == 0x123456)
    }

    @Test func `command quoting handles continuations and combining marks`() {
        #expect(TestFixture(Configuration.arguments("echo a\\\nb")) == TestFixture(["echo", "ab"]))
        #expect(TestFixture(Configuration.arguments("echo \"a\\\nb\"")) == TestFixture(["echo", "ab"]))
        #expect(TestFixture(Configuration.arguments("\\\necho")) == TestFixture(["echo"]))
        #expect(TestFixture(Configuration.arguments("echo '\\\n'")) == TestFixture(["echo", "\\\n"]))
        #expect(Configuration.arguments("echo '\u{301}x'") == ["echo", "\u{301}x"])
        #expect(Configuration.arguments("echo 'x'\u{301}") == ["echo", "x\u{301}"])
        #expect(Configuration.arguments("echo \\\u{301}x") == ["echo", "\u{301}x"])
    }

    @Test func `programmatic palette overrides ignore invalid indices`() {
        var colors = ColorSet()
        colors.foreground = 0x123456
        colors.palette = [0: 0xABCDEF, 255: 0xFEDCBA, -1: 0, 256: 0, Int.min: 0, Int.max: 0]
        var expected = Palette.standard
        expected.foreground = 0x123456
        expected.colors[0] = 0xABCDEF
        expected.colors[255] = 0xFEDCBA
        #expect(colors.applied(to: .standard) == expected)
        var config = Configuration()
        config.colors = colors
        #expect(config.palette() == expected)
    }

    @Test func `accessibility cursor follows the scrolled viewport`() {
        let session = TerminalSession(columns: 10, rows: 3)
        session.feed(Array("old0\r\nold1\r\nold2\r\nlive\u{1B}[1;2H".utf8))
        session.scrollViewport(by: 1)
        let visible = AccessibilityText(session.snapshot())
        #expect(TestFixture(visible.lines) == TestFixture(["old0", "old1", "old2"]))
        #expect(visible.cursorLine == 1)
        #expect(visible.cursorOffset == 6)
        session.feed(Array("\u{1B}[3;2H".utf8))
        let offscreen = AccessibilityText(session.snapshot())
        #expect(offscreen.cursorLine == 2)
        #expect(offscreen.cursorOffset == offscreen.string.utf16.count)
    }

    @Test(arguments: ["no-bold,bogus", "no-italic,bogus", "no-bold-italic,bogus", "no-bold,no-italic,bogus", "no-bold,,italic", ","])
    func `invalid synthetic style lists preserve existing font settings`(_ value: String) {
        var config = Configuration()
        let original = config
        #expect(config.set("font-synthetic-style", value) != nil)
        #expect(config == original)
    }

    @Test func `synthetic style reset and overrides reach the font descriptor`() {
        var config = Configuration()
        #expect(config.set("font-synthetic-style", "false") == nil)
        #expect(!config.fontSyntheticBold && !config.fontSyntheticItalic && !config.fontSyntheticBoldItalic)
        #expect(config.set("font-synthetic-style", "bold-italic") == nil)
        let descriptor = config.fontDescriptor(scale: 2)
        #expect(!descriptor.synthesizeBold && !descriptor.synthesizeItalic && descriptor.synthesizeBoldItalic)
        #expect(config.set("font-synthetic-style", "no-bold-italic") == nil)
        #expect(!config.fontSyntheticBoldItalic)
        for value in ["true", ""] {
            #expect(config.set("font-synthetic-style", value) == nil)
            #expect(config.fontSyntheticBold && config.fontSyntheticItalic && config.fontSyntheticBoldItalic)
            #expect(config.set("font-synthetic-style", "false") == nil)
        }
    }

    @Test(arguments: ["\n", "\r\n", "\r"].map(TestFixture.init))
    func `configuration and themes accept common line endings`(_ newline: TestFixture<String>) {
        let newline = newline.value
        let lines = [
            "# Settings", "", "font-family = \"JetBrains Mono\"", "font-size = 17",
            "cursor-style-blink = false", "not a setting", "background = \"#102030\"",
            "palette = \"2=#abcdef\"", "",
        ]
        let text = lines.joined(separator: newline)
        let config = Configuration.parse(text)
        #expect(TestFixture(config) == TestFixture(Configuration.parse(lines.joined(separator: "\n"))))
        #expect(config.fontFamily == "JetBrains Mono")
        #expect(config.fontSize == 17)
        #expect(config.cursorStyleBlink == false)
        #expect(config.diagnostics == ["config:6: expected key = value"])
        #expect(Themes.parse(text) == config.colors)
        #expect(config.colors.background == 0x102030)
        #expect(config.colors.palette[2] == 0xABCDEF)
    }

    @Test func `themes accept quoted values like configuration files`() {
        let text = """
        # A theme may quote its values.
        background = "#123456"
        foreground = "abc"
        cursor-color = "red"
        palette = "1=#987654"
        selection-background = "#111111"
        selection-background = ""
        font-size = 19
        """
        let colors = Themes.parse(text)
        #expect(colors == Configuration.parse(text).colors)
        #expect(colors.background == 0x123456)
        #expect(colors.foreground == 0xAABBCC)
        #expect(colors.cursor == 0xFF0000)
        #expect(colors.palette[1] == 0x987654)
        #expect(colors.selectionBackground == nil)
    }

    @Test func `font size bindings reject nonfinite numbers`() {
        var bindings = Keybindings.defaults
        let original = bindings.action(for: KeyEvent(.character("="), modifiers: .command))
        for name in ["increase_font_size", "decrease_font_size"] {
            for value in ["nan", "inf", "-inf", "1e999", "bogus", ""] {
                #expect(bindings.apply("super+equal=\(name):\(value)") != nil)
                #expect(bindings.action(for: KeyEvent(.character("="), modifiers: .command)) == original)
            }
        }
    }

    @Test func `invalid layout and font numbers leave settings unchanged`() {
        var config = Configuration.parse("window-padding-x = 4\nadjust-cell-height = 10%\nfont-variation = wght=500")
        for value in ["nan", "inf", "-inf", "1e999"] {
            #expect(config.set("window-padding-x", value) != nil)
            #expect(config.set("adjust-cell-height", value) != nil)
            #expect(config.set("adjust-cell-height", value + "%") != nil)
            #expect(config.set("font-variation", "wght=" + value) != nil)
        }
        for value in ["2,bogus", "2,", ",2", "-1", "1,2,3"] {
            #expect(config.set("window-padding-x", value) != nil)
        }
        #expect(config.windowPaddingX == 4)
        #expect(config.adjustCellHeight.fraction == 0.1)
        #expect(config.fontVariations == ["wght": 500])
        #expect(config.set("window-padding-x", " 2 , 6 ") == nil)
        #expect(config.windowPaddingX == 6)
        #expect(config.set("adjust-cell-height", "-10%") == nil)
        #expect(config.adjustCellHeight.fraction == -0.1)
    }

    @Test(arguments: ["", "wgt", "weight", "漢a", "éab", "a\u{0}bc", "a\tbc", "abc\u{7F}"].map(TestFixture.init))
    func `invalid variation tags preserve earlier settings`(_ tag: TestFixture<String>) {
        let tag = tag.value
        var config = Configuration.parse("font-variation = wght=500")
        #expect(config.set("font-variation", tag + "=600") != nil)
        #expect(config.fontVariations == ["wght": 500])
        let parsed = Configuration.parse("font-variation = wght=500\nfont-variation = \(tag)=600")
        #expect(parsed.diagnostics.count == 1)
        #expect(parsed.fontVariations == ["wght": 500])
    }

    @Test func `variation settings trim spaces and tabs around axis and value`() {
        var config = Configuration()
        #expect(TestFixture(config.set("font-variation", " \twght \t= \t600 \t")) == TestFixture(nil))
        #expect(config.set("font-variation", "slnt = -15") == nil)
        #expect(config.set("font-variation", "AB12=2") == nil)
        #expect(config.fontVariations == ["wght": 600, "slnt": -15, "AB12": 2])
        #expect(config.fontDescriptor(scale: 1).variations == config.fontVariations)
        #expect(config.set("font-variation", "") == nil)
        #expect(config.fontVariations.isEmpty)
    }

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

    @Test(arguments: ["\n", "\r\n"].map(TestFixture.init))
    func `includes and themes`(_ newline: TestFixture<String>) throws {
        let newline = newline.value
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("themes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #000011\npalette = 2=#00aa00\nfont-size = 99\n".replacingOccurrences(of: "\n", with: newline).write(
            to: dir.appendingPathComponent("themes/Night"), atomically: true, encoding: .utf8,
        )
        try "foreground = #eeeeee\n".replacingOccurrences(of: "\n", with: newline).write(
            to: dir.appendingPathComponent("extra"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        config-file = extra
        config-file = ?missing
        theme = light:Swiftty Light,dark:Night
        palette = 2=#00ff00
        """.replacingOccurrences(of: "\n", with: newline).write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
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

    @Test(arguments: ["all:", "unconsumed:performable:all:", "all:performable:unconsumed:"])
    func `all surface scope survives parsing and replacement`(_ prefix: String) {
        var bindings = Keybindings()
        let event = KeyEvent(.character("a"), modifiers: .control)
        #expect(bindings.apply(prefix + "ctrl+a=text:X") == nil)
        #expect(bindings.binding(for: event)?.appliesToAll == true)
        #expect(bindings.binding(for: event)?.consumesInput == true)
        #expect(bindings.binding(for: event)?.requiresPerformable == false)
        let original = bindings
        #expect(bindings.apply("all:ctrl+a=bogus") != nil)
        #expect(bindings == original)
        #expect(bindings.apply("ctrl+a=text:Y") == nil)
        #expect(bindings.binding(for: event)?.appliesToAll == false)
        #expect(bindings.apply(prefix + "ctrl+a=text:X") == nil)
        #expect(bindings.apply("ctrl+a=unbind") == nil)
        #expect(bindings == Keybindings())
        #expect(bindings.apply(prefix + "ctrl+a=text:X") == nil)
        #expect(bindings.apply("clear") == nil)
        #expect(bindings == Keybindings())
    }

    @Test func `performable bindings are conditional and absent from menu shortcuts`() {
        var bindings = Keybindings()
        let event = KeyEvent(.character("c"), modifiers: .control)
        #expect(bindings.apply("performable:ctrl+c=copy_to_clipboard") == nil)
        #expect(bindings.binding(for: event)?.requiresPerformable == true)
        #expect(bindings.trigger(for: .copyToClipboard) == nil)
        #expect(bindings.apply("ctrl+c=copy_to_clipboard") == nil)
        #expect(bindings.binding(for: event)?.requiresPerformable == false)
        #expect(bindings.trigger(for: .copyToClipboard) == KeyTrigger(.character("c"), modifiers: .control))
        #expect(bindings.apply("performable:all:ctrl+c=copy_to_clipboard") == nil)
        #expect(bindings.binding(for: event)?.requiresPerformable == false)
        #expect(bindings.apply("performable:ctrl+c=copy_to_clipboard") == nil)
        #expect(bindings.apply("ctrl+c=unbind") == nil)
        #expect(bindings == Keybindings())
        #expect(bindings.apply("performable:ctrl+c=copy_to_clipboard") == nil)
        #expect(bindings.apply("clear") == nil)
        #expect(bindings == Keybindings())
    }

    @Test func `menu shortcut modifier ties are deterministic`() {
        let tables = (0 ..< 100).map { index in
            var bindings = Keybindings()
            let triggers = index.isMultiple(of: 2) ? ["alt+x", "ctrl+x"] : ["ctrl+x", "alt+x"]
            for trigger in triggers {
                #expect(bindings.apply(trigger + "=copy_to_clipboard") == nil)
            }
            #expect(bindings.apply("ctrl+\u{340}=ignore") == nil)
            #expect(bindings.apply("ctrl+\u{300}=ignore") == nil)
            return bindings
        }
        let shortcuts = Set(tables.compactMap { $0.trigger(for: .copyToClipboard) })
        #expect(shortcuts == [KeyTrigger(.character("x"), modifiers: .alt)])
        let unicodeShortcuts = Set(tables.compactMap { $0.trigger(for: .ignore) })
        #expect(unicodeShortcuts == [KeyTrigger(.character("\u{300}"), modifiers: .control)])
    }

    @Test func `unicode key triggers survive expanding lowercase mappings`() {
        var bindings = Keybindings()
        #expect(bindings.apply("ctrl+İ=text:X") == nil)
        #expect(TestFixture(bindings.action(for: KeyEvent(.character("İ"), modifiers: .control))) == TestFixture(.text("X")))
        #expect(bindings.apply("ctrl+Ö=text:Y") == nil)
        #expect(TestFixture(bindings.action(for: KeyEvent(.character("ö"), modifiers: .control))) == TestFixture(.text("Y")))
        #expect(TestFixture(bindings.action(for: KeyEvent(.character("Ö"), modifiers: .control))) == TestFixture(.text("Y")))
        #expect(bindings.apply("ctrl+😀=ignore") == nil)
        #expect(bindings.action(for: KeyEvent(.character("😀"), modifiers: .control)) == .ignore)
        #expect(bindings.apply("ctrl+i\u{307}=ignore") != nil)
        #expect(bindings.apply("ctrl+\u{600}=text:Z") == nil)
        #expect(TestFixture(bindings.action(for: KeyEvent(.character("\u{600}"), modifiers: .control))) == TestFixture(.text("Z")))
        #expect(bindings.apply("all:\u{300}=ignore") == nil)
        #expect(bindings.binding(for: KeyEvent(.character("\u{300}")))?.appliesToAll == true)
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
        #expect(TestFixture(b.action(for: KeyEvent(.character("T"), modifiers: [.control, .shift]))) == TestFixture(.text("hi\n")))
        #expect(b.action(for: KeyEvent(.character("c"), modifiers: .command)) == nil)
        #expect(b.action(for: KeyEvent(.character("v"), modifiers: .command)) == .pasteFromClipboard)
        #expect(b.action(for: KeyEvent(.up, modifiers: .command)) == .scrollPageLines(-3))
        #expect(b.action(for: KeyEvent(.character("G"), modifiers: [.command, .shift])) == .navigateSearch(next: false))
        #expect(TestFixture(KeyAction.csi("2J").bytes) == TestFixture(Array("\u{1B}[2J".utf8)))
        _ = config.set("keybind", "clear")
        #expect(config.keybindings.bindings.isEmpty)
        _ = config.set("keybind", "")
        #expect(config.keybindings == .defaults)
    }

    @Test func `unconsumed binding metadata follows replacements and matching`() {
        var bindings = Keybindings()
        let event = KeyEvent(.character("+"), modifiers: [.control, .shift])
        #expect(bindings.apply("unconsumed:ctrl+plus=text:X") == nil)
        #expect(bindings.binding(for: event)?.consumesInput == false)
        #expect(bindings.apply("ctrl+plus=text:Y") == nil)
        #expect(bindings.binding(for: event)?.consumesInput == true)
        #expect(bindings.apply("performable:unconsumed:ctrl+plus=text:X") == nil)
        #expect(bindings.binding(for: event)?.consumesInput == false)
        #expect(bindings.apply("unconsumed:performable:ctrl+plus=text:X") == nil)
        #expect(bindings.binding(for: event)?.consumesInput == false)
        let original = bindings
        #expect(bindings.apply("ctrl+plus=bogus") != nil)
        #expect(bindings == original)
        #expect(bindings.apply("ctrl+plus=unbind") == nil)
        #expect(bindings == Keybindings())
        #expect(bindings.apply("unconsumed:all:ctrl+plus=text:X") == nil)
        #expect(bindings.binding(for: event)?.consumesInput == true)
        #expect(bindings.apply("clear") == nil)
        #expect(bindings == Keybindings())
    }

    @Test func `integer boundary navigation bindings remain usable`() throws {
        var bindings = Keybindings()
        #expect(bindings.apply("ctrl+a=scroll_page_lines:\(Int.min)") == nil)
        let action = try #require(bindings.action(for: KeyEvent(.character("a"), modifiers: .control)))
        #expect(ActionDispatch.viewportDelta(for: action, rows: 24, history: 100) == Int.max)
        #expect(ActionDispatch.title(for: action) == "Scroll Up \(Int.min.magnitude) Lines")
        #expect(bindings.apply("ctrl+a=jump_to_prompt:\(Int.min)") == nil)
        let jump = try #require(bindings.action(for: KeyEvent(.character("a"), modifiers: .control)))
        #expect(ActionDispatch.title(for: jump) == "Previous Prompt")
    }

    @Test func `text bindings decode Unicode and raw byte escapes`() {
        for (parameter, expected) in [
            ("\u{300}", Array("\u{300}".utf8)),
            (#"\u{1F600}\u{301}"#, Array("😀\u{301}".utf8)),
            (#"\xC3\xA9"#, Array("é".utf8)),
            (#"\x00\x80\xFF"#, [UInt8(0), 0x80, 0xFF]),
            (#"\"\'\\\e\n\r\t"#, Array("\"'\\\u{1B}\n\r\t".utf8)),
        ] {
            var bindings = Keybindings()
            #expect(bindings.apply("ctrl+a=text:" + parameter) == nil)
            #expect(bindings.action(for: KeyEvent(.character("a"), modifiers: .control))?.bytes == expected)
        }
    }

    @Test func `malformed text escapes preserve existing bindings`() {
        var bindings = Keybindings()
        #expect(bindings.apply("ctrl+a=text:ok") == nil)
        for parameter in [#"\x"#, #"\x1"#, #"\xGG"#, #"\u{}"#, #"\u{110000}"#, #"\u{D800}"#, #"\u{41"#, #"\q"#, "\\"] {
            #expect(bindings.apply("ctrl+a=text:" + parameter) != nil)
            #expect(TestFixture(bindings.action(for: KeyEvent(.character("a"), modifiers: .control))) == TestFixture(.text("ok")))
        }
    }

    @Test(
        arguments: ["foreground", "background", "cursor-color", "cursor-text", "selection-foreground", "selection-background"],
        ["#12", "11223344", "12gg34", "not-a-color"],
    )
    func `invalid color overrides preserve earlier settings and report diagnostics`(_ key: String, _ value: String) {
        var config = Configuration.parse("font-size=17\npalette=2=#abcdef\n\(key)=#123456")
        let original = config
        #expect(config.set(key, value) != nil)
        #expect(config == original)
        config.apply("\(key)=\(value)", name: "override")
        #expect(config.diagnostics.count == 1)
        #expect(config.diagnostics.first?.contains(key) == true)
        #expect(config.diagnostics.first?.contains(value) == true)
        config.diagnostics.removeAll()
        #expect(config == original)
    }

    @Test(arguments: ["-1=#fff", "256=#fff", "2=#xyz", "2=", "=#fff", "2", "2=red=blue", "999999999999999999999999=#fff"])
    func `invalid palette overrides preserve all earlier color settings`(_ value: String) {
        var config = Configuration.parse("foreground=#123456\npalette=2=#abcdef\npalette=7=#fedcba")
        let original = config
        #expect(config.set("palette", value) != nil)
        #expect(config == original)
        config.apply("palette=\(value)", name: "override")
        #expect(config.diagnostics.count == 1)
        config.diagnostics.removeAll()
        #expect(config == original)
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
        #expect(TestFixture(text.string) == TestFixture("hello\n中x\nab"))
        #expect(text.lineRanges[1] == NSRange(location: 6, length: 2))
        #expect(text.cursorLine == 2 && text.cursorOffset == 11)
        #expect(text.line(forOffset: 7) == 1)
    }
}
