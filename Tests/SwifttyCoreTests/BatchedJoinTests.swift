@testable import SwifttyEngine
import Testing

/// Byte-at-a-time feeding prints each scalar alone, so it is the reference
/// for joins after batched runs.
struct BatchedJoinTests {
  @Test(arguments: [false, true], [1, 2, 3])
  func `batched joins match one scalar at a time`(
    clustering: Bool,
    seed: UInt64
  ) {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let pieces = [
      "a", "e", "漢", "क", "\u{94D}", "ष", "\u{93F}", "\u{301}", "\u{302}",
      "\u{20DD}", "\u{200D}", "\u{200C}", "👩", "💻", "🏽", "\u{FE0F}", "\u{FE0E}",
      "☺", "🇯", "🇵", "\u{1100}", "\u{1161}", "\u{11A8}", "\u{600}", "\u{903}",
      " ", "\r\n", "\(CSI)H", String(repeating: "\u{300}", count: 70),
      "\(CSI)7G", "\(CSI)4h", "\(CSI)4l",
    ]
    var input = clustering ? "\(CSI)?2027h" : "\(CSI)?2027l"
    for _ in 0 ..< 1500 { input += pieces[next(pieces.count)] }
    input += "\(CSI)3b"
    let bytes = Array(input.utf8)
    var fast = VT(9, 4)
    var reference = VT(9, 4)
    fast.feed(bytes: bytes)
    for b in bytes { reference.feed(bytes: [b]) }
    #expect(fast.cursor == reference.cursor)
    #expect(fast.state.cursor == reference.state.cursor)
    for y in 0 ..< 4 {
      #expect(fast.state.grid.extent(y) == reference.state.grid.extent(y))
      for x in 0 ..< 9 {
        let a = fast.cell(x, y)
        let r = reference.cell(x, y)
        #expect(fast.state.scalars(of: a) == reference.state.scalars(of: r))
        #expect(a.attributes == r.attributes)
        #expect(a.width == r.width)
      }
    }
    #expect(fast.state.scrollbackCount == reference.state.scrollbackCount)
    for i in 0
      ..< min(fast.state.scrollbackCount, reference.state.scrollbackCount)
    {
      #expect(fast.state.scrollbackText(i) == reference.state.scrollbackText(i))
    }
  }

