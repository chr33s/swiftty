import SwifttyCore
@testable import SwifttyMobile
import Testing
import TestSupport

struct DemoUnicodeTests {
    /// Compare the editor's column model with actual terminal parsing for
    /// every zero-width scalar, including combinations that gain width.
    @Test(arguments: ["a", "क", "漢"])
    func `zero width leading scalars stay aligned when followed by text`(_ base: String) {
        var failures: [UInt32] = []
        var count = 0
        let prompt = DemoShell.prompt
        for value: UInt32 in 0 ..< 0x110000 where UnicodeWidth.width(value) == 0 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            count += 1
            let input = String(scalar) + base + "Z"
            let columns = TerminalGeometry.compositionColumn(in: Array(input.unicodeScalars), atUTF16Offset: .max)
            var shell = DemoShell()
            var state = TerminalState(columns: 60, rows: 3)
            var parser = Parser()
            parser.consume(prompt.span, into: &state)
            let start = state.cursor.x
            let output = shell.input(Array(input.utf8))
            parser.consume(output.span, into: &state)
            let clear = shell.input([0x0C])
            let matches = state.cursor.x == start + columns
            parser.consume(clear.span, into: &state)
            if !matches || state.cursor.x != start + columns {
                if failures.count < 20 {
                    failures.append(value)
                }
            }
        }
        #expect(count > 0)
        #expect(
            failures.isEmpty,
            Comment(rawValue: escapedTestText("Zero-width leads with \(base): \(failures.map { String($0, radix: 16) })")),
        )
    }
}
