import TestSupport
@testable import SwifttyCore
import Testing

// Byte-level ports of Ghostty Terminal.zig, original lines >=14035.
// Feed boundaries exercise print/printSlice equivalence. Page pins, graphics,
// click options, and embedder-default APIs are omitted.

/// Ghostty `plainString`: rows joined by "\n", trailing blank rows dropped.
private func t4Plain(_ vt: borrowing VT) -> String {
  var lines = vt.lines
  while let last = lines.last, last.isEmpty { lines.removeLast() }
  return lines.joined(separator: "\n")
}

private let t4Red = TerminalColor.rgb(0xFF, 0, 0)

/// Deterministic PRNG (SplitMix64) for the differential test.
private struct T4Rand {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in lo...hi.
  mutating func int(_ lo: Int, _ hi: Int) -> Int {
    lo + Int(next() % UInt64(hi - lo + 1))
  }

  mutating func bool() -> Bool { next() & 1 == 1 }
}

struct GhosttyTerminal4Tests {
  // MARK: eraseLine

  @Test
  func `eraseLine left wide character`() {
    var vt = VT(10, 5)
    vt.feed("AB橋DE\(CSI)1;3H\(CSI)1K")
    let s = t4Plain(vt)
    #expect(s == "    DE")
  }

  @Test
  func `eraseLine left protected attributes respected with iso`() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1;1H\(CSI)1K")
    let s = t4Plain(vt)
    #expect(s == "ABC")
  }

  @Test
  func `eraseLine left protected attributes ignored with dec most recent`() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1\"q\(CSI)0\"q\(CSI)1;2H\(CSI)1K")
    let s = t4Plain(vt)
    #expect(s == "  C")
  }

  @Test
  func `eraseLine left protected attributes ignored with dec set`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"qABC\(CSI)1;2H\(CSI)1K")
    let s = t4Plain(vt)
    #expect(s == "  C")
  }

  @Test
  func `eraseLine left protected requested`() {
    var vt = VT(10, 5)
    vt.feed("123456789\(CSI)1;6H\(CSI)1\"qX\(CSI)1;8H\(CSI)?1K")
    let s = t4Plain(vt)
    #expect(s == "     X  9")
  }

  @Test
  func `eraseLine complete preserves background sgr`() {
    var vt = VT(5, 5)
    vt.feed("ABCDE\(CSI)1;2H\(CSI)48;2;255;0;0m\(CSI)2K")
    let s = t4Plain(vt)
    #expect(s == "")
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 0).attributes.background
      #expect(bg == t4Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test
  func `eraseLine complete resets wrap`() {
    var vt = VT(5, 5)
    vt.feed("ABCDE123")
    let wrappedBefore = vt.state.grid.isWrapped(0)
    #expect(wrappedBefore)
    vt.feed("\(CSI)1;1H\(CSI)2K")
    let wrappedAfter = vt.state.grid.isWrapped(0)
    #expect(!wrappedAfter)
    vt.feed("X")
    vt.state.resize(columns: 10, rows: 5)
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\n123"))
  }

  @Test
  func `eraseLine complete protected attributes respected with iso`() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1;1H\(CSI)2K")
    let s = t4Plain(vt)
    #expect(s == "ABC")
  }

  @Test
  func `eraseLine complete protected attributes ignored with dec most recent`()
  {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1\"q\(CSI)0\"q\(CSI)1;2H\(CSI)2K")
    let s = t4Plain(vt)
    #expect(s == "")
  }

  @Test
  func `eraseLine complete protected attributes ignored with dec set`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"qABC\(CSI)1;2H\(CSI)2K")
    let s = t4Plain(vt)
    #expect(s == "")
  }

  @Test
  func `eraseLine complete protected requested`() {
    var vt = VT(10, 5)
    vt.feed("123456789\(CSI)1;6H\(CSI)1\"qX\(CSI)1;8H\(CSI)?2K")
    let s = t4Plain(vt)
    #expect(s == "     X")
  }

  // MARK: tabs

  @Test
  func `tabClear single`() {
    var vt = VT(30, 5)
    vt.feed("\t\(CSI)0g\(CSI)1;1H\t")
    let x = vt.cursor.x
    #expect(x == 16)
  }

  @Test
  func `tabClear all`() {
    var vt = VT(30, 5)
    vt.feed("\(CSI)3g\(CSI)1;1H\t")
    let x = vt.cursor.x
    #expect(x == 29)
  }

  // MARK: printRepeat / printSlice

  @Test
  func `printRepeat simple`() {
    var vt = VT(5, 5)
    vt.feed("A\(CSI)1b")
    let s = t4Plain(vt)
    #expect(s == "AA")
  }

  @Test
  func `printRepeat wrap`() {
    var vt = VT(5, 5)
    vt.feed("    A\(CSI)1b")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("    A\nA"))
  }

  @Test
  func `printRepeat no previous character`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1b")
    let s = t4Plain(vt)
    #expect(s == "")
  }

  @Test
  func `printSlice simple ascii`() {
    var vt = VT(10, 3)
    vt.feed("hello")
    let x = vt.cursor.x
    #expect(x == 5)
    let s = t4Plain(vt)
    #expect(s == "hello")
    // previous_char == 'o': observable through REP.
    vt.feed("\(CSI)b")
    let s2 = t4Plain(vt)
    #expect(s2 == "helloo")
  }

  @Test
  func `printSlice charset batched fill`() {
    var vt = VT(5, 2)
    // G1 = DEC special, invoke G1 into GL (SO), grapheme clustering on.
    vt.feed("\(ESC))0\u{0E}\(CSI)?2027h")
    vt.feed("\(CSI)41m\(CSI)2J")
    for attr in ["0", "0", "1", "1", "0"] {
      vt.feed("\(CSI)1;1H\(CSI)\(attr)m")
      vt.feed("lqqqkmqqqj")
      let s = t4Plain(vt)
      #expect(
        TestFixture(s) == TestFixture("┌───┐\n└───┘"),
        Comment(rawValue: escapedTestText("attr=\(attr)"))
      )
      let pending = vt.state.cursor.pendingWrap
      #expect(pending, Comment(rawValue: escapedTestText("attr=\(attr)")))
      let pen = vt.state.cursor.pen
      for y in 0 ..< 2 {
        for x in 0 ..< 5 {
          var a = vt.cell(x, y).attributes
          a.flags.subtract(.structural)
          #expect(
            a == pen,
            Comment(rawValue: escapedTestText("attr=\(attr) x=\(x) y=\(y)"))
          )
        }
      }
    }
    // previous_char == 'j' (with the DEC special charset still active).
    vt.feed("\(CSI)2;1H\(CSI)b")
    let first = vt.cell(0, 1).glyph
    #expect(first == 0x2518)  // '┘'
  }

  @Test
  func `printSlice charset matches scalar printing`() throws {
    var bytes: [Unicode.Scalar] = []
    for v in 0x10 ..< 0x100 where v >= 0x20 && !(0x7F ... 0x9F).contains(v) {
      try bytes.append(#require(Unicode.Scalar(UInt32(v))))
    }
    let mixed: [Unicode.Scalar] = [
      0x100, 0x71, 0x301, 0x78, 0x4E00, 0x23, 0xFE0F, 0x1F600, 0x6A,
    ]
    .map { Unicode.Scalar(UInt32($0))! }
    for set in ["0", "A"] {
      for grapheme in [false, true] {
        var scalar = VT(17, 4)
        var batched = VT(17, 4)
        let setup = "\(ESC)(\(set)\(CSI)?2027\(grapheme ? "h" : "l")"
        scalar.feed(setup)
        batched.feed(setup)
        for cps in [bytes, mixed] {
          for cp in cps { scalar.feed(String(Character(cp))) }
          var view = String.UnicodeScalarView()
          view.append(contentsOf: cps)
          batched.feed(String(view))
          let a = scalar.lines
          let b = batched.lines
          #expect(
            a == b,
            Comment(
              rawValue: escapedTestText("set=\(set) grapheme=\(grapheme)")
            )
          )
          let ca = scalar.cursor
          let cb = batched.cursor
          #expect(ca.x == cb.x && ca.y == cb.y)
          let pa = scalar.state.cursor.pendingWrap
          let pb = batched.state.cursor.pendingWrap
          #expect(pa == pb)
        }
      }
    }
  }

  @Test
  func `printSlice charset single shift and repeat`() {
    var vt = VT(10, 2)
    // G0 = DEC special, G2 = British, SS2.
    vt.feed("\(ESC)(0\(ESC)*A\(ESC)N#q")
    vt.feed("\(CSI)2b")
    // REP uses the original byte with the current charset.
    vt.feed("\(ESC)(B\(CSI)2b")
    let s = t4Plain(vt)
    #expect(s == "£───qq")
  }

  @Test
  func `printSlice wraps and scrolls`() {
    var vt = VT(5, 2)
    vt.feed("abcdefghijkl")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("fghij\nkl"))
    let x = vt.cursor.x
    #expect(x == 2)
    let pending = vt.state.cursor.pendingWrap
    #expect(!pending)
  }

  @Test
  func `printSlice pending wrap state`() {
    var vt = VT(5, 2)
    vt.feed("abcde")
    let x = vt.cursor.x
    #expect(x == 4)
    let pending = vt.state.cursor.pendingWrap
    #expect(pending)
    let s = t4Plain(vt)
    #expect(s == "abcde")
  }

  /// Ghostty's helper compares print() with chunked printSlice(); here the
  /// same operation stream is fed in one call vs. split at random scalar
  /// boundaries. C0/DEL entries of the upstream alphabet are omitted since
  /// they are controls at the byte level.
  private func printSliceDifferential(
    _ rand: inout T4Rand,
    ops: Int,
    cols: Int,
    rows: Int
  ) {
    var t1 = VT(cols, rows)
    var t2 = VT(cols, rows)
    let alphabet: [UInt32] = [
      0x61, 0x62, 0x5A, 0x30, 0x20, 0xE9, 0xFF, 0x301, 0x4E00, 0x4E01, 0x1F600,
      0x200D, 0xFE0F, 0x78, 0x79, 0x1F9D1, 0x0308, 0xAD, 0x3042, 0xAC00, 0x71,
      0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x31, 0x32, 0x1F1E6, 0x1F1E7, 0x1100,
      0x1161, 0x11A8, 0x200C, 0x0430, 0x03B1,
    ]
    let charsets = ["B", "0", "A", "<", ">"]
    for op in 0 ..< ops {
      var seq = ""
      switch rand.int(0, 20) {
      case 0 ... 9:
        let n = rand.int(1, 64)
        var cps: [String] = []
        for _ in 0 ..< n {
          cps.append(
            String(
              Character(
                Unicode.Scalar(alphabet[rand.int(0, alphabet.count - 1)])!
              )
            )
          )
        }
        t1.feed(cps.joined())
        var i = 0
        while i < n {
          let chunk = rand.int(1, n - i)
          t2.feed(cps[i ..< i + chunk].joined())
          i += chunk
        }
      case 10: seq = "\r\n"
      case 11: seq = "\(CSI)\(rand.int(1, rows));\(rand.int(1, cols))H"
      case 12:
        switch rand.int(0, 3) {
        case 0: seq = "\(CSI)0m"
        case 1: seq = "\(CSI)1m"
        case 2:
          seq =
            "\(CSI)38;2;\(rand.int(0, 255));\(rand.int(0, 255));\(rand.int(0, 255))m"
        default: seq = "\(CSI)31m"
        }
      case 13: seq = "\(CSI)4\(rand.bool() ? "h" : "l")"
      case 14: seq = "\(CSI)?7\(rand.bool() ? "h" : "l")"
      case 15: seq = "\(CSI)?2027\(rand.bool() ? "h" : "l")"
      case 16:
        let left = rand.int(1, cols / 2 == 0 ? 1 : cols / 2)
        let right = rand.int(max(cols / 2, 1), cols)
        seq = "\(CSI)?69h\(CSI)\(left);\(right)s"
      case 17: seq = "\(CSI)?69h\(CSI)s"
      case 18: seq = "\(ESC)]8;;http://example.com\(ESC)\\"
      case 19: seq = "\(ESC)]8;;\(ESC)\\"
      default: seq = "\(ESC)(\(charsets[rand.int(0, charsets.count - 1)])"
      }
      if !seq.isEmpty {
        t1.feed(seq)
        t2.feed(seq)
      }
      let c1 = t1.cursor
      let c2 = t2.cursor
      let p1 = t1.state.cursor.pendingWrap
      let p2 = t2.state.cursor.pendingWrap
      let l1 = t1.lines
      let l2 = t2.lines
      #expect(
        c1.x == c2.x && c1.y == c2.y && p1 == p2,
        Comment(rawValue: escapedTestText("op \(op) \(cols)x\(rows)"))
      )
      #expect(
        l1 == l2,
        Comment(rawValue: escapedTestText("op \(op) \(cols)x\(rows)"))
      )
      if c1.x != c2.x || c1.y != c2.y || p1 != p2 || l1 != l2 { return }
    }
  }

  @Test
  func `printSlice differential fuzz vs print`() {
    var rand = T4Rand(state: 0xC0FFEE)
    printSliceDifferential(&rand, ops: 500, cols: 80, rows: 24)
    printSliceDifferential(&rand, ops: 500, cols: 10, rows: 4)
    printSliceDifferential(&rand, ops: 500, cols: 5, rows: 2)
    printSliceDifferential(&rand, ops: 200, cols: 2, rows: 2)
  }

  // MARK: printAttributes (DECRQSS SGR)

  private func decrqssSGR(_ vt: inout VT) -> String {
    _ = vt.takeOutput()
    vt.feed("\(ESC)P$qm\(ESC)\\")
    return vt.takeOutput()
  }

  @Test
  func `printAttributes`() {
    var vt = VT(5, 5)
    func rpss(_ v: String) -> String { "\(ESC)P1$r\(v)m\(ESC)\\" }

    vt.feed("\(CSI)38;2;1;2;3m")
    var r = decrqssSGR(&vt)
    #expect(r == rpss("0;38:2::1:2:3"))
    vt.feed("\(CSI)0m")

    vt.feed("\(CSI)1m\(CSI)48;2;1;2;3m")
    r = decrqssSGR(&vt)
    #expect(r == rpss("0;1;48:2::1:2:3"))
    vt.feed("\(CSI)0m")

    vt.feed(
      "\(CSI)1m\(CSI)2m\(CSI)3m\(CSI)4m\(CSI)5m\(CSI)7m\(CSI)8m\(CSI)9m\(CSI)53m"
    )
    vt.feed("\(CSI)38;2;100;200;255m\(CSI)48;2;101;102;103m")
    r = decrqssSGR(&vt)
    #expect(
      r == rpss("0;1;2;3;4;53;5;7;8;9;38:2::100:200:255;48:2::101:102:103")
    )
    vt.feed("\(CSI)0m")

    for (sgr, expected) in [
      ("4", "0;4"), ("4:2", "0;4:2"), ("4:3", "0;4:3"), ("4:4", "0;4:4"),
      ("4:5", "0;4:5"),
    ] {
      vt.feed("\(CSI)\(sgr)m")
      r = decrqssSGR(&vt)
      #expect(
        r == rpss(expected),
        Comment(rawValue: escapedTestText("SGR \(sgr)"))
      )
    }

    vt.feed("\(CSI)0m")
    r = decrqssSGR(&vt)
    #expect(r == rpss("0"))
  }

  // MARK: eraseDisplay

  private static let abcRows = "ABC\r\nDEF\r\nGHI"

  @Test
  func `eraseDisplay simple erase below`() {
    var vt = VT(5, 5)
    vt.feed(Self.abcRows + "\(CSI)2;2H\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nD"))
  }

  @Test
  func `eraseDisplay erase below preserves SGR bg`() {
    var vt = VT(5, 5)
    vt.feed(Self.abcRows + "\(CSI)2;2H\(CSI)48;2;255;0;0m\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nD"))
    for x in 1 ..< 5 {
      let bg = vt.cell(x, 1).attributes.background
      #expect(bg == t4Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test
  func `eraseDisplay below split multi-cell`() {
    var vt = VT(5, 5)
    vt.feed("AB橋C\r\nDE橋F\r\nGH橋I\(CSI)2;4H\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("AB橋C\nDE"))
  }

  @Test
  func `eraseDisplay below protected attributes respected with iso`() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)V" + Self.abcRows + "\(CSI)2;2H\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  @Test
  func `eraseDisplay below protected attributes ignored with dec most recent`()
  {
    var vt = VT(5, 5)
    vt.feed("\(ESC)V" + Self.abcRows + "\(CSI)1\"q\(CSI)0\"q\(CSI)2;2H\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nD"))
  }

  @Test
  func `eraseDisplay below protected attributes ignored with dec set`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"q" + Self.abcRows + "\(CSI)2;2H\(CSI)0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nD"))
  }

  @Test
  func `eraseDisplay below protected attributes respected with force`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"q" + Self.abcRows + "\(CSI)2;2H\(CSI)?0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  @Test
  func `eraseDisplay simple erase above`() {
    var vt = VT(5, 5)
    vt.feed(Self.abcRows + "\(CSI)2;2H\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n  F\nGHI"))
  }

  @Test
  func `eraseDisplay erase above preserves SGR bg`() {
    var vt = VT(5, 5)
    vt.feed(Self.abcRows + "\(CSI)2;2H\(CSI)48;2;255;0;0m\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n  F\nGHI"))
    for x in 0 ..< 2 {
      let bg = vt.cell(x, 1).attributes.background
      #expect(bg == t4Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test
  func `eraseDisplay above split multi-cell`() {
    var vt = VT(5, 5)
    vt.feed("AB橋C\r\nDE橋F\r\nGH橋I\(CSI)2;3H\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n    F\nGH橋I"))
  }

  @Test
  func `eraseDisplay above protected attributes respected with iso`() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)V" + Self.abcRows + "\(CSI)2;2H\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  @Test
  func `eraseDisplay above protected attributes ignored with dec most recent`()
  {
    var vt = VT(5, 5)
    vt.feed("\(ESC)V" + Self.abcRows + "\(CSI)1\"q\(CSI)0\"q\(CSI)2;2H\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n  F\nGHI"))
  }

  @Test
  func `eraseDisplay above protected attributes ignored with dec set`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"q" + Self.abcRows + "\(CSI)2;2H\(CSI)1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n  F\nGHI"))
  }

  @Test
  func `eraseDisplay above protected attributes respected with force`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"q" + Self.abcRows + "\(CSI)2;2H\(CSI)?1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  @Test
  func `eraseDisplay protected complete`() {
    var vt = VT(10, 5)
    vt.feed("A\r\n123456789\(CSI)2;6H\(CSI)1\"qX\(CSI)2;4H\(CSI)?2J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n     X"))
  }

  @Test
  func `eraseDisplay protected below`() {
    var vt = VT(10, 5)
    vt.feed("A\r\n123456789\(CSI)2;6H\(CSI)1\"qX\(CSI)2;4H\(CSI)?0J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\n123  X"))
  }

  @Test
  func `eraseDisplay scroll complete`() {
    var vt = VT(10, 5)
    vt.feed("A\r\n\(CSI)22J")
    let s = t4Plain(vt)
    #expect(s == "")
  }

  @Test
  func `eraseDisplay protected above`() {
    var vt = VT(10, 3)
    vt.feed("A\r\n123456789\(CSI)2;6H\(CSI)1\"qX\(CSI)2;8H\(CSI)?1J")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n     X  9"))
  }

  @Test
  func `eraseDisplay complete preserves cursor`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1mAAAA")
    let before = vt.state.cursor.pen.flags.contains(.bold)
    #expect(before)
    vt.feed("\(CSI)2J")
    let after = vt.state.cursor.pen.flags.contains(.bold)
    #expect(after)
  }

  // MARK: fullReset

  @Test
  func `fullReset with a non-empty pen`() {
    var vt = VT(80, 80)
    vt.feed("\(CSI)38;2;255;0;127m\(CSI)48;2;255;0;127m")
    vt.feed("\(ESC)c")
    let c = vt.cursor
    let cell = vt.cell(c.x, c.y)
    #expect(cell.attributes == .default)
    let pen = vt.state.cursor.pen
    #expect(pen == .default)
  }

  @Test
  func `fullReset hyperlink`() {
    var vt = VT(80, 80)
    vt.feed("\(ESC)]8;;http://example.com\(ESC)\\")
    vt.feed("\(ESC)c")
    let link = vt.state.cursor.pen.link
    #expect(link == 0)
    vt.feed("A")
    let cellLink = vt.cell(0, 0).attributes.link
    #expect(cellLink == 0)
  }

  @Test
  func `fullReset with a non-empty saved cursor`() {
    var vt = VT(80, 80)
    vt.feed("\(CSI)38;2;255;0;127m\(CSI)48;2;255;0;127m\(ESC)7")
    vt.feed("\(ESC)c")
    let c = vt.cursor
    let cell = vt.cell(c.x, c.y)
    #expect(cell.attributes == .default)
    let pen = vt.state.cursor.pen
    #expect(pen == .default)
  }

  @Test
  func `fullReset origin mode`() {
    var vt = VT(10, 10)
    vt.feed("\(CSI)3;5H\(CSI)?6h\(ESC)c")
    let c = vt.cursor
    #expect(c.x == 0 && c.y == 0)
    _ = vt.takeOutput()
    vt.feed("\(CSI)?6$p")
    let r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(CSI)?6;2$y"))
  }

  /// https://github.com/mitchellh/ghostty/issues/1607
  @Test
  func `fullReset clears alt screen kitty keyboard state`() {
    var vt = VT(10, 10)
    vt.feed("\(CSI)?1049h\(CSI)>31u\(CSI)?1049l")
    vt.feed("\(ESC)c")
    vt.feed("\(CSI)?1049h")
    _ = vt.takeOutput()
    vt.feed("\(CSI)?u")
    let r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(CSI)?0u"))
  }

  // MARK: resize

  /// https://github.com/mitchellh/ghostty/issues/272
  @Test
  func `resize less cols with wide char then print`() {
    var vt = VT(3, 3)
    vt.feed("x😀")
    vt.state.resize(columns: 2, rows: 3)
    vt.feed("\(CSI)1;2H😀")
    // Crash/integrity test upstream: no further assertions.
  }

  @Test
  func `resize less cols without reflow cutting wide char tail`() {
    var vt = VT(3, 1)
    vt.feed("a一\(CSI)?7l")
    vt.state.resize(columns: 2, rows: 1)
    let cell = vt.cell(1, 0)
    #expect(cell.glyph == 0)
    #expect(!cell.isSpacer)
  }

  /// https://github.com/mitchellh/ghostty/issues/723
  @Test
  func `resize with left and right margin set`() {
    var vt = VT(70, 23)
    vt.feed("\(CSI)?69h0\(CSI)?40h")
    vt.state.resize(columns: 70, rows: 23)
    vt.feed("\(CSI)2;0s\(CSI)1850b\(CSI)?40l")
    vt.state.resize(columns: 70, rows: 23)
    // Crash/integrity test upstream: no further assertions.
  }

  /// https://github.com/mitchellh/ghostty/issues/1343
  @Test
  func `resize with wraparound off`() {
    var vt = VT(4, 2)
    vt.feed("\(CSI)?7l0123")
    vt.state.resize(columns: 2, rows: 2)
    let s = t4Plain(vt)
    #expect(s == "01")
  }

  @Test
  func `resize with wraparound on`() {
    var vt = VT(4, 2)
    vt.feed("\(CSI)?7h0123")
    vt.state.resize(columns: 2, rows: 2)
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("01\n23"))
  }

  @Test
  func `resize with high unique style per cell`() {
    var vt = VT(30, 30)
    for y in 0 ..< 30 {
      for x in 0 ..< 30 { vt.feed("\(CSI)\(y);\(x)H\(CSI)48;2;\(x);\(y);0mx") }
    }
    vt.state.resize(columns: 60, rows: 30)
    // Crash/integrity test upstream: no further assertions.
  }

  @Test
  func `resize with high unique style per cell with wrapping`() {
    var vt = VT(30, 30)
    for i in 0 ..< 30 * 30 { vt.feed("\(CSI)48;2;\(i >> 8);\(i & 0xFF);0mx") }
    vt.state.resize(columns: 60, rows: 30)
    // Crash/integrity test upstream: no further assertions.
  }

  @Test
  func `resize with reflow and saved cursor`() {
    var vt = VT(2, 3)
    vt.feed("1A2B\(CSI)2;2H")
    var c = vt.cursor
    var g = vt.cell(c.x, c.y).glyph
    #expect(g == 0x42)
    var s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("1A\n2B"))

    vt.feed("\(ESC)7")
    vt.state.resize(columns: 5, rows: 3)
    vt.feed("\(ESC)8")
    s = t4Plain(vt)
    #expect(s == "1A2B")
    c = vt.cursor
    g = vt.cell(c.x, c.y).glyph
    #expect(g == 0x42)
  }

  @Test
  func `resize with reflow and saved cursor pending wrap`() {
    var vt = VT(2, 3)
    vt.feed("1A2B")
    let c = vt.cursor
    let g = vt.cell(c.x, c.y).glyph
    #expect(g == 0x42)
    var s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("1A\n2B"))

    vt.feed("\(ESC)7")
    vt.state.resize(columns: 5, rows: 3)
    vt.feed("\(ESC)8")
    s = t4Plain(vt)
    #expect(s == "1A2B")

    vt.feed("X")
    s = t4Plain(vt)
    #expect(s == "1A2BX")
  }

  @Test
  func `saved cursor survives repeated widening`() {
    var vt = VT(4, 5)
    vt.feed("abc\r\nAAA|\(ESC)7")
    vt.state.resize(columns: 5, rows: 5)
    vt.state.resize(columns: 6, rows: 5)
    vt.feed("\(ESC)8X")
    let s = t4Plain(vt)
    #expect(TestFixture(s) == TestFixture("abc\nAAA|X"))
  }

  @Test
  func `resize pending wrap live and saved cursors`() {
    let cases:
      [(text: String, cols: Int, pendingWrap: Bool, expected: String)] = [
        ("ABCD", 6, false, "ABCDX"), ("ABCD", 3, false, "ABC\nDX"),
        ("ABCD", 2, true, "AB\nCD\nX"), ("ABCD", 4, true, "ABCD\nX"),
        ("ABCDEFGH", 6, false, "ABCDEF\nGHX"), ("AB界", 6, false, "AB界X"),
        ("ABC", 6, false, "ABCX"),
      ]
    for c in cases {
      for restore in [false, true] {
        var vt = VT(4, 5)
        vt.feed(c.text)
        if restore { vt.feed("\(ESC)7") }
        vt.state.resize(columns: c.cols, rows: 6)
        if restore { vt.feed("\(ESC)8") }
        let pending = vt.state.cursor.pendingWrap
        #expect(
          pending == c.pendingWrap,
          Comment(
            rawValue: escapedTestText(
              "\(c.text) cols=\(c.cols) restore=\(restore)"
            )
          )
        )
        vt.feed("X")
        let s = t4Plain(vt)
        #expect(
          s == c.expected,
          Comment(
            rawValue: escapedTestText(
              "\(c.text) cols=\(c.cols) restore=\(restore)"
            )
          )
        )
      }
    }
  }

  // MARK: DECCOLM

  @Test
  func `DECCOLM without DEC mode 40`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?3h")
    let cols = vt.state.columns
    let rows = vt.state.rows
    #expect(cols == 5)
    #expect(rows == 5)
    _ = vt.takeOutput()
    vt.feed("\(CSI)?3$p")
    let r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(CSI)?3;2$y"))
  }

  @Test
  func `DECCOLM unset`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?40h\(CSI)?3l")
    let cols = vt.state.columns
    let rows = vt.state.rows
    #expect(cols == 80)
    #expect(rows == 5)
  }

  @Test
  func `DECCOLM resets pending wrap`() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    let before = vt.state.cursor.pendingWrap
    #expect(before)
    vt.feed("\(CSI)?40h\(CSI)?3l")
    let cols = vt.state.columns
    let rows = vt.state.rows
    #expect(cols == 80)
    #expect(rows == 5)
    let after = vt.state.cursor.pendingWrap
    #expect(!after)
  }

  @Test
  func `DECCOLM preserves SGR bg`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)48;2;255;0;0m\(CSI)?40h\(CSI)?3l")
    let bg = vt.cell(0, 0).attributes.background
    #expect(bg == t4Red)
  }

  @Test
  func `DECCOLM resets scroll region`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?69h\(CSI)2;3r\(CSI)3;5s")
    vt.feed("\(CSI)?40h\(CSI)?3l")
    _ = vt.takeOutput()
    vt.feed("\(CSI)?69$p")
    var r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(CSI)?69;1$y"))
    vt.feed("\(ESC)P$qr\(ESC)\\")
    r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(ESC)P1$r1;5r\(ESC)\\"))
    vt.feed("\(ESC)P$qs\(ESC)\\")
    r = vt.takeOutput()
    #expect(TestFixture(r) == TestFixture("\(ESC)P1$r1;80s\(ESC)\\"))
  }

  // MARK: alternate screen modes

  @Test
  func `mode 47 alt screen plain`() {
    var vt = VT(5, 5)
    vt.feed("1A")
    vt.feed("\(CSI)?47h")
    var alt = vt.state.isAlternateScreen
    #expect(alt)
    var s = t4Plain(vt)
    #expect(s == "")
    vt.feed("2B")
    s = t4Plain(vt)
    #expect(s == "  2B")
    vt.feed("\(CSI)?47l")
    alt = vt.state.isAlternateScreen
    #expect(!alt)
    s = t4Plain(vt)
    #expect(s == "1A")
    vt.feed("\(CSI)?47h")
    alt = vt.state.isAlternateScreen
    #expect(alt)
    s = t4Plain(vt)
    #expect(s == "  2B")
  }

  @Test
  func `mode 47 copies cursor both directions`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)38;2;255;0;127m\(CSI)?47h")
    var alt = vt.state.isAlternateScreen
    #expect(alt)
    var fg = vt.state.cursor.pen.foreground
    #expect(fg == .rgb(0xFF, 0, 0x7F))
    vt.feed("\(CSI)38;2;0;255;0m\(CSI)?47l")
    alt = vt.state.isAlternateScreen
    #expect(!alt)
    fg = vt.state.cursor.pen.foreground
    #expect(fg == .rgb(0, 0xFF, 0))
  }

  @Test
  func `mode 1047 alt screen plain`() {
    var vt = VT(5, 5)
    vt.feed("1A")
    vt.feed("\(CSI)?1047h")
    var alt = vt.state.isAlternateScreen
    #expect(alt)
    var s = t4Plain(vt)
    #expect(s == "")
    vt.feed("2B")
    s = t4Plain(vt)
    #expect(s == "  2B")
    vt.feed("\(CSI)?1047l")
    alt = vt.state.isAlternateScreen
    #expect(!alt)
    s = t4Plain(vt)
    #expect(s == "1A")
    vt.feed("\(CSI)?1047h")
    alt = vt.state.isAlternateScreen
    #expect(alt)
    s = t4Plain(vt)
    #expect(s == "")
  }

  @Test
  func `mode 1047 copies cursor both directions`() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)38;2;255;0;127m\(CSI)?1047h")
    var alt = vt.state.isAlternateScreen
    #expect(alt)
    var fg = vt.state.cursor.pen.foreground
    #expect(fg == .rgb(0xFF, 0, 0x7F))
    vt.feed("\(CSI)38;2;0;255;0m\(CSI)?1047l")
    alt = vt.state.isAlternateScreen
    #expect(!alt)
    fg = vt.state.cursor.pen.foreground
    #expect(fg == .rgb(0, 0xFF, 0))
  }

  @Test
  func `mode 1049 alt screen plain`() {
    var vt = VT(5, 5)
    vt.feed("1A")
    vt.feed("\(CSI)?1049h")
    var alt = vt.state.isAlternateScreen
    #expect(alt)
    var s = t4Plain(vt)
    #expect(s == "")
    vt.feed("2B")
    s = t4Plain(vt)
    #expect(s == "  2B")
    vt.feed("\(CSI)?1049l")
    alt = vt.state.isAlternateScreen
    #expect(!alt)
    s = t4Plain(vt)
    #expect(s == "1A")
    vt.feed("C")
    s = t4Plain(vt)
    #expect(s == "1AC")
    vt.feed("\(CSI)?1049h")
    alt = vt.state.isAlternateScreen
    #expect(alt)
    s = t4Plain(vt)
    #expect(s == "")
  }

  // MARK: crash regressions / row metadata

  @Test
  func `deleteLines wide char at right margin with full clear`() {
    var vt = VT(80, 24)
    vt.feed("\(CSI)10;39H\u{4E2D}")
    vt.feed("\(CSI)?69h\(CSI)5;39s")
    // Crash/integrity test upstream: no further assertions.
    vt.feed("\(CSI)24S")
  }

  @Test
  func `scroll region linefeed recycled row has default metadata`() {
    var vt = VT(5, 5)
    vt.feed(String(repeating: "A", count: 12))
    vt.feed("\(CSI)2;4r\(CSI)4;1H\n")
    let wrapped = vt.state.grid.isWrapped(3)
    #expect(!wrapped)
  }

  @Test
  func `alt screen scroll up recycled row has default metadata`() {
    var vt = VT(5, 3)
    vt.feed("\(CSI)?1049h")
    vt.feed(String(repeating: "A", count: 7))
    vt.feed("\(CSI)1S")
    let wrapped = vt.state.grid.isWrapped(2)
    #expect(!wrapped)
  }

  @Test
  func `insertLines count over region blanks row metadata`() {
    var vt = VT(5, 5)
    vt.feed(String(repeating: "A", count: 12))
    vt.feed("\(CSI)2;1H\(CSI)10L")
    for y in 1 ..< 5 {
      let wrapped = vt.state.grid.isWrapped(y)
      #expect(!wrapped, Comment(rawValue: escapedTestText("y=\(y)")))
    }
  }

  @Test
  func `deleteLines count over region blanks row metadata`() {
    var vt = VT(5, 5)
    vt.feed(String(repeating: "A", count: 12))
    vt.feed("\(CSI)2;1H\(CSI)10M")
    for y in 1 ..< 5 {
      let wrapped = vt.state.grid.isWrapped(y)
      #expect(!wrapped, Comment(rawValue: escapedTestText("y=\(y)")))
    }
  }

  @Test
  func `deleteLines blank row does not retain semantic prompt`() {
    var vt = VT(5, 3)
    vt.feed("$\(CSI)1;1H\(CSI)1M")
    let wrapped = vt.state.grid.isWrapped(2)
    #expect(!wrapped)
  }

  @Test
  func `eraseDisplay complete ignores stale prompt on recycled row`() {
    var vt = VT(10, 3)
    vt.feed("hello")
    vt.feed("\(CSI)2;3r\(CSI)3;1H\n\(CSI)r")
    vt.feed("\(CSI)2J")
    let history = vt.state.scrollbackCount
    #expect(history == 0)
  }
}