  /// A scalar with no width that joins nothing is dropped: it must not
  /// wrap a full line first. These once did, in batched runs only.
  @Test(arguments: [0, 1])
  func `a dropped scalar at a pending wrap leaves the line unwrapped`(
    _ index: Int
  ) {
    let text = [
      "क\u{93F}ष क\u{903}a👩\u{1161}", "🇵💻💻 \u{1100}\u{200C}\u{1161}",
    ][index]
    let bytes = Array(("\(CSI)?2027h" + text).utf8)
    var fast = VT(9, 4)
    var reference = VT(9, 4)
    fast.feed(bytes: bytes)
    for b in bytes { reference.feed(bytes: [b]) }
    #expect(fast.state.cursor == reference.state.cursor)
    #expect(fast.state.cursor.x == 8)
    #expect(fast.state.cursor.y == 0)
    #expect(fast.state.cursor.pendingWrap)
    let wrappedEarly = fast.state.grid.isWrapped(0)
    #expect(!wrappedEarly)
    for x in 0 ..< 9 {
      #expect(
        fast.state.scalars(of: fast.cell(x, 0))
          == reference.state.scalars(of: reference.cell(x, 0))
      )
    }
    // The next character wraps as usual.
    fast.feed("z")
    reference.feed("z")
    #expect(fast.state.cursor == reference.state.cursor)
    let wrapped = fast.state.grid.isWrapped(0)
    #expect(wrapped)
    #expect(fast.state.scalars(of: fast.cell(0, 1)) == ["z"])
  }

  /// Consecutive Extend marks are appended together; the cluster limit,
  /// selectors and other joiners must still apply one scalar at a time.
  @Test(arguments: [0, 1, 3, 17])
  func `Extend runs match one scalar at a time`(chunk: Int) {
    let marks = String(repeating: "\u{300}\u{301}\u{302}", count: 30)
    let input =
      "\(CSI)?2027h" + "a" + marks + "b\u{301}\u{FE0F}\u{302}"
      + "👍\u{301}\u{200D}💻\u{302}" + "c\u{94D}\u{301}क" + "漢\u{300}\u{301}"
      + "\(CSI)1;9H" + "x\u{300}\u{301}" + "\u{300}\u{301}" + "\r\n"
      + "\u{300}\u{301}z"
    let bytes = Array(input.utf8)
    var fast = VT(9, 3)
    var reference = VT(9, 3)
    if chunk == 0 {
      fast.feed(bytes: bytes)
    } else {
      var i = 0
      while i < bytes.count {
        fast.feed(bytes: Array(bytes[i ..< min(i + chunk, bytes.count)]))
        i += chunk
      }
    }
    for b in bytes { reference.feed(bytes: [b]) }
    #expect(fast.state.cursor == reference.state.cursor)
    for y in 0 ..< 3 {
      for x in 0 ..< 9 {
        let a = fast.cell(x, y)
        let r = reference.cell(x, y)
        #expect(fast.state.scalars(of: a) == reference.state.scalars(of: r))
        #expect(a.width == r.width)
      }
    }
    // Base plus the 64-scalar join limit.
    #expect(
      fast.state.scalars(of: fast.cell(0, 0)).count
        == TerminalState.graphemeMaxLength + 1
    )
  }

  /// Clusters written on blank cells are appended as a group; the cells,
  /// widths, attributes, cursor and REP's last scalar must match printing
  /// one scalar at a time.
  @Test(arguments: [false, true], [1, 2, 3, 4])
  func `clusters on blank cells match one scalar at a time`(
    clustering: Bool,
    seed: UInt64
  ) {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let pieces = [
      "a", "e\u{301}", "漢", "क\u{94D}ष\u{93F}", "o\u{302}\u{323}", "👨\u{200D}👩\u{200D}👧",
      "🏳\u{FE0F}\u{200D}🌈", "👍🏽", "🏽", "🇯🇵", "🇺🇸🇯", "❤\u{FE0F}", "☺\u{FE0E}",
      "😀\u{FE0E}", "⌚\u{FE0E}", "⌚\u{FE0E}\u{200D}💻", "\u{1100}\u{1161}\u{11A8}", "\u{600}é",
      "\u{600}a", "©\u{FE0F}",
      "\u{200D}", "\u{301}", "\u{200B}", "x\u{200C}\u{301}", " ", "ﷺ", "\u{903}",
      "é\u{20DD}", String(repeating: "\u{300}", count: 70), "\(CSI)1m", "\(CSI)0m",
      "\r\n", "\(CSI)2b",
    ]
    var input = clustering ? "\(CSI)?2027h" : "\(CSI)?2027l"
    for _ in 0 ..< 1200 { input += pieces[next(pieces.count)] }
    let bytes = Array(input.utf8)
    var reference = VT(37, 5, scrollback: 0)
    for b in bytes { reference.feed(bytes: [b]) }
    for chunk in [bytes.count, 1, 7, 64] {
      var fast = VT(37, 5, scrollback: 0)
      var i = 0
      while i < bytes.count {
        fast.feed(bytes: Array(bytes[i ..< min(i + chunk, bytes.count)]))
        i += chunk
      }
      #expect(fast.state.cursor == reference.state.cursor)
      #expect(fast.state.lastPrinted == reference.state.lastPrinted)
      for y in 0 ..< 5 {
        #expect(fast.state.grid.extent(y) == reference.state.grid.extent(y))
        for x in 0 ..< 37 {
          let a = fast.cell(x, y)
          let r = reference.cell(x, y)
          #expect(
            fast.state.scalars(of: a) == reference.state.scalars(of: r),
            Comment(rawValue: "chunk=\(chunk) x=\(x) y=\(y)")
          )
          #expect(a.attributes == r.attributes)
          #expect(a.width == r.width)
        }
      }
    }
  }

  /// Width effects inside a cluster written on blank cells: widening,
  /// narrowing, both in turn, ignored selectors, and the row's last
  /// columns. A coloured pen makes every spacer and narrowed cell visible.
  private static let widthEffectClusters = [
    "😀\u{FE0E}", "⌚\u{FE0E}", "⌚\u{FE0E}\r\nz", "⌚\u{FE0E}x", "⌚\u{FE0E}\u{200D}💻",
    "⌚\u{FE0E}\u{200D}💻\u{FE0E}y", "⌚\u{FE0E}\u{FE0F}", "⌚\u{FE0E}\u{301}\u{FE0F}z",
    "❤\u{FE0F}", "❤\u{FE0F}\u{FE0E}", "a\u{FE0F}b", "❤\u{200D}❤\u{FE0E}",
    "❤\u{200D}❤\u{FE0E}\r\nz", "❤\u{200D}❤\u{FE0E}\u{200D}💻q",
    "x\u{200D}\u{FE0F}💻", "👩\u{200D}\u{FE0F}💻", "क\u{94D}ष\u{93F}", "क\u{94D}ष\u{FE0E}",
    "🇯🇵🇺", "\u{600}é\u{301}", "ab\u{200B}c", "漢字漢字漢\u{301}", "漢字漢字漢字漢",
    "e" + String(repeating: "\u{301}", count: 64) + "\u{FE0F}\u{302}\u{200D}",
  ]

  // Indexes, not strings: the test log must stay free of control bytes.
  @Test(arguments: widthEffectClusters.indices)
  func `width effects on blank cells match one scalar at a time`(
    _ index: Int
  ) {
    let cluster = Self.widthEffectClusters[index]
    // U+231A is wide with a text presentation: its selector narrows it.
    #expect(GraphemeBreak.isEmojiVSBase(0x231A))
    #expect(ScalarInfoTable.shared.lookup(0x231A) >> 5 == 2)
    // Every start column, so that each cluster also ends a row.
    for column in 0 ..< 12 {
      let text =
        "\(CSI)?2027h\(CSI)41m" + String(repeating: "é", count: column)
        + cluster + "\(CSI)2b"
      let bytes = Array(text.utf8)
      var fast = VT(12, 3, scrollback: 0)
      var reference = VT(12, 3, scrollback: 0)
      fast.feed(bytes: bytes)
      for b in bytes { reference.feed(bytes: [b]) }
      let context = Comment(rawValue: "column=\(column)")
      #expect(fast.state.cursor == reference.state.cursor, context)
      #expect(fast.state.lastPrinted == reference.state.lastPrinted, context)
      for y in 0 ..< 3 {
        #expect(
          fast.state.grid.extent(y) == reference.state.grid.extent(y),
          context
        )
        for x in 0 ..< 12 {
          let a = fast.cell(x, y)
          let r = reference.cell(x, y)
          #expect(
            fast.state.scalars(of: a) == reference.state.scalars(of: r),
            context
          )
          #expect(a.attributes == r.attributes, context)
          #expect(a.width == r.width, context)
        }
      }
    }
  }
}
