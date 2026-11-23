import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Builds a frame from rows of `(text, width, style)` cells, padding each
/// row with blank narrow cells.
private func frame(
  columns: Int,
  rows: [[(String, UInt8, Int)]],
  wrapped: [Bool]? = nil,
  styles: [PresentationFrame.Style] = [.init()],
  cursor: (x: Int, y: Int) = (0, 0),
  title: String = ""
) -> PresentationFrame {
  var cells: [PresentationFrame.Cell] = []
  for row in rows {
    precondition(row.count <= columns)
    for (text, width, style) in row {
      cells.append(.init(text: text, width: width, style: style))
    }
    cells += Array(repeating: .init(), count: columns - row.count)
  }
  return PresentationFrame(
    columns: columns,
    rows: rows.count,
    cells: cells,
    wrapped: wrapped ?? Array(repeating: false, count: rows.count),
    styles: styles,
    cursorX: cursor.x,
    cursorY: cursor.y,
    title: title
  )
}

/// Plain text, one cell per character.
private func textFrame(
  _ lines: [String],
  columns: Int,
  cursor: (x: Int, y: Int) = (0, 0)
) -> PresentationFrame {
  frame(
    columns: columns,
    rows: lines.map { line in line.map { (String($0), 1, 0) } },
    cursor: cursor
  )
}

private func scalars(
  _ snapshot: RenderSnapshot,
  row: Int,
  column: Int
) -> [UInt32] {
  let cell = snapshot.cells(row: row)[column]
  guard cell.isGrapheme else { return [cell.glyph] }
  let span = snapshot.graphemeScalars(cell)
  var result: [UInt32] = []
  for i in 0 ..< span.count { result.append(span[i]) }
  return result
}

struct PresentationTests {
  @Test
  func `installed frames preserve the active buffer across transitions`() {
    let session = TerminalSession(presentationColumns: 8, rows: 2)
    for alternate in [true, false, true, false] {
      var frame = textFrame([alternate ? "alt" : "primary"], columns: 8)
      frame.alternateScreen = alternate
      #expect(session.installPresentation(frame))
      #expect(session.withState { $0.isAlternateScreen } == alternate)
      let snapshot = session.snapshot()
      #expect(snapshot.modes.contains(.alternateScreen) == alternate)
      #expect(snapshot.text == [alternate ? "alt" : "primary"])
      #expect(session.withState { $0.scrollbackCount } == 0)
    }
  }

  static let red: UInt32 = 0xFF0000
  static let green: UInt32 = 0x00FF00
  static let blue: UInt32 = 0x0000FF

  /// Wide characters, a combining mark and a ZWJ emoji sequence, styled,
  /// wrapped and with a bar cursor.
  static let sample = frame(
    columns: 6,
    rows: [
      [("a", 1, 0), ("界", 2, 1), ("", 0, 0), ("e\u{301}", 1, 1), ("x", 1, 0)],
      [("👩‍👩‍👧", 2, 0), ("", 0, 0), ("b", 1, 1)], [],
    ],
    wrapped: [true, false, false],
    styles: [
      .init(),
      .init(
        foreground: red,
        background: green,
        underlineColor: blue,
        flags: [.bold, .underline, .spacerTail]
      ),
    ],
    cursor: (2, 1),
    title: "remote"
  )

  @Test
  func `install renders the frame exactly`() throws {
    var sample = Self.sample
    sample.cursorStyle = .bar
    sample.cursorBlinking = true
    sample.reverseVideo = true
    let session = TerminalSession(presentationColumns: 80, rows: 24)
    #expect(session.isPresentation)
    let events = Mutex<[TerminalEvent]>([])
    session.onEvent = { event in events.withLock { $0.append(event) } }
    #expect(session.installPresentation(sample))
    let snapshot = session.snapshot()
    #expect(snapshot.columns == 6)
    #expect(snapshot.rowCount == 3)
    #expect(snapshot.text == ["a界éx", "👩‍👩‍👧b", ""])
    #expect(snapshot.damage.isFull)

    let row0 = snapshot.cells(row: 0)
    #expect(row0[1].width == 2)
    #expect(row0[2].width == 0 && row0[2].flags.contains(.spacerTail))
    #expect(row0[3].width == 1 && row0[3].isGrapheme)
    #expect(scalars(snapshot, row: 0, column: 3) == [0x65, 0x301])
    let row1 = snapshot.cells(row: 1)
    #expect(row1[0].width == 2 && row1[0].isGrapheme)
    #expect(
      scalars(snapshot, row: 1, column: 0) == "👩‍👩‍👧".unicodeScalars.map(\.value)
    )
    #expect(row1[1].flags.contains(.spacerTail))

