import Foundation
@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

struct ReviewRegressionTests {
  @Test
  func `external transport exit discards incomplete stream state`() {
    let prefixes =
      [
        "\u{1B}]2;pending", "\u{1B}[12;", "\u{1B}P$q", "\u{1B}P$qm\u{1B}",
        "\u{1B}_pending",
      ]
      .map { Array($0.utf8) } + [[0xF0, 0x9F]]
    for prefix in prefixes {
      let session = TerminalSession(columns: 10, rows: 2)
      let replies = Mutex<[[UInt8]]>([])
      session.onWrite = { bytes in replies.withLock { $0.append(bytes) } }
      session.receive(Array("old".utf8) + prefix)
      session.programExited()
      session.receive(Array("ok".utf8))
      #expect(
        TestFixture(session.snapshot().text) == TestFixture(["oldok", ""])
      )
      #expect(replies.withLock { $0.isEmpty })
    }
  }

  @Test
  func `external transport exit ends control mode once`() {
    let session = TerminalSession(columns: 10, rows: 2)
    let events = Mutex<[TerminalEvent]>([])
    session.onEvent = { event in events.withLock { $0.append(event) } }
    session.receive(Array("old\u{1B}P1000p%begin\n".utf8))
    session.programExited()
    session.programExited()
    session.receive(Array("ok".utf8))
    #expect(TestFixture(session.snapshot().text) == TestFixture(["oldok", ""]))
    #expect(!session.withState { $0.isControlMode })
    #expect(events.withLock { $0 } == [.controlModeStarted, .controlModeEnded])
  }

  @Test
  func `session reset ends control mode before accepting new text`() {
    let session = TerminalSession(columns: 10, rows: 2)
    let events = Mutex<[TerminalEvent]>([])
    session.onEvent = { event in events.withLock { $0.append(event) } }
    session.feed(Array("\u{1B}P1000p%begin\n".utf8))
    session.reset()
    session.receive(Array("ok".utf8))
    let snapshot = session.snapshot()
    #expect(TestFixture(snapshot.text) == TestFixture(["ok", ""]))
    #expect(!session.withState { $0.isControlMode })
    #expect(events.withLock { $0 } == [.controlModeStarted, .controlModeEnded])
  }

  @Test
  func `session reset abandons incomplete parser sequences`() {
    for sequence in [
      "\u{1B}]2;pending", "\u{1B}[12;", "\u{1B}P$q", "\u{1B}P$qm\u{1B}",
      "\u{1B}_pending",
    ] {
      let session = TerminalSession(columns: 10, rows: 2)
      session.feed(Array(sequence.utf8))
      session.reset()
      session.receive(Array("ok".utf8))
      #expect(TestFixture(session.snapshot().text) == TestFixture(["ok", ""]))
    }
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed([0xF0, 0x9F])
    session.reset()
    session.feed(Array("ok".utf8))
    #expect(TestFixture(session.snapshot().text) == TestFixture(["ok", ""]))
  }

  @Test
  func
    `full reset clears both saved cursors while soft reset clears the active one`()
  {
    for reset in ["\u{1B}c", "\u{1B}[!p"] {
      var vt = VT(10, 6)
      vt.feed("\u{1B}[2;5r\u{1B}[?6h\u{1B}7")
      vt.feed("\u{1B}[?47h\u{1B}7" + reset)
      if reset == "\u{1B}c" { vt.feed("\u{1B}[?47h") }
      vt.feed("\u{1B}8")
      #expect(!vt.state.modes.contains(.origin))
      vt.feed("\u{1B}[?47l\u{1B}8")
      #expect(
        TestFixture(vt.state.modes.contains(.origin))
          == TestFixture(reset == "\u{1B}[!p")
      )
    }
  }

  @Test
  func `resetting the cursor color schedules a redraw`() {
    let session = TerminalSession(columns: 10, rows: 2)
    let updates = Mutex(0)
    session.onUpdate = { updates.withLock { $0 += 1 } }
    let original = session.snapshot().palette.cursor
    session.feed(Array("\u{1B}]12;#123456\u{7}".utf8))
    #expect(session.snapshot().palette.cursor == 0x123456)
    let before = updates.withLock { $0 }
    session.feed(Array("\u{1B}]112\u{7}".utf8))
    #expect(updates.withLock { $0 } == before + 1)
    #expect(session.snapshot().palette.cursor == original)
  }

  @Test
  func `cursor changes schedule updates`() {
    let session = TerminalSession(columns: 10, rows: 6)
    let updates = Mutex(0)
    session.onUpdate = { updates.withLock { $0 += 1 } }
    _ = session.snapshot()
    for sequence in ["\u{1B}[5;6H", "\u{1B}[?25l", "\u{1B}[6 q", "\u{1B}[?12h"]
    {
      let before = updates.withLock { $0 }
      session.feed(Array(sequence.utf8))
      #expect(updates.withLock { $0 } == before + 1)
      #expect(session.snapshot().damage.isEmpty)
    }
    let before = updates.withLock { $0 }
    session.feed(Array("\u{1B}[5;6H".utf8))
    #expect(updates.withLock { $0 } == before)
    session.feed(Array("\u{1B}[?2026h\u{1B}[1;1H".utf8))
    #expect(updates.withLock { $0 } == before)
    #expect(session.snapshot().cursor.x == 5)
    session.feed(Array("\u{1B}[?2026l".utf8))
    #expect(updates.withLock { $0 } == before + 1)
    #expect(session.snapshot().cursor.x == 0)
  }

  @Test
  func `keyboard stacks follow screens`() {
    var vt = VT(10, 2)
    vt.feed("\u{1B}[>1u\u{1B}[?1049h")
    #expect(vt.state.keyboardFlags == 0)
    vt.feed("\u{1B}[>8u\u{1B}[?1049l")
    #expect(vt.state.keyboardFlags == 1)
    vt.feed("\u{1B}[?1049h")
    #expect(vt.state.keyboardFlags == 8)
    vt.feed("\u{1B}[<u")
    #expect(vt.state.keyboardFlags == 0)
    vt.feed("\u{1B}c\u{1B}[?1049h")
    #expect(vt.state.keyboardFlags == 0)
  }

  @Test
  func `super keys use kitty encoding`() {
    for (action, flags, expected) in [
      (KeyEvent.Action.press, UInt8(1), "\u{1B}[97;9u"),
      (.release, 3, "\u{1B}[97;9:3u"),
    ] {
      var bytes: [UInt8] = []
      #expect(
        TestFixture(
          InputEncoder.encode(
            .key(
              KeyEvent(.character("a"), modifiers: .command, action: action)
            ),
            modes: .initial,
            keyboardFlags: flags,
            into: &bytes,
          )
        ) == TestFixture(true)
      )
      #expect(
        TestFixture(String(decoding: bytes, as: UTF8.self))
          == TestFixture(expected)
      )
    }
  }

  @Test
  func `empty booleans restore defaults`() {
    var config = Configuration.parse(
      "copy-on-select = true\nmouse-hide-while-typing = true\nlink-url = false\ncursor-click-to-move = false"
    )
    config.apply(
      "copy-on-select =\nmouse-hide-while-typing =\nlink-url =\ncursor-click-to-move ="
    )
    let defaults = Configuration()
    #expect(config.copyOnSelect == defaults.copyOnSelect)
    #expect(config.mouseHideWhileTyping == defaults.mouseHideWhileTyping)
    #expect(config.linkURL == defaults.linkURL)
    #expect(config.cursorClickToMove == defaults.cursorClickToMove)
  }

  @Test
  func `tilde includes resolve from files`() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let include = dir.appendingPathComponent("shared")
    try "font-size = 19".write(to: include, atomically: true, encoding: .utf8)
    let parents = String(
      repeating: "/..",
      count: FileManager.default.homeDirectoryForCurrentUser.pathComponents
        .count - 1
    )
    let path = "~" + parents + include.path
    for prefix in ["", "?"] {
      let url = dir.appendingPathComponent("config")
      try "config-file = \(prefix)\(path)"
        .write(to: url, atomically: true, encoding: .utf8)
      let config = Configuration.load(from: url)
      #expect(config.diagnostics.isEmpty)
      #expect(config.fontSize == 19)
    }
  }

  @Test
  func `dumps preserve underlines`() {
    var vt = VT(20, 2)
    vt.feed(
      "\u{1B}[4:3;58:2::255:0:0mA\u{1B}[4:4;58;5;123mB\u{1B}[4:5;59mC\u{1B}[4:2mD\u{1B}[4mE\u{1B}[0mF"
    )
    var copy = VT(20, 2)
    copy.feed(bytes: vt.state.dumpPrimaryANSI())
    for x in 0 ..< 6 {
      let original = vt.state.grid[x, 0].attributes
      let restored = copy.state.grid[x, 0].attributes
      #expect(original.flags == restored.flags)
      #expect(
        vt.state.underlineColor(original.underlineColor)
          == copy.state.underlineColor(restored.underlineColor)
      )
    }
  }
}
