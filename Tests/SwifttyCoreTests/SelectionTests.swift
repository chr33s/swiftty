@testable import SwifttyCore
import Testing
import TestSupport

struct SelectionTests {
  @Test(arguments: [0, 1, 4], [0, 10_000_000])
  func `clearing below a kept cursor line severs its discarded soft wrap`(
    _ oldLines: Int,
    _ scrollback: Int
  ) {
    var vt = VT(4, 3, scrollback: scrollback)
    vt.feed(String(repeating: "old\r\n", count: oldLines) + "\u{1B}[31mABCDx")
    let kept = vt.cursor.y - 1
    let wrapped = vt.state.grid.isWrapped(kept)
    #expect(wrapped)
    let cells = Array(vt.state.grid._unsafeCells(row: kept))
    vt.feed("\u{1B}[\(kept + 1);1H")
    vt.state.clearScreenKeepingCursorLine()
    #expect(Array(vt.state.grid._unsafeCells(row: 0)) == cells)
    #expect(TestFixture(vt.lines) == TestFixture(["ABCD", "", ""]))
    #expect(vt.state.scrollbackCount == 0)
    let keptWrapped = vt.state.grid.isWrapped(0)
    #expect(!keptWrapped)
    // New text on the next physical row is a separate logical line.
    vt.feed("\u{1B}[2;1Hx")
    vt.state.search("ABCDx")
    #expect(vt.state.searchMatches.isEmpty)
    vt.state.setSelection(
      Selection(
        anchor: TerminalPoint(row: 0, column: 0),
        head: TerminalPoint(row: 1, column: 0)
      )
    )
    #expect(TestFixture(vt.state.selectionText) == TestFixture("ABCD\nx"))
  }

