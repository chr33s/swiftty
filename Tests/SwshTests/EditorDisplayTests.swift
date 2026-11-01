import Foundation
import SwifttyEngine
import Testing
@testable import Swsh

struct EditorDisplayTests {
  @Test(arguments: [10, 20, 80])
  func clearsEveryOccupiedRow(columns: Int) {
    var terminal = TerminalState(columns: columns, rows: 12)
    var parser = SwifttyEngine.Parser()
    var display = EditorDisplay()
    for text in [
      String(repeating: "x", count: columns * 3), "short", "",
      String(repeating: "界e\u{301}🙂", count: 8), "done",
    ] {
      let bytes = display.paint(
        prompt: "swsh> ",
        bytes: Array(text.utf8),
        columns: columns,
        rows: 12
      )
      parser.consume(bytes.span, into: &terminal)
      let painted = (0 ..< 12).map { terminal.text(row: $0) }.joined()
      #expect(
        painted.filter { !$0.isWhitespace }
          == ("swsh> " + text).filter { !$0.isWhitespace }
      )
    }
    let screen = (0 ..< 12)
      .map { terminal.text(row: $0).trimmingCharacters(in: .whitespaces) }
    #expect(screen.joined().filter { $0 == ">" }.count == 1)
    #expect(screen.joined() == "swsh> done")
  }

  @Test
  func repaintAfterScrollingAtBottom() {
    var terminal = TerminalState(columns: 16, rows: 6)
    var parser = SwifttyEngine.Parser()
    parser.consume(
      Array("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n".utf8).span,
      into: &terminal
    )
    var display = EditorDisplay()
    for text in ["", String(repeating: "x", count: 45), ""] {
      let bytes = display.paint(
        prompt: "swsh> ",
        bytes: Array(text.utf8),
        columns: 16,
        rows: 6
      )
      parser.consume(bytes.span, into: &terminal)
    }
    let screen = (0 ..< 6).map { terminal.text(row: $0) }.joined()
    #expect(!screen.contains("x"))
    #expect(screen.components(separatedBy: "swsh>").count == 2)
  }

  @Test
  func resizeRepaintsWithoutOldRowsOrSoftReflow() {
    var terminal = TerminalState(columns: 24, rows: 10)
    var parser = SwifttyEngine.Parser()
    var display = EditorDisplay()
    for (columns, rows) in [
      (24, 10), (12, 5), (40, 12), (9, 3), (9, 10), (24, 10),
    ] {
      terminal.resize(columns: columns, rows: rows)
      let bytes = display.paint(
        prompt: "swsh> ",
        bytes: Array(String(repeating: "abcdefgh", count: 4).utf8),
        columns: columns,
        rows: rows
      )
      parser.consume(bytes.span, into: &terminal)
    }
    let clear = display.paint(
      prompt: "swsh> ",
      bytes: [],
      columns: 24,
      rows: 10
    )
    parser.consume(clear.span, into: &terminal)
    #expect(
      terminal.text(row: 0).trimmingCharacters(in: .whitespaces) == "swsh>"
    )
    for row in 1 ..< 10 {
      #expect(
        terminal.text(row: row).trimmingCharacters(in: .whitespaces).isEmpty
      )
    }
  }
}
