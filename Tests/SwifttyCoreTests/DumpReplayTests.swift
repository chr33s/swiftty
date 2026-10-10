@testable import SwifttyCore
import Testing
import TestSupport

struct DumpReplayTests {
  @Test(arguments: [47, 1047, 1049], [1, 3])
  func
    `primary dumps retain trailing blank cursor rows while alternate screen is active`(
      _ mode: Int,
      _ blankRows: Int
    )
  {
    var vt = VT(8, 6)
    vt.feed("\u{1B}7line" + String(repeating: "\r\n", count: blankRows))
    let expected = vt.state.dumpPrimaryANSI()
    vt.feed("\u{1B}[?\(mode)halternate")
    #expect(vt.state.dumpPrimaryANSI() == expected)
    var copy = VT(8, 6)
    copy.feed(bytes: vt.state.dumpPrimaryANSI())
    copy.feed("next")
    #expect(TestFixture(copy.lines[blankRows]) == TestFixture("next"))
    #expect(TestFixture(copy.lines[0]) == TestFixture("line"))
  }

  @Test(arguments: [47, 1047, 1049], [(8, 6), (3, 6), (4, 2)])
  func
    `inactive primary dumps reflow the same trailing rows as active primary dumps`(
      _ mode: Int,
      _ size: (Int, Int)
    )
  {
    var active = VT(4, 6)
    var inactive = VT(4, 6)
    let content = "\u{1B}7ABC漢\r\n\r\n"
    active.feed(content)
    inactive.feed(content + "\u{1B}[?\(mode)halternate")
    active.state.resize(columns: size.0, rows: size.1)
    inactive.state.resize(columns: size.0, rows: size.1)
    #expect(inactive.state.dumpPrimaryANSI() == active.state.dumpPrimaryANSI())
  }

  @Test(arguments: [3, 5, 7])
  func
    `styled Unicode history replays at a different width from the alternate screen`(
      _ columns: Int
    ) throws
  {
    var vt = VT(columns, 3)
    let content = String(repeating: "aé中e\u{301}👩‍💻", count: 4)
    vt.feed(
      "\u{1B}[1;3;4:3;58;2;11;22;33;38;2;44;55;66m" + content
        + "\r\n\u{1B}[0mlast"
    )
    let original = vt.state.dumpPrimaryANSI()
    let originalLine = vt.state.line(absoluteRow: 0)
    let first = try #require(originalLine).cells[0].attributes
    vt.feed("\u{1B}[?1049halternate content")
    #expect(vt.state.dumpPrimaryANSI() == original)
    var copy = VT(columns + 2, 3)
    copy.feed(bytes: original)
    let text = copy.state.text(
      from: TerminalPoint(row: 0, column: 0),
      to: TerminalPoint(
        row: copy.state.screenAbsoluteRow(copy.state.cursor.y),
        column: copy.state.cursor.x
      ),
    )
    #expect(TestFixture(text) == TestFixture(content + "\nlast"))
    let copiedLine = copy.state.line(absoluteRow: 0)
    #expect(try #require(copiedLine).cells[0].attributes == first)
  }

  @Test
  func `replay ends on fresh line`() {
    var vt = VT(49, 10)
    vt.feed("total 8\n" + String(repeating: "x", count: 30) + " .shellrc\n")
    let dump = vt.state.dumpPrimaryANSI()
    var copy = VT(37, 10)
    copy.feed(bytes: dump)
    copy.feed("bold")
    #expect(
      TestFixture(copy.lines.prefix(4))
        == TestFixture([
          "total 8", "       xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", " .shellrc",
          "bold",
        ])
    )
  }
}