  @Test(
    arguments: [
      "é", "éé", "漢", "é漢", "漢é", "aé", "漢字한국어日本語", "漢字한국어日本語\u{301}",
    ],
    [(false, 10), (true, 10), (false, 32), (true, 32)],
  )
  func `batched scalar selection invalidation matches single scalar writes`(
    _ text: String,
    _ layout: (Bool, Int)
  ) {
    let (rectangle, columns) = layout
    for column in 0 ..< columns {
      for selectedColumn in 0 ..< columns {
        var actual = VT(columns, 3)
        var reference = VT(columns, 3)
        let initial = "ab漢c漢def\u{1B}[1;\(column + 1)H"
        actual.feed(initial)
        reference.feed(initial)
        let selection = Selection(
          anchor: TerminalPoint(row: 0, column: selectedColumn),
          head: TerminalPoint(row: 1, column: selectedColumn),
          rectangle: rectangle,
        )
        actual.state.setSelection(selection)
        reference.state.setSelection(selection)
        actual.feed(text)
        for scalar in text.unicodeScalars {
          reference.state.print(scalar.value)
        }
        #expect(
          actual.state.selection == reference.state.selection,
          Comment(
            rawValue: escapedTestText(
              "column=\(column), selection=\(selectedColumn)"
            )
          ),
        )
        #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
      }
    }
  }

  @Test(arguments: [0, 1, 3], [false, true])
  func `screen row conversion saturates independently of the viewport`(
    _ offset: Int,
    _ alternate: Bool
  ) {
    var vt = VT(4, 2)
    vt.feed("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4")
    vt.state.scrollViewport(by: offset)
    if alternate { vt.feed("\u{1B}[?1049h") }
    let top = alternate ? 0 : 3
    #expect(vt.state.screenAbsoluteRow(.max) == .max)
    #expect(vt.state.screenAbsoluteRow(.min) == Int.min + top)
    #expect(vt.state.screenAbsoluteRow(-1) == top - 1)
    #expect(vt.state.screenAbsoluteRow(0) == top)
    #expect(vt.state.screenAbsoluteRow(1) == top + 1)
  }

  @Test(
    arguments: ["X", "0K", "2K", "?0K", "?2K", "0J", "?0J"],
    [false, true]
  )
  func
    `protected wrap spacers retain their attributes and selection during erasure`(
      _ erase: String,
      _ iso: Bool
    )
  {
    var vt = VT(4, 3)
    let protect = iso ? "\u{1B}V" : "\u{1B}[1\"q"
    let unprotect = iso ? "\u{1B}W" : "\u{1B}[0\"q"
    vt.feed("abc\u{1B}[44m\(protect)漢\(unprotect)\u{1B}[0m")
    #expect(vt.cell(3, 0).flags.contains(.spacerHead))
    let point = TerminalPoint(row: 0, column: 3)
    vt.state.setSelection(Selection(anchor: point, head: point))
    var retainedAttributes = vt.cell(3, 0).attributes
    retainedAttributes.flags.remove(.spacerHead)
    vt.feed("\u{1B}[1;4H\u{1B}[\(erase)")
    let retainsProtection = iso || erase.hasPrefix("?")
    #expect(
      vt.cell(3, 0).attributes
        == (retainsProtection ? retainedAttributes : Cell.blank.attributes)
    )
    #expect((vt.state.selection != nil) == retainsProtection)
    #expect(!vt.cell(3, 0).flags.contains(.spacerHead))
    let wrapped = vt.state.grid.isWrapped(0)
    #expect(!wrapped)
  }

  @Test(arguments: [(1, 1), (1, 3), (2, 1), (2, 3)], [false, true])
  func `ECH respects ISO protection across wide cell boundaries`(
    _ request: (Int, Int),
    _ iso: Bool
  ) {
    let (column, count) = request
    var vt = VT(8, 2)
    let protect = iso ? "\u{1B}V" : "\u{1B}[1\"q"
    let unprotect = iso ? "\u{1B}W" : "\u{1B}[0\"q"
    vt.feed("a\(protect)漢\(unprotect)bc")
    vt.state.setSelection(
      Selection(
        anchor: TerminalPoint(row: 0, column: 1),
        head: TerminalPoint(row: 0, column: 2),
      )
    )
    vt.feed("\u{1B}[1;\(column + 1)H\u{1B}[\(count)X")
    #expect(vt.cell(0, 0).glyph == 0x61)
    #expect(vt.cell(1, 0).glyph == (iso ? 0x6F22 : 0))
    #expect(vt.cell(2, 0).width == (iso ? 0 : 1))
    #expect(vt.cell(3, 0).glyph == (count == 1 ? 0x62 : 0))
    #expect(vt.cell(4, 0).glyph == (column + count > 4 ? 0 : 0x63))
    #expect(vt.state.selectionText == (iso ? "漢" : nil))
    #expect(vt.state.cursor.x == column)
  }

  @Test(arguments: ["é漢a", "é©️z", "é\u{D4E}®"], [0, 1, 8])
  func `unicode batches preserve selection behavior while splitting wide cells`(
    _ text: String,
    _ selectedColumn: Int
  ) {
    var batched = VT(10, 3)
    var bytewise = VT(10, 3)
    func prepare(_ vt: inout VT) {
      vt.feed("漢abcd\u{1B}[1;2H")
      let point = TerminalPoint(row: 0, column: selectedColumn)
      vt.state.setSelection(Selection(anchor: point, head: point))
    }
    prepare(&batched)
    prepare(&bytewise)
    batched.feed(text)
    for byte in text.utf8 { bytewise.feed(bytes: [byte]) }
    #expect(TestFixture(batched.lines) == TestFixture(bytewise.lines))
    #expect(batched.state.cursor == bytewise.state.cursor)
    #expect(batched.state.selection == bytewise.state.selection)
    #expect((batched.state.selection != nil) == (selectedColumn == 8))
  }

  @Test(arguments: [0, 3])
  func `width changes track a selected search occurrence in retained history`(
    _ oldLines: Int
  ) {
    var state = TerminalState(columns: 4, rows: 2, scrollbackLimitRows: 5)
    var parser = Parser()
    let bytes = Array(
      (String(repeating: "old\r\n", count: oldLines) + "foo0 foo1 foo2 foo3")
        .utf8
    )
    parser.consume(bytes.span, into: &state)
    state.search("foo")
    state.selectSearchMatch(forward: true)
    state.selectSearchMatch(forward: true)
    #expect(state.searchMatches.count == 4)
    #expect(state.searchMatches[1].start.row < state.screenAbsoluteRow(0))
    state.resize(columns: 24, rows: 2)
    #expect(state.searchMatches.count == 4)
    #expect(state.searchSelected == 1)
    let selected = state.searchSelected.map { state.searchMatches[$0] }
    #expect(selected?.start.column == 5 && selected?.end.column == 7)
  }

  @Test
  func `searching unused blank rows does not change resized terminal content`()
  {
    var searched = VT(10, 3)
    var plain = VT(10, 3)
    searched.feed("x")
    plain.feed("x")
    searched.state.search(" ")
    searched.state.selectSearchMatch(forward: false)
    searched.state.resize(columns: 5, rows: 2)
    plain.state.resize(columns: 5, rows: 2)
    #expect(TestFixture(searched.lines) == TestFixture(plain.lines))
    #expect(searched.cursor == plain.cursor)
    #expect(searched.state.scrollbackCount == plain.state.scrollbackCount)
  }

  @Test(
    arguments: [
      (20, "foo0 foo1 foo2 foo3", "foo"), (4, "foo0 foo1 foo2 foo3", "foo"),
      (24, "foo漢 foo漢 foo漢 foo漢", "foo漢"), (4, "foo漢 foo漢 foo漢 foo漢", "foo漢"),
    ],
    [1, 3]
  )
  func `width changes preserve the selected search occurrence through reflow`(
    _ sample: (Int, String, String),
    _ selectedIndex: Int
  ) {
    var vt = VT(sample.0, 8)
    vt.feed(sample.1)
    vt.state.search(sample.2)
    for _ in 0 ... selectedIndex { vt.state.selectSearchMatch(forward: true) }
    #expect(vt.state.searchSelected == selectedIndex)
    vt.state.resize(columns: sample.0 == 4 ? 24 : 4, rows: 8)
    #expect(vt.state.searchMatches.count == 4)
    #expect(vt.state.searchSelected == selectedIndex)
  }

  @Test(arguments: [
    "resize", "reset", "clear", "erase", "history", "alternate", "restore",
  ])
  func
    `addressing generations reject coordinates reused by layout and screen changes`(
      _ operation: String
    )
  {
    var vt = VT(10, 2)
    vt.feed("old\r\nline\r\ntext")
    if operation == "restore" { vt.feed("\u{1B}[?1049h") }
    let generation = vt.state.addressingGeneration
    vt.feed("x")
    vt.state.scrollViewport(by: 1)
    vt.state.resize(columns: 10, rows: 2)
    #expect(vt.state.addressingGeneration == generation)
    switch operation {
    case "resize": vt.state.resize(columns: 10, rows: 3)
    case "reset": vt.state.reset()
    case "clear": vt.state.clearScreenKeepingCursorLine()
    case "erase": vt.feed("\u{1B}[2J")
    case "history": vt.feed("\u{1B}[3J")
    case "alternate": vt.feed("\u{1B}[?1049h")
    default: vt.feed("\u{1B}[?1049l")
    }
    #expect(vt.state.addressingGeneration != generation)
  }

  @Test(arguments: [0, 1, 4], [0, 10_000_000])
  func
    `clearing earlier output preserves the selected search occurrence on the cursor line`(
      _ oldLines: Int,
      _ scrollback: Int
    )
  {
    var vt = VT(20, 2, scrollback: scrollback)
    vt.feed(String(repeating: "old\r\n", count: oldLines) + "foo foo foo")
    vt.state.search("foo")
    vt.state.selectSearchMatch(forward: true)
    #expect(vt.state.searchSelected == 0)
    vt.state.clearScreenKeepingCursorLine()
    vt.state.refreshSearch()
    #expect(TestFixture(vt.lines[0]) == TestFixture("foo foo foo"))
    #expect(vt.state.searchMatches.count == 3)
    let selected = vt.state.searchSelected.map { vt.state.searchMatches[$0] }
    #expect(
      selected
        == TerminalRange(
          start: TerminalPoint(row: 0, column: 0),
          end: TerminalPoint(row: 0, column: 2)
        )
    )
  }

  @Test(arguments: [1, 3])
  func
    `height changes preserve the selected search occurrence after history eviction`(
      _ newRows: Int
    )
  {
    var state = TerminalState(columns: 10, rows: 2, scrollbackLimitRows: 1)
    var parser = Parser()
    let bytes = Array("old\r\nfoo1\r\nfoo2\r\nfoo3".utf8)
    parser.consume(bytes.span, into: &state)
    #expect(state.firstAbsoluteRow == 1)
    state.search("foo")
    state.selectSearchMatch(forward: true)
    state.selectSearchMatch(forward: true)
    let before = state.searchSelected.map { state.searchMatches[$0] }
    #expect(before?.start.row == 2)
    state.resize(columns: 10, rows: newRows)
    let after = state.searchSelected.map { state.searchMatches[$0] }
    #expect(after?.start.row == 1)
    #expect(after?.end == TerminalPoint(row: 1, column: 2))
  }

  @Test(arguments: [false, true])
  func `viewport points clamp to visible cells even at integer limits`(
    _ alternate: Bool
  ) {
    var vt = VT(4, 2)
    vt.feed("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4")
    vt.state.scrollViewport(by: 1)
    if alternate { vt.feed("\u{1B}[?1049h") }
    let top = alternate ? 0 : 2
    #expect(
      vt.state.viewportPoint(row: .min, column: .max)
        == TerminalPoint(row: top, column: 3)
    )
    #expect(
      vt.state.viewportPoint(row: .max, column: .min)
        == TerminalPoint(row: top + 1, column: 0)
    )
    #expect(
      vt.state.viewportPoint(row: 0, column: 2)
        == TerminalPoint(row: top, column: 2)
    )
    #expect(
      vt.state.viewportPoint(row: 1, column: 1)
        == TerminalPoint(row: top + 1, column: 1)
    )
  }

  @Test(arguments: [
    ("ς", "σ", 0), ("ß", "ss", 0), ("ss", "ß", 1), ("ﬃ", "ffi", 0),
    ("ffi", "ﬃ", 2), ("ß", "s", 0),
  ])
  func
    `case insensitive search uses Unicode case folding without duplicate cell ranges`(
      _ sample: (String, String, Int)
    )
  {
    var vt = VT(8, 2)
    vt.feed(sample.0)
    vt.state.search(sample.1)
    #expect(
      vt.state.searchMatches == [
        TerminalRange(
          start: TerminalPoint(row: 0, column: 0),
          end: TerminalPoint(row: 0, column: sample.2)
        )
      ]
    )
  }

  @Test
  func `unicode folding keeps overlapping search positions across wraps`() {
    var vt = VT(2, 2)
    vt.feed("sßs")
    vt.state.search("sss")
    #expect(
      vt.state.searchMatches == [
        TerminalRange(
          start: TerminalPoint(row: 0, column: 0),
          end: TerminalPoint(row: 0, column: 1)
        ),
        TerminalRange(
          start: TerminalPoint(row: 0, column: 1),
          end: TerminalPoint(row: 1, column: 0)
        ),
      ]
    )
    vt.state.search("SSS")
    #expect(vt.state.searchMatches.isEmpty)
  }

  @Test
  func
    `narrowing a grapheme updates search ranges and clears its selected tail`()
  {
    var vt = VT(6, 3)
    vt.feed("⌚")
    #expect(vt.cell(0, 0).width == 2)
    vt.state.search("⌚")
    let tail = TerminalPoint(row: 0, column: 1)
    vt.state.setSelection(Selection(anchor: tail, head: tail))
    vt.feed("\u{FE0E}")
    #expect(vt.cell(0, 0).width == 1)
    #expect(vt.state.selection == nil)
    #expect(
      vt.state.searchMatches.first?.end == TerminalPoint(row: 0, column: 0)
    )
  }

  @Test(
    arguments: [
      "\u{1B}[1;1Hx", "\u{1B}[1;1H新", "\u{301}", "\u{1B}[3;1H\n",
      "\u{1B}[1;6H\u{1B}[K", "\u{1B}[2J", "\u{1B}[2;1H\u{1B}[L",
      "\u{1B}[2;1H\u{1B}[M", "\u{1B}[1;2H\u{1B}[P", "\u{1B}[1;2H\u{1B}[@",
      "\u{1B}[X", "\u{1B}[S", "\u{1B}[T", "\u{1B}[?1049h", "\u{1B}#8",
      "\u{1B}c",
    ]
    .map(TestFixture.init),
    ["foo", "foofoo", "E", "新"].map(TestFixture.init)
  )
  func `active search stays consistent across text editing commands`(
    _ edit: TestFixture<String>,
    _ query: TestFixture<String>
  ) {
    let edit = edit.value
    let query = query.value
    var vt = VT(6, 3)
    vt.feed("foofoofoo\r\nfoo")
    vt.state.search(query)
    vt.feed(edit)
    let matches = vt.state.searchMatches
    vt.state.search(query)
    #expect(matches == vt.state.searchMatches)
  }

  @Test
  func `screen alignment clears selections on replaced text`() {
    var vt = VT(6, 3)
    vt.feed("foo")
    let point = TerminalPoint(row: 0, column: 0)
    vt.state.setSelection(Selection(anchor: point, head: point))
    vt.feed("\u{1B}#8")
    #expect(vt.state.selection == nil)
    #expect(
      TestFixture(vt.lines) == TestFixture(["EEEEEE", "EEEEEE", "EEEEEE"])
    )
  }

  @Test
  func `row addressing remains safe outside available history`() {
    var configuration = SessionConfiguration()
    configuration.scrollbackLimitRows = 1
    let session = TerminalSession(
      columns: 4,
      rows: 2,
      configuration: configuration
    )
    session.feed(Array("1\r\n2\r\n3\r\n4\r\n5".utf8))
    session.withState { state in
      #expect(state.firstAbsoluteRow > 0)
      #expect(state.line(absoluteRow: .min) == nil)
      #expect(state.line(absoluteRow: .max) == nil)
      #expect(state.viewportRow(absoluteRow: .min) == .min)
      #expect(state.absoluteRow(viewportRow: .max) == .max)
    }
    session.mutate { $0.scrollToShow(row: .min) }
    #expect(session.withState { $0.viewportOffset } == 1)
    session.mutate { $0.scrollToShow(row: .max) }
    #expect(session.withState { $0.viewportOffset } == 0)
  }

  @Test(
    arguments: [
      "\u{1B}[1;4HZ", "\u{1B}[1;4H漢", "\u{1B}[1;5H\u{301}",
      "\u{1B}[1;4H\u{1B}[X", "\u{1B}[1;2H\u{1B}[K", "\u{1B}[2J",
      "\u{1B}[1;2H\u{1B}[2P", "\u{1B}[1;2H\u{1B}[2@",
    ]
    .map(TestFixture.init)
  )
  func `character changes clear selections on replaced text`(
    _ edit: TestFixture<String>
  ) {
    let edit = edit.value
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("abcdef".utf8))
    let point = TerminalPoint(row: 0, column: 3)
    session.mutate { $0.setSelection(Selection(anchor: point, head: point)) }
    session.feed(Array(edit.utf8))
    #expect(session.withState { $0.selection } == nil)
  }

  @Test
  func `protected and untouched selected cells survive erasure and printing`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("\u{1B}[1\"qabc\u{1B}[0\"qdef".utf8))
    let point = TerminalPoint(row: 0, column: 1)
    session.mutate { $0.setSelection(Selection(anchor: point, head: point)) }
    session.feed(Array("\u{1B}[?2J\u{1B}[1;5HZ".utf8))
    #expect(session.withState { $0.selectionText } == "b")
  }

  @Test(arguments: [false, true])
  func `horizontal margin scrolling preserves outside column selections`(
    _ alternate: Bool
  ) {
    let session = TerminalSession(columns: 10, rows: 4)
    session.feed(
      Array(
        ((alternate ? "\u{1B}[?1049h" : "")
          + "aMIDz\r\naMIDz\r\naMIDz\r\naMIDz\u{1B}[?69h\u{1B}[2;4s\u{1B}[2;4r\u{1B}[4;2H")
          .utf8
      )
    )
    let outside = TerminalPoint(row: 1, column: 0)
    session.mutate {
      $0.setSelection(Selection(anchor: outside, head: outside))
    }
    session.feed([0x0A])
    #expect(session.withState { $0.selectionText } == "a")
    let inside = TerminalPoint(row: 1, column: 2)
    session.mutate { $0.setSelection(Selection(anchor: inside, head: inside)) }
    session.feed([0x0A])
    #expect(session.withState { $0.selection } == nil)
  }

  @Test(arguments: [false, true])
  func `line edits clear selections on moved content`(_ alternate: Bool) {
    var edits = [
      "\u{1B}[2;1H\u{1B}[M", "\u{1B}[2;1H\u{1B}[L", "\u{1B}[2;4r\u{1B}[4;1H\n",
      "\u{1B}[2;4r\u{1B}[2;1H\u{1B}M",
    ]
    if alternate { edits.append("\u{1B}[4;1H\n") }
    for edit in edits {
      let session = TerminalSession(columns: 10, rows: 4)
      session.feed(
        Array(
          ((alternate ? "\u{1B}[?1049h" : "") + "alpha\r\nbeta\r\ngamma\r\ntail")
            .utf8
        )
      )
      session.mutate {
        $0.setSelection(
          Selection(
            anchor: TerminalPoint(row: 1, column: 0),
            head: TerminalPoint(row: 1, column: 3)
          )
        )
      }
      #expect(session.withState { $0.selectionText } == "beta")
      session.feed(Array(edit.utf8))
      #expect(session.withState { $0.selection } == nil)
    }
  }

  @Test(arguments: [false, true])
  func `region scrolling preserves selections on untouched rows`(
    _ alternate: Bool
  ) {
    let session = TerminalSession(columns: 10, rows: 4)
    session.feed(
      Array(
        ((alternate ? "\u{1B}[?1049h" : "")
          + "alpha\r\nbeta\r\ngamma\r\ntail\u{1B}[2;4r\u{1B}[4;1H")
          .utf8
      )
    )
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 4)
        )
      )
    }
    session.feed([0x0A])
    #expect(session.withState { $0.selectionText } == "alpha")
  }

  @Test(arguments: [0, 10])
  func `selections below a scrolling region stay on stationary text`(
    _ historyLimit: Int
  ) {
    var config = SessionConfiguration()
    config.scrollbackLimitRows = historyLimit
    let session = TerminalSession(columns: 10, rows: 4, configuration: config)
    session.feed(
      Array("alpha\r\nbeta\r\ngamma\r\ntail\u{1B}[1;3r\u{1B}[3;1H".utf8)
    )
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 3, column: 0),
          head: TerminalPoint(row: 3, column: 3)
        )
      )
    }
    session.feed([0x0A])
    #expect(session.withState { $0.selectionText } == "tail")
    #expect(session.withState { $0.selection?.start.row } == 4)
  }

  @Test
  func `a selection across a history scrolling boundary is cleared`() {
    let session = TerminalSession(columns: 10, rows: 4)
    session.feed(
      Array("alpha\r\nbeta\r\ngamma\r\ntail\u{1B}[1;3r\u{1B}[3;1H".utf8)
    )
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 2, column: 0),
          head: TerminalPoint(row: 3, column: 3)
        )
      )
    }
    #expect(
      TestFixture(session.withState { $0.selectionText })
        == TestFixture("gamma\ntail")
    )
    session.feed([0x0A])
    #expect(session.withState { $0.selection } == nil)
  }

  @Test(arguments: [0, 1])
  func `evicted selections do not copy replacement history`(_ historyLimit: Int)
  {
    var config = SessionConfiguration()
    config.scrollbackLimitRows = historyLimit
    let session = TerminalSession(columns: 10, rows: 2, configuration: config)
    session.feed(Array("alpha\r\nbravo".utf8))
    session.mutate {
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 4)
        )
      )
    }
    #expect(session.withState { $0.selectionText } == "alpha")
    session.feed(Array("\r\ncharlie\r\ndelta".utf8))
    #expect(session.withState { $0.selectionText } == nil)
    #expect(session.withState { $0.selection } == nil)
  }

  @Test(arguments: [false, true])
  func `partly evicted selections retain the correct surviving columns`(
    _ rectangle: Bool
  ) {
    for transition in ["output", "resize"] {
      var config = SessionConfiguration()
      config.scrollbackLimitRows = 1
      let session = TerminalSession(columns: 10, rows: 2, configuration: config)
      session.feed(Array("alpha\r\nbravo\r\ncharlie".utf8))
      session.mutate {
        $0.setSelection(
          Selection(
            anchor: TerminalPoint(row: 0, column: 2),
            head: TerminalPoint(row: 1, column: 4),
            rectangle: rectangle,
          )
        )
      }
      if transition == "output" {
        session.feed(Array("\r\ndelta".utf8))
      } else {
        session.resize(columns: 10, rows: 1)
      }
      #expect(
        session.withState { $0.selectionText } == (rectangle ? "avo" : "bravo")
      )
    }
  }

  @Test(arguments: [false, true])
  func `trimming selection blanks preserves spaces inside graphemes`(
    _ rectangle: Bool
  ) {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("a\u{600}  ".utf8))
    let text = session.snapshot().text[0]
    #expect(text == "a\u{600} ")
    let copied = session.withState {
      $0.text(
        from: TerminalPoint(row: 0, column: 0),
        to: TerminalPoint(row: 0, column: 9),
        rectangle: rectangle
      )
    }
    #expect(copied == text)
  }

  @Test(arguments: [false, true])
  func `selecting a wide character tail copies the whole grapheme`(
    _ rectangle: Bool
  ) {
    var vt = VT(10, 2)
    vt.feed("a漢b👩‍💻c")
    let tail = TerminalPoint(row: 0, column: 2)
    #expect(
      TestFixture(vt.state.text(from: tail, to: tail, rectangle: rectangle))
        == TestFixture("漢")
    )
    let emojiTail = TerminalPoint(row: 0, column: 5)
    vt.state.setSelection(
      Selection(anchor: tail, head: emojiTail, rectangle: rectangle)
    )
    #expect(vt.state.selectionText == "漢b👩‍💻")
    vt.state.setSelection(
      Selection(anchor: emojiTail, head: tail, rectangle: rectangle)
    )
    #expect(vt.state.selectionText == "漢b👩‍💻")
  }

  @Test(arguments: ["漢", "🙂", "👩‍💻"])
  func `URL lookup maps many preceding links and surrogate pairs`(
    _ ending: String
  ) {
    let prefix = "https://example.com/🙂 "
    let columns = prefix.utf16.count * 4
    var vt = VT(columns, 3)
    let url = "https://example.com/cafe\u{301}/👩‍💻/" + ending
    vt.feed(String(repeating: prefix, count: 2000) + url + " ")
    let start = prefix.utf16.count * 2000
    let point = TerminalPoint(row: start / columns, column: start % columns)
    let link = vt.state.link(at: point)
    #expect(link?.url == url)
    #expect(link?.range.start == point)
    let end = TerminalPoint(row: point.row, column: vt.state.cursor.x - 2)
    #expect(link?.range.end == end)
    #expect(vt.state.link(at: end) == link)
    #expect(
      vt.state.link(at: TerminalPoint(row: 0, column: prefix.utf16.count - 1))
        == nil
    )
  }

  @Test
  func `URL trimming keeps balanced brackets in long wrapped lines`() {
    var vt = VT(64, 3)
    let url = "https://example.com/(a)"
    vt.feed(url + String(repeating: ")", count: 3000) + "...")
    let link = vt.state.link(at: TerminalPoint(row: 0, column: 0))
    #expect(link?.url == url)
    #expect(link?.range.end == TerminalPoint(row: 0, column: url.count - 1))
    let punctuation = vt.state.link(
      at: TerminalPoint(row: 0, column: url.count)
    )
    #expect(punctuation == nil)
  }

  @Test
  func `viewport scrolling clamps extreme deltas`() {
    var vt = VT(4, 2)
    vt.feed("1\r\n2\r\n3\r\n4")
    vt.state.scrollViewport(by: 1)
    vt.state.scrollViewport(by: Int.max)
    #expect(vt.state.viewportOffset == vt.state.grid.historyCount)
    vt.state.scrollViewport(by: Int.min)
    #expect(vt.state.viewportOffset == 0)
    let previous = vt.state.jumpToPrompt(Int.min)
    let next = vt.state.jumpToPrompt(Int.max)
    #expect(!previous && !next)
  }

  @Test
  func `active search follows output and keeps the selected match`() {
    var vt = VT(10, 2)
    vt.feed("foo\r\nfoo")
    vt.state.search("foo")
    vt.state.selectSearchMatch(forward: true)
    let selected = vt.state.searchMatches[0]
    vt.feed("\r\nfoo")
    #expect(vt.state.searchMatches.count == 3)
    #expect(
      vt.state.searchSelected.map { vt.state.searchMatches[$0] } == selected
    )
    vt.feed("\u{1B}[1;1Hbar")
    #expect(vt.state.searchMatches.count == 2)
  }

  @Test
  func `active search finds matches completed by later output`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.feed(Array("foo".utf8))
    session.mutate { $0.search("foobar") }
    #expect(session.withState { $0.searchMatches.isEmpty })
    session.feed(Array("bar".utf8))
    #expect(session.withState { $0.searchMatches.count } == 1)
    #expect(session.snapshot().searchMatches.count == 1)
    session.mutate { $0.endSearch() }
    session.feed(Array("foobar".utf8))
    #expect(session.withState { $0.searchMatches.isEmpty })
  }

  @Test
  func `active search survives reflow and screen switches`() {
    var vt = VT(10, 3)
    vt.feed("foo foo")
    vt.state.search("foo")
    vt.state.resize(columns: 4, rows: 3)
    #expect(vt.state.searchMatches.count == 2)
    vt.feed("\u{1B}[?1049h")
    #expect(vt.state.searchMatches.isEmpty)
    vt.feed("\u{1B}[?1049l")
    #expect(vt.state.searchMatches.count == 2)
  }

  @Test
  func `active search refreshes after a batch resizes and prints`() {
    let session = TerminalSession(columns: 10, rows: 2)
    session.mutate { $0.search("foo") }
    session.mutate {
      $0.resize(columns: 20, rows: 2)
      $0.print(0x66)
      $0.print(0x6F)
      $0.print(0x6F)
    }
    #expect(session.withState { $0.searchMatches.count } == 1)
    session.feed(Array("\u{1B}[?40h\u{1B}[?3hfoo".utf8))
    #expect(session.withState { $0.columns } == 132)
    #expect(session.withState { $0.searchMatches.count } == 1)
  }

  @Test
  func `case insensitive search retains lowercase expansions`() {
    var vt = VT(3, 3)
    vt.feed("İx İx")
    vt.state.search("i\u{307}x")
    #expect(
      vt.state.searchMatches == [
        TerminalRange(
          start: TerminalPoint(row: 0, column: 0),
          end: TerminalPoint(row: 0, column: 1)
        ),
        TerminalRange(
          start: TerminalPoint(row: 1, column: 0),
          end: TerminalPoint(row: 1, column: 1)
        ),
      ]
    )
    vt.state.search("ix")
    #expect(vt.state.searchMatches.isEmpty)
  }

  @Test
  func `search includes overlapping matches across soft wraps`() {
    var vt = VT(3, 3)
    vt.feed("abababa")
    vt.state.search("aba")
    let matches = vt.state.searchMatches
    #expect(
      matches.map(\.start) == [
        TerminalPoint(row: 0, column: 0), TerminalPoint(row: 0, column: 2),
        TerminalPoint(row: 1, column: 1),
      ]
    )
    #expect(
      matches.map(\.end) == [
        TerminalPoint(row: 0, column: 2), TerminalPoint(row: 1, column: 1),
        TerminalPoint(row: 2, column: 0),
      ]
    )
  }

  @Test(arguments: [false, true])
  func `streaming search crosses soft wraps and stops at hard breaks`(
    _ hardBreak: Bool
  ) {
    var vt = VT(4, 3)
    vt.feed(hardBreak ? "abcd\r\nefgh" : "abcdefgh")
    vt.state.search("de")
    let across = TerminalRange(
      start: TerminalPoint(row: 0, column: 3),
      end: TerminalPoint(row: 1, column: 0)
    )
    #expect(vt.state.searchMatches == (hardBreak ? [] : [across]))
    vt.state.search("gh")
    #expect(
      vt.state.searchMatches == [
        TerminalRange(
          start: TerminalPoint(row: 1, column: 2),
          end: TerminalPoint(row: 1, column: 3)
        )
      ]
    )
  }

  @Test
  func
    `streaming search keeps cell positions through overlapping lowercase expansions`()
  {
    var vt = VT(2, 3)
    vt.feed("İİİ")
    vt.state.search("i\u{307}i")
    #expect(
      vt.state.searchMatches == [
        TerminalRange(
          start: TerminalPoint(row: 0, column: 0),
          end: TerminalPoint(row: 0, column: 1)
        ),
        TerminalRange(
          start: TerminalPoint(row: 0, column: 1),
          end: TerminalPoint(row: 1, column: 0)
        ),
      ]
    )
  }

  @Test
  func `search handles long repeated prefixes`() {
    var vt = VT(100, 4)
    let needle = String(repeating: "a", count: 500) + "b"
    vt.feed(String(repeating: "a", count: 5000) + "b")
    vt.state.search(needle)
    let matches = vt.state.searchMatches
    #expect(matches.count == 1)
    #expect(matches.first?.start == TerminalPoint(row: 45, column: 0))
    #expect(matches.first?.end == TerminalPoint(row: 50, column: 0))
  }

  @Test
  func `rectangular text clamps columns`() {
    var vt = VT(5, 2)
    vt.feed("abcde\r\nfghij")
    for (left, right, expected) in [
      (-10, 10, "abcde\nfghij"), (8, 10, "e\nj"), (-10, -2, "a\nf"),
    ] {
      let a = TerminalPoint(row: 0, column: left)
      let b = TerminalPoint(row: 1, column: right)
      #expect(
        TestFixture(vt.state.text(from: a, to: b, rectangle: true))
          == TestFixture(expected)
      )
      #expect(
        TestFixture(vt.state.text(from: b, to: a, rectangle: true))
          == TestFixture(expected)
      )
    }
  }

  @Test
  func `detected URLs retain grapheme scalars and wide endpoints`() {
    var vt = VT(20, 4)
    let url = "https://example.com/cafe\u{301}/漢"
    vt.feed("🙂 " + url + " ")
    let link = vt.state.link(at: TerminalPoint(row: 1, column: 8))
    #expect(link?.url == url)
    #expect(link?.range.start == TerminalPoint(row: 0, column: 3))
    #expect(link?.range.end == TerminalPoint(row: 1, column: 9))
  }

  @Test
  func `text across wraps and lines`() {
    var vt = VT(5, 3)
    vt.feed("abcdefg\r\nxy")
    let a = vt.state.absoluteRow(viewportRow: 0)
    let text = vt.state.text(
      from: TerminalPoint(row: a, column: 0),
      to: TerminalPoint(row: a + 2, column: 4)
    )
    #expect(TestFixture(text) == TestFixture("abcdefg\nxy"))
  }

  @Test
  func `points stay pinned while scrolling`() {
    var vt = VT(5, 2)
    vt.feed("one\r\ntwo")
    let row = vt.state.absoluteRow(viewportRow: 0)
    vt.state.setSelection(
      Selection(
        anchor: TerminalPoint(row: row, column: 0),
        head: TerminalPoint(row: row, column: 2)
      )
    )
    vt.feed("\r\nthree\r\nfour")
    let text = vt.state.selectionText
    #expect(text == "one")
  }

  @Test(arguments: [3, 5, 7])
  func `word ranges cross wide character wrap padding`(_ columns: Int) {
    var vt = VT(columns, 5)
    let word = "中文中文中文"
    vt.feed(word + " ")
    for column in 0 ..< columns {
      let range = vt.state.wordRange(at: TerminalPoint(row: 0, column: column))
      #expect(
        TestFixture(vt.state.text(from: range.start, to: range.end))
          == TestFixture(word)
      )
    }
  }

  @Test
  func `word and line ranges`() {
    var vt = VT(20, 2)
    vt.feed("ls /usr/bin; echo")
    let row = vt.state.absoluteRow(viewportRow: 0)
    let word = vt.state.wordRange(at: TerminalPoint(row: row, column: 5))
    #expect(word.start.column == 3 && word.end.column == 10)
    let line = vt.state.lineRange(at: TerminalPoint(row: row, column: 5))
    #expect(line.start.column == 0 && line.end.column == 19)
  }

  @Test
  func `search finds matches across history`() {
    var vt = VT(10, 2)
    vt.feed("foo bar\r\nbaz\r\nFoo\r\nx")
    vt.state.search("foo")
    let count = vt.state.searchMatches.count
    #expect(count == 2)
    let selected = vt.state.selectSearchMatch(forward: false)
    #expect(selected == 1)
  }

  @Test
  func `alternate screen clears selection`() {
    var vt = VT(10, 2)
    vt.feed("hi")
    vt.state.setSelection(
      Selection(
        anchor: TerminalPoint(row: 0, column: 0),
        head: TerminalPoint(row: 0, column: 1)
      )
    )
    vt.feed("\(CSI)?1049h")
    let cleared = vt.state.selection == nil
    #expect(cleared)
  }
}

struct DumpTests {
  @Test
  func `dump round trips`() {
    var vt = VT(6, 3)
    vt.feed("\(CSI)1;31mred\(CSI)0m plain\r\nabcdefgh\r\nz")
    let dump = vt.state.dumpPrimaryANSI()
    var copy = VT(6, 3)
    copy.feed(bytes: dump)
    #expect(TestFixture(copy.lines) == TestFixture(vt.lines))
    let a = copy.state.absoluteRow(viewportRow: 0)
    let b = vt.state.absoluteRow(viewportRow: 0)
    #expect(
      TestFixture(
        copy.state.text(
          from: TerminalPoint(row: a - 1, column: 0),
          to: TerminalPoint(row: a + 2, column: 5)
        )
      )
        == TestFixture(
          vt.state.text(
            from: TerminalPoint(row: b - 1, column: 0),
            to: TerminalPoint(row: b + 2, column: 5),
          )
        )
    )
    #expect(
      copy.cell(0, 0).attributes.foreground
        == vt.cell(0, 0).attributes.foreground
    )
  }
}