    #expect(snapshot.rows[0].isWrapped)
    #expect(!snapshot.rows[1].isWrapped)
    #expect(!snapshot.rows[2].isWrapped)

    #expect(snapshot.cursor.x == 2 && snapshot.cursor.y == 1)
    #expect(snapshot.cursor.isVisible)
    #expect(snapshot.cursor.style == .bar)
    #expect(snapshot.cursor.isBlinking)
    #expect(snapshot.modes.contains(.reverseVideo))

    // Styles resolve to the frame's colors and presentation flags; the
    // structural flag in the style table is ignored.
    let styled = row0[1]
    let palette = snapshot.palette
    #expect(
      palette.resolve(styled.attributes.foreground, isForeground: true)
        == Self.red
    )
    #expect(
      palette.resolve(styled.attributes.background, isForeground: false)
        == Self.green
    )
    #expect(styled.flags.contains([.bold, .underline]))
    #expect(!styled.flags.contains(.spacerTail))
    let underline = Int(styled.attributes.underlineColor)
    #expect(underline > 0)
    #expect(snapshot.underlineColors[underline - 1] == .rgb(0, 0, 0xFF))
    // The continuation takes its lead's pen.
    #expect(row0[2].attributes.background == styled.attributes.background)
    let plain = row0[0]
    #expect(plain.attributes.foreground == .default)
    #expect(plain.attributes.background == .default)
    #expect(session.withState { $0.title } == "remote")
    session.queue.sync {}
    #expect(events.withLock { $0 } == [.title("remote")])
  }

  @Test
  func `repeated installs replace the screen without reflow`() {
    let session = TerminalSession(presentationColumns: 20, rows: 5)
    let frames = [
      textFrame(["0123456789", "abc"], columns: 10, cursor: (9, 1)),
      textFrame(["xy", "z", "w"], columns: 4),
      textFrame(["long line here", "", "", "", "end"], columns: 14),
      textFrame(["long line here", "", "", "", "end"], columns: 14),
      textFrame(["q"], columns: 1),
    ]
    _ = session.snapshot()
    for frame in frames {
      #expect(session.installPresentation(frame))
      let snapshot = session.snapshot()
      #expect(snapshot.columns == frame.columns)
      #expect(snapshot.rowCount == frame.rows)
      let expected = (0 ..< frame.rows)
        .map { y in
          String(
            frame.cells[y * frame.columns ..< (y + 1) * frame.columns]
              .map { $0.text.isEmpty ? " " : $0.text }.joined()
          )
        }
        .map { line in
          var line = line
          while line.last == " " { line.removeLast() }
          return line
        }
      #expect(snapshot.text == expected)
      #expect(snapshot.damage.isFull)
      #expect(snapshot.cursor.x == frame.cursorX)
      #expect(snapshot.cursor.y == frame.cursorY)
      #expect(snapshot.scrollbackCount == 0)
    }
  }

  static let invalid: [(String, TestFixture<PresentationFrame>)] = {
    let base = textFrame(["ab", "cd"], columns: 2)
    func mutated(
      _ body: (inout PresentationFrame) -> Void
    ) -> TestFixture<PresentationFrame> {
      var frame = base
      body(&frame)
      return TestFixture(frame)
    }
    return [
      ("zero columns", mutated { $0.columns = 0 }),
      ("too many cells", mutated { $0.cells.append(.init()) }),
      ("wrap flags", mutated { $0.wrapped = [false] }),
      ("no styles", mutated { $0.styles = [] }),
      ("style index", mutated { $0.cells[1].style = 1 }),
      ("negative style", mutated { $0.cells[1].style = -1 }),
      ("color", mutated { $0.styles[0].foreground = 0x0100_0000 }),
      ("wide at edge", mutated { $0.cells[1] = .init(text: "界", width: 2) }),
      ("orphan continuation", mutated { $0.cells[1].width = 0 }),
      (
        "continuation text",
        mutated {
          $0.cells[0] = .init(text: "界", width: 2)
          $0.cells[1] = .init(text: "x", width: 0)
        }
      ), ("width 3", mutated { $0.cells[0].width = 3 }),
      ("cursor column", mutated { $0.cursorX = 2 }),
      ("cursor row", mutated { $0.cursorY = -1 }),
      ("escape", mutated { $0.cells[0].text = "\u{1B}[2J" }),
      ("C1", mutated { $0.cells[0].text = "\u{9B}" }),
      (
        "grapheme bytes",
        mutated {
          $0.cells[0].text = "e" + String(repeating: "\u{301}", count: 40)
        }
      ), ("title", mutated { $0.title = String(repeating: "t", count: 1025) }),
      (
        "oversized",
        mutated {
          $0.columns = 2000
          $0.rows = 1
          $0.cells = Array(repeating: .init(), count: 2000)
          $0.wrapped = [false]
        }
      ),
    ]
  }()

  @Test(arguments: invalid)
  func `invalid frames are rejected without change`(
    _ name: String,
    _ fixture: TestFixture<PresentationFrame>
  ) {
    #expect(!fixture.value.isValid, "\(name)")
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    #expect(session.installPresentation(Self.sample))
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 2)
        )
      )
    }
    let before = session.snapshot()
    #expect(!session.installPresentation(fixture.value), "\(name)")
    let after = session.snapshot()
    #expect(after.text == before.text)
    #expect(after.columns == 6)
    #expect(after.damage.isEmpty)
    #expect(after.selection != nil)
    #expect(after.cursor == before.cursor)
  }

  @Test
  func `ordinary sessions do not install frames`() {
    let session = TerminalSession(columns: 10, rows: 3)
    #expect(!session.isPresentation)
    session.feed(Array("live".utf8))
    #expect(!session.installPresentation(Self.sample))
    #expect(session.snapshot().text.first == "live")
  }

  @Test
  func `presentation input is semantic and never written`() {
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    let written = Mutex<[[UInt8]]>([])
    let semantic = Mutex<[String]>([])
    let output = Mutex(0)
    session.onWrite = { bytes in written.withLock { $0.append(bytes) } }
    session.onTerminalReply = { bytes in written.withLock { $0.append(bytes) } }
    session.onProgramOutput = { _ in output.withLock { $0 += 1 } }
    session.semanticInputHandler = { input in
      let description =
        switch input {
        case let .text(text): "text:\(text)"
        case let .key(event): "key:\(event.key):\(event.action)"
        case let .paste(text): "paste:\(text)"
        case let .mouse(event): "mouse:\(event.button):\(event.action)"
        case .focus: "focus"
        case .bytes: "bytes"
        }
      semantic.withLock { $0.append(description) }
    }
    session.send(.text("ls"))
    session.send(.key(KeyEvent(.enter)))
    session.send(.key(KeyEvent(.enter, action: .release)))
    session.send(.key(KeyEvent(.up, action: .repeat)))
    session.send(.paste("pasted\n"))
    session.send(.mouse(MouseEvent(.press, .left, column: 1, row: 1)))
    session.send(.mouse(MouseEvent(.press, .wheelUp, column: 1, row: 1)))
    session.send(.mouse(MouseEvent(.release, .wheelUp, column: 1, row: 1)))
    session.send(.focus(true))
    session.send(.bytes([0x1B]))
    // Program output and query replies cannot occur: nothing is parsed.
    session.receive(Array("\u{1B}[6n\u{1B}]52;c;aGk=\u{7}text".utf8))
    session.receive { _ in Array("\u{1B}[c".utf8) }
    session.feed(Array("\u{1B}[5n".utf8))
    session.queue.sync {}
    #expect(
      semantic.withLock { $0 } == [
        "text:ls", "key:enter:press", "key:up:repeat", "paste:pasted\n",
        "mouse:wheelUp:press",
      ]
    )
    #expect(written.withLock { $0 }.isEmpty)
    #expect(output.withLock { $0 } == 0)
    #expect(session.snapshot().text == ["", "", ""])
  }

  @Test
  func `resize only proposes a grid`() {
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    #expect(session.installPresentation(textFrame(["abc"], columns: 4)))
    let proposals = Mutex<[[Int]]>([])
    session.gridProposalHandler = { columns, rows in
      proposals.withLock { $0.append([columns, rows]) }
    }
    session.resize(columns: 100, rows: 30)
    session.resize(columns: 0, rows: -2)
    session.queue.sync {}
    #expect(proposals.withLock { $0 } == [[100, 30], [1, 1]])
    let snapshot = session.snapshot()
    #expect(snapshot.columns == 4)
    #expect(snapshot.rowCount == 1)
    #expect(snapshot.text == ["abc"])
  }

  @Test
  func `selection copies the displayed frame`() {
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    #expect(session.installPresentation(Self.sample))
    let selected = session.mutate { state in
      state.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 1, column: 2)
        )
      )
      return state.selectionText
    }
    // Row 0 is wrapped, so it continues (with its blank last cell)
    // without a newline.
    #expect(selected == "a界éx 👩‍👩‍👧b")
    #expect(session.snapshot().selection != nil)
    let all = session.mutate { state in
      state.selectAll()
      return state.selectionText
    }
    #expect(all?.hasPrefix("a界éx") == true)
    // A new frame invalidates the selection's coordinates.
    #expect(session.installPresentation(Self.sample))
    #expect(session.snapshot().selection == nil)
  }

  @Test
  func `install clears search and has no scrollback`() {
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    #expect(session.installPresentation(textFrame(["abc", "abd"], columns: 5)))
    let matches = session.mutate { state in
      state.search("ab")
      return state.searchMatches.count
    }
    #expect(matches == 2)
    for i in 0 ..< 10 {
      #expect(
        session.installPresentation(textFrame(["line \(i)", "x"], columns: 8))
      )
    }
    session.scrollViewport(by: 5)
    let snapshot = session.snapshot()
    #expect(snapshot.searchMatchCount == 0)
    #expect(snapshot.scrollbackCount == 0)
    #expect(snapshot.viewportOffset == 0)
    #expect(snapshot.text == ["line 9", "x"])
  }

  @Test
  func `installs from a session callback do not deadlock`() {
    let session = TerminalSession(presentationColumns: 10, rows: 3)
    let installed = Mutex(false)
    session.semanticInputHandler = { [weak session] _ in
      let ok =
        session?.installPresentation(textFrame(["typed"], columns: 6)) ?? false
      installed.withLock { $0 = ok }
    }
    session.send(.text("t"))
    session.queue.sync {}
    #expect(installed.withLock { $0 })
    #expect(session.snapshot().text == ["typed"])
  }

  @Test
  func `roaming capabilities gate local features`() {
    let roaming = SurfaceCapabilities.roaming
    #expect(!roaming.allows(.startSearch))
    #expect(!roaming.allows(.scrollPageUp))
    #expect(!roaming.allows(.jumpToPrompt(-1)))
    #expect(roaming.allows(.copyToClipboard))
    #expect(roaming.allows(.pasteFromClipboard))
    #expect(!roaming.allows(.reset, presentation: true))
    #expect(!roaming.allows(.csi("2J"), presentation: true))
    #expect(roaming.allows(.increaseFontSize(1), presentation: true))
    let tv = roaming.withoutClipboard
    #expect(!tv.allows(.copyToClipboard))
    #expect(!tv.allows(.pasteFromClipboard))
    #expect(!tv.remoteClipboardWrites)
    let modes: Modes = [.mouseAny, .mouseSGR, .focusEvents, .cursorVisible]
    #expect(roaming.effectiveModes(modes) == [.mouseSGR, .cursorVisible])
    #expect(SurfaceCapabilities.full.effectiveModes(modes) == modes)
    // Wheel reports still reach a program tracking the mouse: scrolling
    // must not fall back to arrow keys (alternate scroll mode).
    #expect(roaming.wheelReporting)
    #expect(roaming.scrollModes(modes) == modes)
    var noWheel = roaming
    noWheel.wheelReporting = false
    #expect(noWheel.scrollModes(modes) == noWheel.effectiveModes(modes))
    for action: KeyAction in [
      .startSearch, .scrollToTop, .reset, .clearScreen, .copyToClipboard,
    ] { #expect(SurfaceCapabilities.full.allows(action)) }
  }
}
