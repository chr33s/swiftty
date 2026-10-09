@testable import SwifttyCore
import Testing
import TestSupport

struct SGRColorTests {
    @Test(arguments: ["38", "48", "58"], [false, true])
    func `color space fields are optional only in colon RGB groups`(_ target: String, _ fragmented: Bool) {
        let fixtures: [(String, TerminalColor)] = [
            (":2:11:22:33", .rgb(11, 22, 33)),
            (":2::11:22:33", .rgb(11, 22, 33)),
            (":2:0:11:22:33", .rgb(11, 22, 33)),
            (";2;0;11;22", .rgb(0, 11, 22)),
        ]
        for (parameters, color) in fixtures {
            var vt = VT(8, 3)
            let input = "\u{1B}[" + target + parameters + ";3;9mX"
            if fragmented {
                for byte in input.utf8 {
                    vt.feed(bytes: [byte])
                }
            } else {
                vt.feed(input)
            }
            let attributes = vt.cell(0, 0).attributes
            #expect(attributes.foreground == (target == "38" ? color : .default))
            #expect(attributes.background == (target == "48" ? color : .default))
            #expect(vt.state.underlineColor(attributes.underlineColor) == (target == "58" ? color : nil))
            #expect(attributes.flags == [.italic, .strikethrough])
            #expect(TestFixture(vt.lines) == TestFixture(["X", "", ""]))
        }
    }

    @Test(arguments: [false, true])
    func `mixed Kakoune color sequences preserve following attributes`(_ fragmented: Bool) {
        let fixtures: [(String, TerminalColor, TerminalColor, TerminalColor)] = [
            ("0;4:3;38;2;175;175;215;58:2:0:190:80:70", .rgb(175, 175, 215), .default, .rgb(190, 80, 70)),
            ("4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136", .rgb(51, 51, 51), .rgb(170, 170, 170), .rgb(255, 97, 136)),
        ]
        for (parameters, foreground, background, underline) in fixtures {
            var vt = VT(8, 3)
            let input = "\u{1B}[" + parameters + ";1mX\u{1B}[0mY"
            if fragmented {
                for byte in input.utf8 {
                    vt.feed(bytes: [byte])
                }
            } else {
                vt.feed(input)
            }
            let attributes = vt.cell(0, 0).attributes
            #expect(attributes.foreground == foreground)
            #expect(attributes.background == background)
            #expect(vt.state.underlineColor(attributes.underlineColor) == underline)
            #expect(attributes.flags == [.underline, .underlineStyleA, .bold])
            #expect(vt.cell(1, 0).attributes == .default)
            #expect(TestFixture(vt.lines) == TestFixture(["XY", "", ""]))
        }
    }
}
