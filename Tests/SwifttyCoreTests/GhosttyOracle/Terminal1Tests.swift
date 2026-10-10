import TestSupport
@testable import SwifttyCore
import Testing

// Byte-level ports of Ghostty Terminal.zig, original tests before line 7739.
// Page/refcount assertions, allocation injection, graphics, and pixel APIs are omitted.

private enum Wide: Equatable { case narrow, wide, spacerTail, spacerHead }

private func wideOf(_ vt: borrowing VT, _ x: Int, _ y: Int) -> Wide {
  let c = vt.cell(x, y)
  if c.flags.contains(.spacerHead) { return .spacerHead }
  if c.flags.contains(.spacerTail) || c.width == 0 { return .spacerTail }
  return c.width == 2 ? .wide : .narrow
}

/// Ghostty's `cell.content.codepoint`: the base codepoint (0 when empty).
private func codepoint(_ vt: borrowing VT, _ x: Int, _ y: Int) -> UInt32 {
  let c = vt.cell(x, y)
  if c.isGrapheme { return vt.state.scalars(of: c).first?.value ?? 0 }
  return c.isSpacer ? 0 : c.glyph
}

/// Ghostty's `lookupGrapheme`: codepoints after the base, or nil.
private func graphemeTail(_ vt: borrowing VT, _ x: Int, _ y: Int) -> [UInt32]? {
  let c = vt.cell(x, y)
  guard c.isGrapheme else { return nil }
  let rest = vt.state.scalars(of: c).dropFirst().map(\.value)
  return rest.isEmpty ? nil : Array(rest)
}

private func hasGrapheme(_ vt: borrowing VT, _ x: Int, _ y: Int) -> Bool {
  graphemeTail(vt, x, y) != nil
}

private func link(_ vt: borrowing VT, _ x: Int, _ y: Int) -> UInt8 {
  vt.cell(x, y).attributes.link
}

/// Ghostty's `plainString`: viewport rows joined by "\n", trailing empty
/// cells and trailing empty rows trimmed. Unlike `vt.lines`, an explicit
/// space codepoint counts as content.
private func plain(_ vt: borrowing VT) -> String {
  var lines: [String] = []
  for y in 0 ..< vt.state.rows {
    var s = String.UnicodeScalarView()
    var blanks = 0
    for cell in vt.state.viewportRow(y).cells where !cell.isSpacer {
      let scalars = vt.state.scalars(of: cell)
      if scalars.isEmpty {
        blanks += 1
      } else {
        for _ in 0 ..< blanks { s.append(" ") }
        blanks = 0
        s.append(contentsOf: scalars)
      }
    }
    lines.append(String(s))
  }
  while lines.last == "" { lines.removeLast() }
  return lines.joined(separator: "\n")
}

private func hex(_ s: String) -> String {
  s.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
}

private func expectPlain(
  _ vt: borrowing VT,
  _ expected: String,
  sourceLocation: SourceLocation = #_sourceLocation,
) {
  let actual = plain(vt)
  #expect(
    Array(actual.unicodeScalars) == Array(expected.unicodeScalars),
    Comment(
      rawValue: escapedTestText(
        "plainString \(actual.debugDescription) [\(hex(actual))] != \(expected.debugDescription) [\(hex(expected))]",
      ),
    ),
    sourceLocation: sourceLocation,
  )
}

private func s(_ cps: UInt32...) -> String {
  var v = String.UnicodeScalarView()
  for cp in cps { v.append(Unicode.Scalar(cp)!) }
  return String(v)
}

