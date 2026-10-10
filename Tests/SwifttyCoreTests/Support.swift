@testable import SwifttyCore

/// A terminal plus parser driven from strings.
struct VT: ~Copyable {
  var state: TerminalState
  var parser = Parser()

  init(_ columns: Int = 10, _ rows: Int = 5, scrollback: Int = 10_000_000) {
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: scrollback
    )
  }

  mutating func feed(_ s: String) {
    let bytes = Array(s.utf8)
    parser.consume(bytes.span, into: &state)
  }

  mutating func feed(bytes: [UInt8]) {
    parser.consume(bytes.span, into: &state)
  }

  var lines: [String] { state.screenLines }

  var cursor: (x: Int, y: Int) { (state.cursor.x, state.cursor.y) }

  func cell(_ x: Int, _ y: Int) -> Cell { state.grid[x, y] }

  mutating func takeOutput() -> String {
    defer { state.output.removeAll() }
    return String(decoding: state.output, as: UTF8.self)
  }
}

let ESC = "\u{1B}"
let CSI = "\u{1B}["