private func eq<T: Equatable>(
  _ actual: T,
  _ expected: T,
  sourceLocation: SourceLocation = #_sourceLocation
) { #expect(actual == expected, sourceLocation: sourceLocation) }

private func ne<T: Equatable>(
  _ actual: T,
  _ expected: T,
  sourceLocation: SourceLocation = #_sourceLocation
) { #expect(actual != expected, sourceLocation: sourceLocation) }

private let graphemeOn = "\u{1B}[?2027h"
private let graphemeOff = "\u{1B}[?2027l"
private let lrmOn = "\u{1B}[?69h"
private let linkStart = "\u{1B}]8;;http://example.com\u{1B}\\"
private let linkEnd = "\u{1B}]8;;\u{1B}\\"
private let family = s(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467)

struct GhosttyTerminal1Tests {
  // MARK: Resize / title / pwd

  @Test("Terminal: resize resets synchronized output")
  func resizeResetsSynchronizedOutput() {
    var vt = VT(10, 5)
    vt.feed("\(CSI)?2026h")
    vt.state.resize(columns: 10, rows: 5)
    #expect(!vt.state.modes.contains(.synchronizedOutput))
  }

  @Test("Terminal: setPwd accepts its current value")
  func setPwdAcceptsCurrentValue() {
    var vt = VT(5, 1)
    vt.feed("\(ESC)]7;file:///tmp\(ESC)\\")
    vt.feed("\(ESC)]7;file:///tmp\(ESC)\\")
    #expect(
      TestFixture(String(decoding: vt.state.directoryBytes, as: UTF8.self))
        == TestFixture("file:///tmp")
    )
  }

  @Test("Terminal: setTitle accepts its current value")
  func setTitleAcceptsCurrentValue() {
    var vt = VT(5, 1)
    vt.feed("\(ESC)]2;Ghostty\u{07}")
    vt.feed("\(ESC)]2;Ghostty\u{07}")
    #expect(vt.state.title == "Ghostty")
  }

  @Test("Terminal: setCursorPos saturates overflowing origin offsets")
  func setCursorPosSaturates() {
    var vt = VT(10, 10)
    // scrolling_region top=2 bottom=7 left=3 right=8 (0-based), origin on.
    vt.feed("\(CSI)3;8r\(lrmOn)\(CSI)4;9s\(CSI)?6h")
    vt.feed("\(CSI)65535;65535H")
    #expect(vt.cursor.x == 8)
    #expect(vt.cursor.y == 7)
  }

  // MARK: Basic input

  @Test("Terminal: input with no control characters")
  func inputNoControlCharacters() {
    var vt = VT(40, 40)
    vt.feed("hello")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 5)
    expectPlain(vt, "hello")
  }

  @Test("Terminal: input with basic wraparound")
  func inputBasicWraparound() {
    var vt = VT(5, 40)
    vt.feed("helloworldabc12")
    #expect(vt.cursor.y == 2)
    #expect(vt.cursor.x == 4)
    #expect(vt.state.cursor.pendingWrap)
    expectPlain(vt, "hello\nworld\nabc12")
  }

  @Test("Terminal: input that forces scroll")
  func inputForcesScroll() {
    var vt = VT(1, 5)
    vt.feed("abcdef")
    #expect(vt.cursor.y == 4)
    #expect(vt.cursor.x == 0)
    expectPlain(vt, "b\nc\nd\ne\nf")
  }

  @Test("Terminal: input unique style per cell")
  func inputUniqueStylePerCell() {
    var vt = VT(30, 30)
    for y in 0 ..< 30 {
      for x in 0 ..< 30 {
        vt.feed("\(CSI)\(y + 1);\(x + 1)H\(CSI)48;2;\(x);\(y);0mx")
      }
    }
    for y in 0 ..< 30 {
      for x in 0 ..< 30 {
        let c = vt.cell(x, y)
        #expect(c.glyph == 0x78)
        #expect(c.attributes.background == .rgb(UInt8(x), UInt8(y), 0))
      }
    }
  }

  @Test("Terminal: zero-width character at start")
  func zeroWidthAtStart() {
    var vt = VT(80, 80)
    vt.feed(s(0x200D))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 0)
    eq(vt.cell(0, 0).isBlank, true)
  }

  @Test("Terminal: zero-width character attaches to pending wrap cell")
  func zeroWidthAttachesToPendingWrapCell() {
    var vt = VT(2, 2)
    vt.feed(graphemeOff)
    vt.feed(s(0x78, 0xE5, 0x332))
    expectPlain(vt, s(0x78, 0xE5, 0x332))
  }

  @Test("Terminal: caps zero-width codepoints attached to one cell")
  func capsZeroWidthCodepoints() {
    var vt = VT(2, 2)
    vt.feed(graphemeOff)
    vt.feed("A")
    vt.feed(String(repeating: s(0x301), count: 64 * 4))
    eq(graphemeTail(vt, 0, 0)?.count, 64)
  }

  @Test("Terminal: print single very long line")
  func printSingleVeryLongLine() {
    var vt = VT(5, 5)
    vt.feed(String(repeating: "x", count: 1000))
    #expect(vt.cursor.y == 4)
  }

  // MARK: Wide characters

  @Test("Terminal: print wide char")
  func printWideChar() {
    var vt = VT(80, 80)
    vt.feed(s(0x1F600))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x1F600)
    eq(wideOf(vt, 0, 0), .wide)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test("Terminal: print wide char at edge creates spacer head")
  func printWideCharAtEdgeCreatesSpacerHead() {
    var vt = VT(10, 10)
    vt.feed("\(CSI)1;10H")
    vt.feed(s(0x1F600))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)
    eq(wideOf(vt, 9, 0), .spacerHead)
    eq(codepoint(vt, 0, 1), 0x1F600)
    eq(wideOf(vt, 0, 1), .wide)
    eq(wideOf(vt, 1, 1), .spacerTail)
  }

  @Test("Terminal: print wide char in single-width terminal")
  func printWideCharSingleWidthTerminal() {
    var vt = VT(1, 80)
    vt.feed(s(0x1F600))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 0)
    #expect(vt.state.cursor.pendingWrap)
    eq(codepoint(vt, 0, 0), 0)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: print over wide char at 0,0")
  func printOverWideCharAtOrigin() {
    var vt = VT(80, 80)
    vt.feed(s(0x1F600))
    vt.feed("\(CSI)1;1HA")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x41)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .narrow)
  }

  @Test("Terminal: print over wide char at col 0 corrupts previous row")
  func printOverWideCharAtCol0() {
    var vt = VT(10, 3)
    vt.feed(String(repeating: s(0x4E2D), count: 10))
    vt.feed("\(CSI)2;1HA")
    eq(wideOf(vt, 0, 1), .narrow)
    eq(wideOf(vt, 8, 0), .wide)
    eq(wideOf(vt, 9, 0), .spacerTail)
  }

  @Test("Terminal: print over wide spacer tail")
  func printOverWideSpacerTail() {
    var vt = VT(5, 5)
    vt.feed(s(0x6A4B))
    vt.feed("\(CSI)1;2HX")
    eq(codepoint(vt, 0, 0), 0)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0x58)
    eq(wideOf(vt, 1, 0), .narrow)
    expectPlain(vt, " X")
  }

  @Test("Terminal: print over wide char with bold")
  func printOverWideCharWithBold() {
    var vt = VT(80, 80)
    vt.feed("\(CSI)1m")
    vt.feed(s(0x1F600))
    eq(vt.cell(0, 0).flags.contains(.bold), true)
    vt.feed("\(CSI)1;1H\(CSI)0mA")
    // Ghostty: the page's style count drops to 0 (no cell keeps bold).
    eq(vt.cell(0, 0).attributes, .default)
    eq(vt.cell(1, 0).attributes, .default)
  }

  @Test("Terminal: print over wide char with bg color")
  func printOverWideCharWithBg() {
    var vt = VT(80, 80)
    vt.feed("\(CSI)48;2;255;0;0m")
    vt.feed(s(0x1F600))
    eq(vt.cell(0, 0).attributes.background, .rgb(255, 0, 0))
    vt.feed("\(CSI)1;1H\(CSI)0mA")
    // Ghostty: the page's style count drops to 0 (no cell keeps the bg).
    eq(vt.cell(0, 0).attributes, .default)
    eq(vt.cell(1, 0).attributes, .default)
  }

  // MARK: Graphemes

  @Test("Terminal: print multicodepoint grapheme, disabled mode 2027")
  func multicodepointGraphemeDisabled2027() {
    var vt = VT(80, 80)
    vt.feed(graphemeOff)
    vt.feed(family)
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 6)

    eq(codepoint(vt, 0, 0), 0x1F468)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .wide)

    eq(codepoint(vt, 1, 0), 0)
    eq(hasGrapheme(vt, 1, 0), false)
    eq(wideOf(vt, 1, 0), .spacerTail)

    eq(codepoint(vt, 2, 0), 0x1F469)
    eq(graphemeTail(vt, 2, 0)?.count, 1)
    eq(wideOf(vt, 2, 0), .wide)

    eq(codepoint(vt, 3, 0), 0)
    eq(hasGrapheme(vt, 3, 0), false)
    eq(wideOf(vt, 3, 0), .spacerTail)

    eq(codepoint(vt, 4, 0), 0x1F467)
    eq(hasGrapheme(vt, 4, 0), false)
    eq(wideOf(vt, 4, 0), .wide)

    eq(codepoint(vt, 5, 0), 0)
    eq(hasGrapheme(vt, 5, 0), false)
    eq(wideOf(vt, 5, 0), .spacerTail)
  }

  @Test("Terminal: enabling grapheme mode handles stored breaks")
  func enablingGraphemeModeHandlesStoredBreaks() {
    var vt = VT(5, 1)
    vt.feed(graphemeOff)
    vt.feed("a" + s(0x200B))
    vt.feed(graphemeOn)
    vt.feed(s(0x301))
    expectPlain(vt, s(0x61, 0x200B, 0x301))
  }

  @Test("Terminal: graphemeWidth parity")
  func graphemeWidthParity() throws {
    // Expected cursor advance = sum of unicode.graphemeWidth over clusters.
    let cases: [([UInt32], Int)] = [
      ([0x2764, 0xFE0F], 2), ([0x78, 0xFE0F, 0xFE0F], 1),
      ([0x231A, 0xFE0E, 0xFE0F], 1), ([0x1F3F4, 0x200D, 0x2620, 0xFE0F], 2),
      ([0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467], 2),
      ([0x23, 0xFE0F, 0x20E3], 2), ([0x31, 0x20E3], 1),
      ([0x1F44B, 0x1F3FF], 2), ([0x1F1E6, 0x1F1E7, 0x1F1E8], 4),
      ([0x61, 0x62], 2), ([0x301, 0x302], 0),
    ]
    for (cps, expected) in cases {
      var vt = VT(80, 5)
      vt.feed(graphemeOn)
      var str = String.UnicodeScalarView()
      for cp in cps { try str.append(#require(Unicode.Scalar(cp))) }
      vt.feed(String(str))
      #expect(
        vt.cursor.y == 0,
        Comment(
          rawValue: escapedTestText("\(cps.map { String($0, radix: 16) })")
        )
      )
      #expect(
        vt.cursor.x == expected,
        Comment(
          rawValue: escapedTestText("\(cps.map { String($0, radix: 16) })")
        )
      )
    }
  }

  @Test("Terminal: VS16 doesn't make character with 2027 disabled")
  func vs16Disabled2027() {
    var vt = VT(5, 5)
    vt.feed(graphemeOff)
    vt.feed(s(0x2764, 0xFE0F))
    expectPlain(vt, s(0x2764, 0xFE0F))
    eq(codepoint(vt, 0, 0), 0x2764)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: print invalid VS16 non-grapheme")
  func invalidVS16NonGrapheme() {
    var vt = VT(80, 80)
    vt.feed(s(0x78, 0xFE0F))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x78)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0)
  }

  @Test("Terminal: variation selectors apply to preceding codepoint")
  func variationSelectorsApplyToPrecedingCodepoint() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x1F3F4, 0x200D, 0x2620, 0xFE0F))
    eq(codepoint(vt, 0, 0), 0x1F3F4)
    eq(graphemeTail(vt, 0, 0), [0x200D, 0x2620, 0xFE0F])
  }

  @Test("Terminal: print multicodepoint grapheme, mode 2027")
  func multicodepointGraphemeMode2027() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(family)
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x1F468)
    eq(graphemeTail(vt, 0, 0)?.count, 4)
    eq(wideOf(vt, 0, 0), .wide)
    eq(codepoint(vt, 1, 0), 0)
    eq(hasGrapheme(vt, 1, 0), false)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test("Terminal: keypad sequence VS15")
  func keypadSequenceVS15() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x23, 0xFE0E))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x23)
    eq(hasGrapheme(vt, 0, 0), true)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: keypad sequence VS16")
  func keypadSequenceVS16() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x23, 0xFE0F))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x23)
    eq(hasGrapheme(vt, 0, 0), true)
    eq(wideOf(vt, 0, 0), .wide)
  }

  @Test("Terminal: Fitzpatrick skin tone next valid base")
  func fitzpatrickValidBase() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x1F44B, 0x1F3FF))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x1F44B)
    eq(hasGrapheme(vt, 0, 0), true)
    eq(wideOf(vt, 0, 0), .wide)
  }

  @Test("Terminal: Fitzpatrick skin tone next to non-base")
  func fitzpatrickNonBase() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x22, 0x1F3FF, 0x22))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 4)
    eq(codepoint(vt, 0, 0), 0x22)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0x1F3FF)
    eq(hasGrapheme(vt, 1, 0), false)
    eq(wideOf(vt, 1, 0), .wide)
    eq(codepoint(vt, 3, 0), 0x22)
    eq(hasGrapheme(vt, 3, 0), false)
    eq(wideOf(vt, 3, 0), .narrow)
  }

  @Test("Terminal: VS15 to make narrow character")
  func vs15MakeNarrow() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x2614))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    vt.feed(s(0xFE0E))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    expectPlain(vt, s(0x2614, 0xFE0E))
    eq(codepoint(vt, 0, 0), 0x2614)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: VS15 on already narrow emoji")
  func vs15AlreadyNarrow() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x26C8, 0xFE0E))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    expectPlain(vt, s(0x26C8, 0xFE0E))
    eq(codepoint(vt, 0, 0), 0x26C8)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: print invalid VS15 following emoji is wide")
  func invalidVS15FollowingEmoji() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x1F9E0, 0xFE0E))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x1F9E0)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .wide)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test("Terminal: print invalid VS15 in emoji ZWJ sequence")
  func invalidVS15InZWJSequence() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x1F469, 0xFE0E, 0x200D, 0x1F466))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x1F469)
    eq(graphemeTail(vt, 0, 0), [0x200D, 0x1F466])
    eq(wideOf(vt, 0, 0), .wide)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test("Terminal: VS15 to make narrow character with pending wrap")
  func vs15NarrowWithPendingWrap() {
    var vt = VT(4, 5)
    vt.feed(graphemeOn)
    #expect(vt.state.modes.contains(.autowrap))
    vt.feed(s(0x1F34B, 0x2614))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 3)
    #expect(vt.state.cursor.pendingWrap)

    vt.feed(s(0xFE0E))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 3)
    #expect(!vt.state.cursor.pendingWrap)
    expectPlain(vt, s(0x1F34B, 0x2614, 0xFE0E))

    eq(codepoint(vt, 2, 0), 0x2614)
    eq(graphemeTail(vt, 2, 0)?.count, 1)
    eq(wideOf(vt, 2, 0), .narrow)

    eq(codepoint(vt, 0, 0), 0x1F34B)
    eq(wideOf(vt, 0, 0), .wide)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test(
    "Terminal: VS15 narrows wide cell under cursor with wraparound disabled"
  )
  func vs15NarrowsUnderCursorNoWrap() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)?7l")
    vt.feed("\(CSI)1;4H" + s(0x2614))
    vt.feed("\(lrmOn)\(CSI)1;4s\(CSI)1;4H")
    vt.feed(s(0xFE0E))
    #expect(vt.cursor.x == 3)
    #expect(!vt.state.cursor.pendingWrap)
    eq(wideOf(vt, 3, 0), .narrow)
    eq(hasGrapheme(vt, 3, 0), true)
    eq(wideOf(vt, 4, 0), .narrow)
  }

  @Test("Terminal: VS15 narrows wide cell under restored pending cursor")
  func vs15NarrowsUnderRestoredPendingCursor() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed("\(lrmOn)\(CSI)1;4s")
    vt.feed("\(CSI)1;4HX")
    #expect(vt.state.cursor.pendingWrap)
    vt.feed("\(ESC)7")
    vt.feed("\(CSI)1;5s\(CSI)1;4H" + s(0x2614))
    vt.feed("\(ESC)8")
    #expect(vt.state.cursor.pendingWrap)
    vt.feed(s(0xFE0E))
    #expect(vt.cursor.x == 4)
    #expect(!vt.state.cursor.pendingWrap)
    eq(wideOf(vt, 3, 0), .narrow)
    eq(hasGrapheme(vt, 3, 0), true)
    eq(wideOf(vt, 4, 0), .narrow)
  }

  @Test("Terminal: VS16 to make wide character on next line")
  func vs16WideOnNextLine() {
    var vt = VT(3, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)2C#")
    #expect(vt.cursor.x == 2)
    #expect(vt.state.cursor.pendingWrap)

    vt.feed(s(0xFE0F))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)
    #expect(!vt.state.cursor.pendingWrap)

    eq(codepoint(vt, 2, 0), 0)
    eq(hasGrapheme(vt, 2, 0), false)
    eq(wideOf(vt, 2, 0), .spacerHead)

    eq(codepoint(vt, 0, 1), 0x23)
    eq(graphemeTail(vt, 0, 1), [0xFE0F])
    eq(wideOf(vt, 0, 1), .wide)

    eq(codepoint(vt, 1, 1), 0)
    eq(hasGrapheme(vt, 1, 1), false)
    eq(wideOf(vt, 1, 1), .spacerTail)
  }

  @Test("Terminal: VS16 to make wide character on next line with hyperlink")
  func vs16WideOnNextLineWithHyperlink() {
    var vt = VT(3, 5)
    vt.feed(graphemeOn)
    vt.feed(linkStart)
    vt.feed("\(CSI)2C#")
    #expect(vt.cursor.x == 2)
    #expect(vt.state.cursor.pendingWrap)

    vt.feed(s(0xFE0F))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)
    #expect(!vt.state.cursor.pendingWrap)

    eq(codepoint(vt, 2, 0), 0)
    eq(wideOf(vt, 2, 0), .spacerHead)
    ne(link(vt, 2, 0), 0)
    eq(vt.state.grid.isWrapped(0), true)

    eq(codepoint(vt, 0, 1), 0x23)
    eq(graphemeTail(vt, 0, 1), [0xFE0F])
    eq(wideOf(vt, 0, 1), .wide)
    ne(link(vt, 0, 1), 0)

    eq(codepoint(vt, 1, 1), 0)
    eq(wideOf(vt, 1, 1), .spacerTail)
    ne(link(vt, 1, 1), 0)
  }

  @Test("Terminal: grapheme transfer when widening wraps to the next line")
  func graphemeTransferWhenWideningWraps() {
    var vt = VT(3, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)2C")
    vt.feed(s(0x263A, 0x200D, 0x2764))

    eq(wideOf(vt, 2, 0), .spacerHead)
    eq(vt.state.grid.isWrapped(0), true)

    eq(codepoint(vt, 0, 1), 0x263A)
    eq(wideOf(vt, 0, 1), .wide)
    eq(graphemeTail(vt, 0, 1), [0x200D, 0x2764])

    eq(wideOf(vt, 1, 1), .spacerTail)
  }

  @Test("Terminal: VS16 to make wide character with pending wrap")
  func vs16WideWithPendingWrap() {
    var vt = VT(3, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)1C#")
    #expect(vt.cursor.x == 2)
    #expect(!vt.state.cursor.pendingWrap)

    vt.feed(s(0xFE0F))
    #expect(vt.cursor.x == 2)
    #expect(vt.cursor.y == 0)
    #expect(vt.state.cursor.pendingWrap)

    eq(codepoint(vt, 1, 0), 0x23)
    eq(graphemeTail(vt, 1, 0), [0xFE0F])
    eq(wideOf(vt, 1, 0), .wide)

    eq(codepoint(vt, 2, 0), 0)
    eq(hasGrapheme(vt, 2, 0), false)
    eq(wideOf(vt, 2, 0), .spacerTail)
  }

  @Test("Terminal: VS16 to make wide character with mode 2027")
  func vs16WideMode2027() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x2764, 0xFE0F))
    expectPlain(vt, s(0x2764, 0xFE0F))
    eq(codepoint(vt, 0, 0), 0x2764)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .wide)
  }

  @Test("Terminal: VS16 repeated with mode 2027")
  func vs16RepeatedMode2027() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x2764, 0xFE0F, 0x2764, 0xFE0F))
    expectPlain(vt, s(0x2764, 0xFE0F, 0x2764, 0xFE0F))
    eq(codepoint(vt, 0, 0), 0x2764)
    eq(graphemeTail(vt, 0, 0)?.count, 1)
    eq(wideOf(vt, 0, 0), .wide)
    eq(codepoint(vt, 2, 0), 0x2764)
    eq(graphemeTail(vt, 2, 0)?.count, 1)
    eq(wideOf(vt, 2, 0), .wide)
  }

  @Test("Terminal: print invalid VS16 grapheme")
  func invalidVS16Grapheme() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x78, 0xFE0F))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x78)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .narrow)
  }

  @Test("Terminal: print invalid VS16 with second char")
  func invalidVS16WithSecondChar() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x78, 0xFE0F, 0x79))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x78)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0x79)
    eq(hasGrapheme(vt, 1, 0), false)
    eq(wideOf(vt, 1, 0), .narrow)
  }

  @Test("Terminal: print grapheme ò (o with nonspacing mark) should be narrow")
  func graphemeOWithNonspacingMark() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x6F, 0x300))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x6F)
    eq(graphemeTail(vt, 0, 0), [0x300])
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: print Devanagari grapheme should be wide")
  func devanagariWide() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x915, 0x94D, 0x200D, 0x937))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(codepoint(vt, 0, 0), 0x915)
    eq(graphemeTail(vt, 0, 0), [0x94D, 0x200D, 0x937])
    eq(wideOf(vt, 0, 0), .wide)
    eq(wideOf(vt, 1, 0), .spacerTail)
  }

  @Test("Terminal: print Devanagari grapheme should be wide on next line")
  func devanagariWideOnNextLine() {
    var vt = VT(3, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)2C")
    vt.feed(s(0x915, 0x94D, 0x200D))
    #expect(vt.cursor.x == 2)
    #expect(vt.state.cursor.pendingWrap)

    vt.feed(s(0x937))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)
    #expect(!vt.state.cursor.pendingWrap)

    eq(codepoint(vt, 2, 0), 0)
    eq(hasGrapheme(vt, 2, 0), false)
    eq(wideOf(vt, 2, 0), .spacerHead)

    eq(codepoint(vt, 0, 1), 0x915)
    eq(graphemeTail(vt, 0, 1), [0x94D, 0x200D, 0x937])
    eq(wideOf(vt, 0, 1), .wide)

    eq(wideOf(vt, 1, 1), .spacerTail)
  }

  @Test("Terminal: print invalid VS16 with second char (combining)")
  func invalidVS16WithCombining() {
    var vt = VT(80, 80)
    vt.feed(graphemeOn)
    vt.feed(s(0x6E, 0xFE0F, 0x303))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    eq(codepoint(vt, 0, 0), 0x6E)
    eq(graphemeTail(vt, 0, 0), [0x303])
    eq(wideOf(vt, 0, 0), .narrow)
    eq(codepoint(vt, 1, 0), 0)
    eq(wideOf(vt, 1, 0), .narrow)
  }

  @Test("Terminal: overwrite grapheme should clear grapheme data")
  func overwriteGraphemeClears() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed(s(0x26C8, 0xFE0E))
    vt.feed("\(CSI)1;1HA")
    expectPlain(vt, "A")
    eq(codepoint(vt, 0, 0), 0x41)
    eq(hasGrapheme(vt, 0, 0), false)
    eq(wideOf(vt, 0, 0), .narrow)
  }

  @Test("Terminal: overwrite multicodepoint grapheme clears grapheme data")
  func overwriteMulticodepointGraphemeClears() {
    var vt = VT(10, 10)
    vt.feed(graphemeOn)
    vt.feed(family)
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(hasGrapheme(vt, 0, 0), true)

    vt.feed("\(CSI)1;1HX")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 1)
    // Ghostty: page grapheme count drops to 0.
    eq(vt.cell(0, 0).isGrapheme, false)
    eq(vt.cell(1, 0).isGrapheme, false)
    expectPlain(vt, "X")
  }

  @Test("Terminal: overwrite multicodepoint grapheme tail clears grapheme data")
  func overwriteMulticodepointGraphemeTailClears() {
    var vt = VT(10, 10)
    vt.feed(graphemeOn)
    vt.feed(family)
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    eq(hasGrapheme(vt, 0, 0), true)

    vt.feed("\(CSI)1;2HX")
    expectPlain(vt, " X")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 2)
    // Ghostty: page grapheme count drops to 0.
    eq(vt.cell(0, 0).isGrapheme, false)
    eq(vt.cell(1, 0).isGrapheme, false)
  }

  @Test(
    "Terminal: print breaks valid grapheme cluster with Prepend + ASCII for speed"
  )
  func prependPlusASCIIBreaks() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed("_")
    vt.feed(s(0x600))
    vt.feed("1")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 3)
    eq(codepoint(vt, 1, 0), 0x600)
    eq(hasGrapheme(vt, 1, 0), false)
    eq(wideOf(vt, 1, 0), .narrow)
    eq(codepoint(vt, 2, 0), 0x31)
    eq(hasGrapheme(vt, 2, 0), false)
    eq(wideOf(vt, 2, 0), .narrow)
  }

  // MARK: Scrolled viewport / charsets

  @Test("Terminal: print writes to bottom if scrolled")
  func printWritesToBottomIfScrolled() {
    var vt = VT(5, 2)
    vt.feed("hello")
    vt.feed("\(CSI)1;1H")
    vt.feed("\(ESC)D\(ESC)D\(ESC)D")
    expectPlain(vt, "")

    vt.state.scrollViewport(toTopRow: 0)
    expectPlain(vt, "hello")

    vt.feed("A")
    vt.state.scrollViewportToBottom()
    expectPlain(vt, "\nA")
  }

  @Test("Terminal: print charset")
  func printCharset() {
    var vt = VT(80, 80)
    // G1..G3 should have no effect.
    vt.feed("\(ESC))0\(ESC)*0\(ESC)+0")
    vt.feed("`")
    vt.feed("\(ESC)(B`")  // G0 utf8 (no SCS byte; ASCII prints '`' identically)
    vt.feed("\(ESC)(B`")
    vt.feed("\(ESC)(0`")
    expectPlain(vt, "```\u{25C6}")
  }

  @Test("Terminal: print charset outside of ASCII")
  func printCharsetOutsideASCII() {
    var vt = VT(80, 80)
    vt.feed("\(ESC))0\(ESC)*0\(ESC)+0")
    vt.feed("\(ESC)(0`")
    vt.feed(s(0x1F600))
    expectPlain(vt, "\u{25C6} ")
  }

  @Test("Terminal: print invoke charset")
  func printInvokeCharset() {
    var vt = VT(80, 80)
    vt.feed("\(ESC))0")
    vt.feed("`")
    vt.feed("\u{0E}")  // SO: GL = G1
    vt.feed("``")
    vt.feed("\u{0F}")  // SI: GL = G0
    vt.feed("`")
    expectPlain(vt, "`\u{25C6}\u{25C6}`")
  }

  @Test("Terminal: print invoke charset single")
  func printInvokeCharsetSingle() {
    var vt = VT(80, 80)
    // Ported via G2 + SS2: single-shifting G1 has no byte form.
    vt.feed("\(ESC)*0")
    vt.feed("`")
    vt.feed("\(ESC)N")
    vt.feed("``")
    expectPlain(vt, "`\u{25C6}`")
  }

  // MARK: Wrapping and margins

  @Test("Terminal: soft wrap")
  func softWrap() {
    var vt = VT(3, 80)
    vt.feed("hello")
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)
    expectPlain(vt, "hel\nlo")
  }

  @Test("Terminal: disabled wraparound with wide char and one space")
  func disabledWraparoundWideCharOneSpace() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?7l")
    vt.feed("AAAA")
    vt.feed(s(0x1F6A8))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 4)
    expectPlain(vt, "AAAA")
    eq(codepoint(vt, 4, 0), 0)
    eq(wideOf(vt, 4, 0), .narrow)
  }

  @Test("Terminal: disabled wraparound with wide char and no space")
  func disabledWraparoundWideCharNoSpace() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?7l")
    vt.feed("AAAAA")
    vt.feed(s(0x1F6A8))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 4)
    expectPlain(vt, "AAAAA")
    eq(codepoint(vt, 4, 0), 0x41)
    eq(wideOf(vt, 4, 0), .narrow)
  }

  @Test("Terminal: disabled wraparound with wide grapheme and half space")
  func disabledWraparoundWideGraphemeHalfSpace() {
    var vt = VT(5, 5)
    vt.feed(graphemeOn)
    vt.feed("\(CSI)?7l")
    vt.feed("AAAA")
    vt.feed(s(0x2764))
    vt.feed(s(0xFE0F))
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 4)
    expectPlain(vt, "AAAA\u{2764}")
    eq(codepoint(vt, 4, 0), 0x2764)
    eq(wideOf(vt, 4, 0), .narrow)
  }

  @Test("Terminal: print right margin wrap")
  func printRightMarginWrap() {
    var vt = VT(10, 5)
    vt.feed("123456789")
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;5H")
    vt.feed("XY")
    expectPlain(vt, "1234X6789\n  Y")
    eq(vt.state.grid.isWrapped(0), false)
  }

  @Test("Terminal: print right margin outside")
  func printRightMarginOutside() {
    var vt = VT(10, 5)
    vt.feed("123456789")
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;6H")
    vt.feed("XY")
    expectPlain(vt, "12345XY89")
  }

  @Test("Terminal: print right margin outside wrap")
  func printRightMarginOutsideWrap() {
    var vt = VT(10, 5)
    vt.feed("123456789")
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;10H")
    vt.feed("XY")
    expectPlain(vt, "123456789X\n  Y")
  }

  @Test("Terminal: print wide char at right margin does not create spacer head")
  func printWideCharAtRightMarginNoSpacerHead() {
    var vt = VT(10, 10)
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;5H")
    vt.feed(s(0x1F600))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 4)

    eq(codepoint(vt, 4, 0), 0)
    eq(wideOf(vt, 4, 0), .narrow)
    eq(vt.state.grid.isWrapped(0), false)

    eq(codepoint(vt, 2, 1), 0x1F600)
    eq(wideOf(vt, 2, 1), .wide)
    eq(wideOf(vt, 3, 1), .spacerTail)
  }

  // MARK: Hyperlinks

  @Test("Terminal: print with hyperlink")
  func printWithHyperlink() {
    var vt = VT(80, 80)
    vt.feed(linkStart)
    vt.feed("123456")
    let id = link(vt, 0, 0)
    #expect(id != 0)
    for x in 0 ..< 6 { eq(link(vt, x, 0), id) }
  }

  @Test("Terminal: print over cell with same hyperlink")
  func printOverCellWithSameHyperlink() {
    var vt = VT(80, 80)
    vt.feed(linkStart)
    vt.feed("123456")
    vt.feed("\(CSI)1;1H")
    vt.feed("123456")
    let id = link(vt, 0, 0)
    #expect(id != 0)
    for x in 0 ..< 6 { eq(link(vt, x, 0), id) }
  }

  @Test("Terminal: print and end hyperlink")
  func printAndEndHyperlink() {
    var vt = VT(80, 80)
    vt.feed(linkStart)
    vt.feed("123")
    vt.feed(linkEnd)
    vt.feed("456")
    let id = link(vt, 0, 0)
    #expect(id != 0)
    for x in 0 ..< 3 { eq(link(vt, x, 0), id) }
    for x in 3 ..< 6 { eq(link(vt, x, 0), 0) }
  }

  @Test("Terminal: print and change hyperlink")
  func printAndChangeHyperlink() {
    var vt = VT(80, 80)
    vt.feed("\(ESC)]8;;http://one.example.com\(ESC)\\")
    vt.feed("123")
    vt.feed("\(ESC)]8;;http://two.example.com\(ESC)\\")
    vt.feed("456")
    let one = link(vt, 0, 0)
    let two = link(vt, 3, 0)
    #expect(one != 0)
    #expect(two != 0)
    #expect(one != two)
    for x in 0 ..< 3 { eq(link(vt, x, 0), one) }
    for x in 3 ..< 6 { eq(link(vt, x, 0), two) }
  }

  @Test("Terminal: overwrite hyperlink")
  func overwriteHyperlink() {
    var vt = VT(80, 80)
    vt.feed("\(ESC)]8;;http://one.example.com\(ESC)\\")
    vt.feed("123")
    vt.feed("\(CSI)1;1H")
    vt.feed(linkEnd)
    vt.feed("456")
    for x in 0 ..< 3 { eq(link(vt, x, 0), 0) }
  }

  @Test("Terminal: print wide char at right edge with hyperlink")
  func printWideCharAtRightEdgeWithHyperlink() {
    var vt = VT(10, 5)
    vt.feed(linkStart)
    vt.feed("\(CSI)1;10H")
    vt.feed(s(0x4E2D))
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 2)

    eq(wideOf(vt, 9, 0), .spacerHead)
    ne(link(vt, 9, 0), 0)
    eq(vt.state.grid.isWrapped(0), true)

    eq(codepoint(vt, 0, 1), 0x4E2D)
    eq(wideOf(vt, 0, 1), .wide)
    ne(link(vt, 0, 1), 0)

    eq(wideOf(vt, 1, 1), .spacerTail)
    ne(link(vt, 1, 1), 0)
  }

  // MARK: C0 controls

  @Test("Terminal: linefeed and carriage return")
  func linefeedAndCarriageReturn() {
    var vt = VT(80, 80)
    vt.feed("hello")
    vt.feed("\r")
    vt.feed("\n")
    vt.feed("world")
    #expect(vt.cursor.y == 1)
    #expect(vt.cursor.x == 5)
    expectPlain(vt, "hello\nworld")
  }

  @Test("Terminal: linefeed unsets pending wrap")
  func linefeedUnsetsPendingWrap() {
    var vt = VT(5, 80)
    vt.feed("hello")
    #expect(vt.state.cursor.pendingWrap)
    vt.feed("\n")
    #expect(!vt.state.cursor.pendingWrap)
  }

  @Test("Terminal: linefeed mode automatic carriage return")
  func linefeedModeAutomaticCR() {
    var vt = VT(10, 10)
    vt.feed("\(CSI)20h")
    vt.feed("123456")
    vt.feed("\n")
    vt.feed("X")
    expectPlain(vt, "123456\nX")
  }

  @Test("Terminal: carriage return unsets pending wrap")
  func carriageReturnUnsetsPendingWrap() {
    var vt = VT(5, 80)
    vt.feed("hello")
    #expect(vt.state.cursor.pendingWrap)
    vt.feed("\r")
    #expect(!vt.state.cursor.pendingWrap)
  }

  @Test("Terminal: carriage return origin mode moves to left margin")
  func carriageReturnOriginModeLeftMargin() {
    var vt = VT(5, 80)
    // left margin = 2; origin mode on. Ghostty pokes cursor.x = 0 directly,
    // which origin mode cannot express in bytes; move inside the margin.
    vt.feed("\(lrmOn)\(CSI)3;5s\(CSI)?6h")
    vt.feed("\(CSI)1;3H")
    vt.feed("\r")
    #expect(vt.cursor.x == 2)
  }

  @Test("Terminal: carriage return left of left margin moves to zero")
  func carriageReturnLeftOfLeftMargin() {
    var vt = VT(5, 80)
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;2H")
    vt.feed("\r")
    #expect(vt.cursor.x == 0)
  }

  @Test("Terminal: carriage return right of left margin moves to left margin")
  func carriageReturnRightOfLeftMargin() {
    var vt = VT(5, 80)
    vt.feed("\(lrmOn)\(CSI)3;5s")
    vt.feed("\(CSI)1;4H")
    vt.feed("\r")
    #expect(vt.cursor.x == 2)
  }

  @Test("Terminal: backspace")
  func backspace() {
    var vt = VT(80, 80)
    vt.feed("hello")
    vt.feed("\u{08}")
    vt.feed("y")
    #expect(vt.cursor.y == 0)
    #expect(vt.cursor.x == 5)
    expectPlain(vt, "helly")
  }

  @Test("Terminal: horizontal tabs")
  func horizontalTabs() {
    var vt = VT(20, 5)
    vt.feed("1\t")
    #expect(vt.cursor.x == 8)
    vt.feed("\t")
    #expect(vt.cursor.x == 16)
    vt.feed("\t")
    #expect(vt.cursor.x == 19)
    vt.feed("\t")
    #expect(vt.cursor.x == 19)
  }

  @Test("Terminal: horizontal tabs starting on tabstop")
  func horizontalTabsStartingOnTabstop() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)1;9HX")
    vt.feed("\(CSI)1;9H\tA")
    expectPlain(vt, "        X       A")
  }
}
