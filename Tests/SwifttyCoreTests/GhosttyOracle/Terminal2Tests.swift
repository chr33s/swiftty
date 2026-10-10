import TestSupport
@testable import SwifttyCore
import Testing

// Byte-level ports of Ghostty Terminal.zig, original lines 7739..<11089.
// Margins use DECSTBM/DECSLRM; page capacity and style refcounts are omitted.

private func t2Join(_ lines: [String]) -> String {
  var l = lines
  while let last = l.last, last.isEmpty { l.removeLast() }
  return l.joined(separator: "\n")
}

/// Ghostty `plainString` equivalent (active screen).
private func t2Plain(_ vt: borrowing VT) -> String { t2Join(vt.lines) }

/// Ghostty `dumpStringAlloc(.screen)` equivalent: scrollback + active.
private func t2Screen(_ vt: borrowing VT) -> String {
  var all: [String] = []
  if !vt.state.isAlternateScreen {
    for i in 0 ..< vt.state.scrollbackCount {
      all.append(vt.state.scrollbackText(i))
    }
  }
  return t2Join(all + vt.lines)
}

private let t2Link = "\u{1B}]8;;http://example.com\u{1B}\\"
private let t2Unlink = "\u{1B}]8;;\u{1B}\\"
private let t2RedBG = "\u{1B}[48;2;255;0;0m"
private let t2Red = TerminalColor.rgb(0xFF, 0, 0)
private let t2ABCDEFGHI = "ABC\r\nDEF\r\nGHI"
private let t2LR = "ABC123\r\nDEF456\r\nGHI789"

struct GhosttyTerminal2Tests {
  // MARK: horizontal tabs

  @Test("Terminal: horizontal tabs with right margin")
  func horizontalTabsWithRightMargin() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)?69h\(CSI)3;6s")
    vt.feed("\(CSI)1;1HX\tA")
    let s = t2Plain(vt)
    #expect(s == "X    A")
  }

  @Test("Terminal: horizontal tabs back")
  func horizontalTabsBack() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)1;20H")
    vt.feed("\(CSI)Z")
    var x = vt.cursor.x
    #expect(x == 16)
    vt.feed("\(CSI)Z")
    x = vt.cursor.x
    #expect(x == 8)
    vt.feed("\(CSI)Z")
    x = vt.cursor.x
    #expect(x == 0)
    vt.feed("\(CSI)Z")
    x = vt.cursor.x
    #expect(x == 0)
  }

  @Test("Terminal: horizontal tabs back starting on tabstop")
  func horizontalTabsBackStartingOnTabstop() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)1;9HX\(CSI)1;9H\(CSI)ZA")
    let s = t2Plain(vt)
    #expect(s == "A       X")
  }

  @Test("Terminal: horizontal tabs with left margin in origin mode")
  func horizontalTabsWithLeftMarginInOriginMode() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)?69h\(CSI)3;6s\(CSI)?6h")
    vt.feed("\(CSI)1;2HX\(CSI)ZA")
    let s = t2Plain(vt)
    #expect(s == "  AX")
  }

  @Test("Terminal: horizontal tab back with cursor before left margin")
  func horizontalTabBackWithCursorBeforeLeftMargin() {
    var vt = VT(20, 5)
    vt.feed("\(CSI)?6h\(ESC)7\(CSI)?69h\(CSI)5s\(ESC)8\(CSI)ZX")
    let s = t2Plain(vt)
    #expect(s == "X")
  }

  // MARK: cursorPos

  @Test("Terminal: cursorPos resets wrap")
  func cursorPosResetsWrap() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)1;1H")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "XBCDE")
  }

  @Test("Terminal: cursorPos off the screen")
  func cursorPosOffTheScreen() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)500;500HX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\n\n    X"))
  }

  @Test("Terminal: cursorPos relative to origin")
  func cursorPosRelativeToOrigin() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)3;4r\(CSI)?6h\(CSI)1;1HX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\nX"))
  }

  @Test("Terminal: cursorPos relative to origin with left/right")
  func cursorPosRelativeToOriginWithLeftRight() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)3;4r\(CSI)?69h\(CSI)3;5s\(CSI)?6h\(CSI)1;1HX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n  X"))
  }

  @Test("Terminal: cursorPos limits with full scroll region")
  func cursorPosLimitsWithFullScrollRegion() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)3;4r\(CSI)?69h\(CSI)3;5s\(CSI)?6h\(CSI)500;500HX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\n    X"))
  }

  @Test("Terminal: setCursorPos (original test)")
  func setCursorPosOriginalTest() {
    var vt = VT(80, 80)
    var c = vt.cursor
    #expect(c.x == 0 && c.y == 0)

    vt.feed("\(CSI)0;0H")
    c = vt.cursor
    #expect(c.x == 0 && c.y == 0)

    vt.feed("\(CSI)81;81H")
    c = vt.cursor
    #expect(c.x == 79 && c.y == 79)

    vt.feed("\(CSI)0;80Hc")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)0;80H")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)

    vt.feed("\(CSI)?6h")
    vt.feed("\(CSI)81;81H")
    c = vt.cursor
    #expect(c.x == 79 && c.y == 79)

    vt.feed("\(CSI)10;80r")
    vt.feed("\(CSI)0;0H")
    c = vt.cursor
    #expect(c.x == 0 && c.y == 9)

    vt.feed("\(CSI)1;1H")
    c = vt.cursor
    #expect(c.x == 0 && c.y == 9)

    vt.feed("\(CSI)100;0H")
    c = vt.cursor
    #expect(c.x == 0 && c.y == 79)

    vt.feed("\(CSI)10;11r")
    vt.feed("\(CSI)2;0H")
    c = vt.cursor
    #expect(c.x == 0 && c.y == 10)
  }

  // MARK: setTopAndBottomMargin

  @Test("Terminal: setTopAndBottomMargin simple")
  func setTopAndBottomMarginSimple() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)r\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
  }

  @Test("Terminal: setTopAndBottomMargin top only")
  func setTopAndBottomMarginTopOnly() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2r\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\n\nDEF\nGHI"))
  }

  @Test("Terminal: setTopAndBottomMargin top and bottom")
  func setTopAndBottomMarginTopAndBottom() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)1;2r\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nGHI"))
  }

  @Test("Terminal: setTopAndBottomMargin top equal to bottom")
  func setTopAndBottomMarginTopEqualToBottom() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;2r\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
  }

  // MARK: setLeftAndRightMargin

  @Test("Terminal: setLeftAndRightMargin simple")
  func setLeftAndRightMarginSimple() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)?69h\(CSI)s\(CSI)X")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture(" BC\nDEF\nGHI"))
  }

  @Test("Terminal: setLeftAndRightMargin left only")
  func setLeftAndRightMarginLeftOnly() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)?69h\(CSI)2s\(CSI)1;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\nDBC\nGEF\n HI"))
  }

  @Test("Terminal: setLeftAndRightMargin left and right")
  func setLeftAndRightMarginLeftAndRight() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)?69h\(CSI)1;2s\(CSI)1;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("  C\nABF\nDEI\nGH"))
  }

  @Test("Terminal: setLeftAndRightMargin left equal right")
  func setLeftAndRightMarginLeftEqualRight() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)?69h\(CSI)2;2s\(CSI)1;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
  }

  @Test("Terminal: setLeftAndRightMargin mode 69 unset")
  func setLeftAndRightMarginMode69Unset() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)?69l\(CSI)1;2s\(CSI)1;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
  }

  // MARK: insertLines

  @Test("Terminal: insertLines simple")
  func insertLinesSimple() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\n\nDEF\nGHI"))
  }

  @Test("Terminal: insertLines colors with bg color")
  func insertLinesColorsWithBgColor() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;2H\(t2RedBG)\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\n\nDEF\nGHI"))
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 1).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: insertLines handles style refs")
  func insertLinesHandlesStyleRefs() {
    var vt = VT(5, 3)
    vt.feed("ABC\r\nDEF\r\n\(CSI)1mGHI\(CSI)0m")
    vt.feed("\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\n\nDEF"))
  }

  @Test("Terminal: insertLines outside of scroll region")
  func insertLinesOutsideOfScrollRegion() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)3;4r\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  @Test("Terminal: insertLines top/bottom scroll region")
  func insertLinesTopBottomScrollRegion() {
    var vt = VT(5, 5)
    vt.feed("ABC\r\nDEF\r\nGHI\r\n123")
    vt.feed("\(CSI)1;3r\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\n\nDEF\n123"))
  }

  @Test("Terminal: insertLines (legacy test)")
  func insertLinesLegacyTest() {
    var vt = VT(2, 5)
    vt.feed("A\r\nB\r\nC\r\nD\r\nE")
    vt.feed("\(CSI)2;1H\(CSI)2L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\n\n\nB\nC"))
  }

  @Test("Terminal: insertLines zero")
  func insertLinesZero() {
    var vt = VT(2, 5)
    vt.feed("\(CSI)1;1H\(CSI)0L")
    let s = t2Plain(vt)
    #expect(s == "")
  }

  @Test("Terminal: insertLines with scroll region")
  func insertLinesWithScrollRegion() {
    var vt = VT(2, 6)
    vt.feed("A\r\nB\r\nC\r\nD\r\nE")
    vt.feed("\(CSI)1;2r\(CSI)1;1H\(CSI)LX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\nA\nC\nD\nE"))
  }

  @Test("Terminal: insertLines more than remaining")
  func insertLinesMoreThanRemaining() {
    var vt = VT(2, 5)
    vt.feed("A\r\nB\r\nC\r\nD\r\nE")
    vt.feed("\(CSI)2;1H\(CSI)20L")
    let s = t2Plain(vt)
    #expect(s == "A")
  }

  @Test("Terminal: insertLines resets pending wrap")
  func insertLinesResetsPendingWrap() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)L")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("B")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("B\nABCDE"))
  }

  @Test("Terminal: insertLines resets wrap")
  func insertLinesResetsWrap() {
    var vt = VT(3, 3)
    vt.feed("1\r\nABCDEF")
    vt.feed("\(CSI)1;1H\(CSI)LX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\n1\nABC"))
    let wrapped = vt.state.viewportRow(2).wrapped
    #expect(!wrapped)
  }

  @Test("Terminal: insertLines multi-codepoint graphemes")
  func insertLinesMultiCodepointGraphemes() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?2027h")
    vt.feed("ABC\r\n")
    vt.feed("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")
    vt.feed("\r\nGHI")
    vt.feed("\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(
      TestFixture(s)
        == TestFixture(
          "ABC\n\n\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\nGHI"
        )
    )
  }

  @Test("Terminal: insertLines left/right scroll region")
  func insertLinesLeftRightScrollRegion() {
    var vt = VT(10, 10)
    vt.feed(t2LR)
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)2;2H\(CSI)L")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC123\nD   56\nGEF489\n HI7"))
  }

  // MARK: scrollUp

  @Test("Terminal: scrollUp simple")
  func scrollUpSimple() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;2H")
    let before = vt.cursor
    vt.feed("\(CSI)S")
    let after = vt.cursor
    #expect(before == after)
    // Ghostty: the viewport moved, i.e. the top row went to scrollback.
    let sb = vt.state.scrollbackCount
    #expect(sb == 1)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("DEF\nGHI"))
  }

  @Test("Terminal: scrollUp moves hyperlink")
  func scrollUpMovesHyperlink() {
    var vt = VT(5, 5)
    vt.feed("ABC\r\n\(t2Link)DEF\(t2Unlink)\r\nGHI")
    vt.feed("\(CSI)2;2H\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("DEF\nGHI"))
    for x in 0 ..< 3 {
      let l0 = vt.cell(x, 0).attributes.link
      #expect(l0 != 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
      let l1 = vt.cell(x, 1).attributes.link
      #expect(l1 == 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
    }
  }

  @Test("Terminal: scrollUp clears hyperlink")
  func scrollUpClearsHyperlink() {
    var vt = VT(5, 5)
    vt.feed("\(t2Link)ABC\(t2Unlink)\r\nDEF\r\nGHI")
    vt.feed("\(CSI)2;2H\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("DEF\nGHI"))
    for x in 0 ..< 3 {
      let l0 = vt.cell(x, 0).attributes.link
      #expect(l0 == 0, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: scrollUp top/bottom scroll region")
  func scrollUpTopBottomScrollRegion() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;3r\(CSI)1;1H\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nGHI"))
  }

  @Test("Terminal: scrollUp left/right scroll region")
  func scrollUpLeftRightScrollRegion() {
    var vt = VT(10, 10)
    vt.feed(t2LR)
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)2;2H")
    let before = vt.cursor
    vt.feed("\(CSI)S")
    let after = vt.cursor
    #expect(before == after)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("AEF423\nDHI756\nG   89"))
  }

  @Test("Terminal: scrollUp left/right scroll region hyperlink")
  func scrollUpLeftRightScrollRegionHyperlink() {
    var vt = VT(10, 10)
    vt.feed("ABC123\r\n\(t2Link)DEF456\(t2Unlink)\r\nGHI789")
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)2;2H\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("AEF423\nDHI756\nG   89"))
    // Row 0: links only in the scrolled columns 1..<4.
    for x in 0 ..< 6 {
      let l = vt.cell(x, 0).attributes.link
      if (1 ..< 4).contains(x) {
        #expect(l != 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
      } else {
        #expect(l == 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
      }
    }
    // Row 1: links preserved outside the scrolled columns.
    for x in 0 ..< 6 {
      let l = vt.cell(x, 1).attributes.link
      if (1 ..< 4).contains(x) {
        #expect(l == 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
      } else {
        #expect(l != 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
      }
    }
  }

  @Test("Terminal: scrollUp preserves pending wrap")
  func scrollUpPreservesPendingWrap() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;5HA\(CSI)2;5HB\(CSI)3;5HC\(CSI)SX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("    B\n    C\n\nX"))
  }

  @Test("Terminal: scrollUp full top/bottom region")
  func scrollUpFullTopBottomRegion() {
    var vt = VT(5, 5)
    vt.feed("top\(CSI)5;1HABCDE\(CSI)2;5r\(CSI)4S")
    let s = t2Plain(vt)
    #expect(s == "top")
  }

  @Test("Terminal: scrollUp full top/bottomleft/right scroll region")
  func scrollUpFullTopBottomLeftRightScrollRegion() {
    var vt = VT(5, 5)
    vt.feed("top\(CSI)5;1HABCDE")
    vt.feed("\(CSI)?69h\(CSI)2;5r\(CSI)2;4s\(CSI)4S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("top\n\n\n\nA   E"))
  }

  @Test("Terminal: scrollUp creates scrollback in primary screen")
  func scrollUpCreatesScrollbackInPrimaryScreen() {
    var vt = VT(5, 5)
    vt.feed("AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE")
    vt.feed("\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("BBBBB\nCCCCC\nDDDDD\nEEEEE"))
    vt.state.scrollViewport(by: 1000)
    let top = t2Plain(vt)
    #expect(
      TestFixture(top) == TestFixture("AAAAA\nBBBBB\nCCCCC\nDDDDD\nEEEEE")
    )
  }

  @Test("Terminal: scrollUp with max_scrollback_bytes zero")
  func scrollUpWithMaxScrollbackBytesZero() {
    var vt = VT(5, 5, scrollback: 0)
    vt.feed("AAAAA\r\nBBBBB\r\nCCCCC")
    vt.feed("\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("BBBBB\nCCCCC"))
    vt.state.scrollViewport(by: 1000)
    let top = t2Plain(vt)
    #expect(TestFixture(top) == TestFixture("BBBBB\nCCCCC"))
  }

  @Test("Terminal: scrollUp with max_scrollback_bytes zero and top margin")
  func scrollUpWithMaxScrollbackBytesZeroAndTopMargin() {
    var vt = VT(5, 5, scrollback: 0)
    vt.feed("AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD")
    vt.feed("\(CSI)2;5r\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("AAAAA\nCCCCC\nDDDDD"))
  }

  @Test(
    "Terminal: scrollUp with max_scrollback_bytes zero and left/right margin",
  )
  func scrollUpWithMaxScrollbackBytesZeroAndLeftRightMargin() {
    var vt = VT(10, 5, scrollback: 0)
    vt.feed("AAAAABBBBB\r\nCCCCCDDDDD\r\nEEEEEFFFFF")
    vt.feed("\(CSI)?69h\(CSI)2;6s\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF"))
  }

  // MARK: scrollDown

  @Test("Terminal: scrollDown simple")
  func scrollDownSimple() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)2;2H")
    let before = vt.cursor
    vt.feed("\(CSI)T")
    let after = vt.cursor
    #expect(before == after)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
  }

  @Test("Terminal: scrollDown hyperlink moves")
  func scrollDownHyperlinkMoves() {
    var vt = VT(5, 5)
    vt.feed("\(t2Link)ABC\(t2Unlink)\r\nDEF\r\nGHI")
    vt.feed("\(CSI)2;2H\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nABC\nDEF\nGHI"))
    for x in 0 ..< 3 {
      let l1 = vt.cell(x, 1).attributes.link
      #expect(l1 != 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
      let l0 = vt.cell(x, 0).attributes.link
      #expect(l0 == 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
    }
  }

  @Test("Terminal: scrollDown outside of scroll region")
  func scrollDownOutsideOfScrollRegion() {
    var vt = VT(5, 5)
    vt.feed(t2ABCDEFGHI)
    vt.feed("\(CSI)3;4r\(CSI)2;2H")
    let before = vt.cursor
    vt.feed("\(CSI)T")
    let after = vt.cursor
    #expect(before == after)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\n\nGHI"))
  }

  @Test("Terminal: scrollDown left/right scroll region")
  func scrollDownLeftRightScrollRegion() {
    var vt = VT(10, 10)
    vt.feed(t2LR)
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)2;2H")
    let before = vt.cursor
    vt.feed("\(CSI)T")
    let after = vt.cursor
    #expect(before == after)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A   23\nDBC156\nGEF489\n HI7"))
  }

  @Test("Terminal: scrollDown left/right scroll region hyperlink")
  func scrollDownLeftRightScrollRegionHyperlink() {
    var vt = VT(10, 10)
    vt.feed("\(t2Link)ABC123\(t2Unlink)\r\nDEF456\r\nGHI789")
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)2;2H\(CSI)T")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A   23\nDBC156\nGEF489\n HI7"))
    // Row 0 keeps links outside the scrolled columns.
    for x in 0 ..< 6 {
      let l = vt.cell(x, 0).attributes.link
      if (1 ..< 4).contains(x) {
        #expect(l == 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
      } else {
        #expect(l != 0, Comment(rawValue: escapedTestText("x=\(x) y=0")))
      }
    }
    // Row 1 gets links in the scrolled columns.
    for x in 0 ..< 6 {
      let l = vt.cell(x, 1).attributes.link
      if (1 ..< 4).contains(x) {
        #expect(l != 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
      } else {
        #expect(l == 0, Comment(rawValue: escapedTestText("x=\(x) y=1")))
      }
    }
  }

  @Test("Terminal: scrollDown outside of left/right scroll region")
  func scrollDownOutsideOfLeftRightScrollRegion() {
    var vt = VT(10, 10)
    vt.feed(t2LR)
    vt.feed("\(CSI)?69h\(CSI)2;4s\(CSI)1;1H")
    let before = vt.cursor
    vt.feed("\(CSI)T")
    let after = vt.cursor
    #expect(before == after)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A   23\nDBC156\nGEF489\n HI7"))
  }

  @Test("Terminal: scrollDown preserves pending wrap")
  func scrollDownPreservesPendingWrap() {
    var vt = VT(5, 10)
    vt.feed("\(CSI)1;5HA\(CSI)2;5HB\(CSI)3;5HC\(CSI)TX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n    A\n    B\nX   C"))
  }

  // MARK: eraseChars

  @Test("Terminal: eraseChars simple operation")
  func eraseCharsSimpleOperation() {
    var vt = VT(5, 5)
    vt.feed("ABC\(CSI)1;1H\(CSI)2XX")
    let s = t2Plain(vt)
    #expect(s == "X C")
  }

  @Test("Terminal: eraseChars minimum one")
  func eraseCharsMinimumOne() {
    var vt = VT(5, 5)
    vt.feed("ABC\(CSI)1;1H\(CSI)0XX")
    let s = t2Plain(vt)
    #expect(s == "XBC")
  }

  @Test("Terminal: eraseChars beyond screen edge")
  func eraseCharsBeyondScreenEdge() {
    var vt = VT(5, 5)
    vt.feed("  ABC\(CSI)1;4H\(CSI)10X")
    let s = t2Plain(vt)
    #expect(s == "  A")
  }

  @Test("Terminal: eraseChars wide character")
  func eraseCharsWideCharacter() {
    var vt = VT(5, 5)
    vt.feed("橋BC\(CSI)1;1H\(CSI)XX")
    let s = t2Plain(vt)
    #expect(s == "X BC")
  }

  @Test("Terminal: eraseChars resets pending wrap")
  func eraseCharsResetsPendingWrap() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)X")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "ABCDX")
  }

  @Test("Terminal: eraseChars resets wrap")
  func eraseCharsResetsWrap() {
    var vt = VT(5, 5)
    vt.feed("ABCDE123")
    var wrapped = vt.state.viewportRow(0).wrapped
    #expect(wrapped)
    vt.feed("\(CSI)1;1H\(CSI)X")
    wrapped = vt.state.viewportRow(0).wrapped
    #expect(!wrapped)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("XBCDE\n123"))
  }

  @Test("Terminal: eraseChars preserves background sgr")
  func eraseCharsPreservesBackgroundSgr() {
    var vt = VT(10, 10)
    vt.feed("ABC\(CSI)1;1H\(t2RedBG)\(CSI)2X")
    let s = t2Plain(vt)
    #expect(s == "  C")
    for x in 0 ..< 2 {
      let bg = vt.cell(x, 0).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: eraseChars protected attributes respected with iso")
  func eraseCharsProtectedAttributesRespectedWithIso() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1;1H\(CSI)2X")
    let s = t2Plain(vt)
    #expect(s == "ABC")
  }

  @Test(
    "Terminal: eraseChars protected attributes ignored with dec most recent",
  )
  func eraseCharsProtectedAttributesIgnoredWithDecMostRecent() {
    var vt = VT(5, 5)
    vt.feed("\(ESC)VABC\(CSI)1\"q\(CSI)0\"q\(CSI)1;1H\(CSI)2X")
    let s = t2Plain(vt)
    #expect(s == "  C")
  }

  @Test("Terminal: eraseChars protected attributes ignored with dec set")
  func eraseCharsProtectedAttributesIgnoredWithDecSet() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1\"qABC\(CSI)1;1H\(CSI)2X")
    let s = t2Plain(vt)
    #expect(s == "  C")
  }

  @Test("Terminal: eraseChars wide char boundary conditions")
  func eraseCharsWideCharBoundaryConditions() {
    var vt = VT(8, 1)
    vt.feed("😀a😀b😀")
    var s = t2Plain(vt)
    #expect(s == "😀a😀b😀")
    vt.feed("\(CSI)1;2H\(CSI)3X")
    s = t2Plain(vt)
    #expect(s == "     b😀")
  }

  @Test("Terminal: eraseChars wide char splits proper cell boundaries")
  func eraseCharsWideCharSplitsProperCellBoundaries() {
    var vt = VT(30, 1)
    vt.feed("x食べて下さい")
    var s = t2Plain(vt)
    #expect(s == "x食べて下さい")
    vt.feed("\(CSI)1;6H\(CSI)4X")
    s = t2Plain(vt)
    #expect(s == "x食べ    さい")
  }

  @Test("Terminal: eraseChars wide char wrap boundary conditions")
  func eraseCharsWideCharWrapBoundaryConditions() {
    var vt = VT(8, 3)
    vt.feed(".......😀abcde😀......")
    var s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture(".......\n😀abcde\n😀......"))
    // plainStringUnwrapped ".......😀abcde😀......": rows 0 and 1 soft-wrap.
    var w0 = vt.state.viewportRow(0).wrapped
    var w1 = vt.state.viewportRow(1).wrapped
    #expect(w0)
    #expect(w1)
    vt.feed("\(CSI)2;2H\(CSI)3X")
    s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture(".......\n    cde\n😀......"))
    // plainStringUnwrapped ".......     cde\n😀......": row 1 no longer wraps.
    w0 = vt.state.viewportRow(0).wrapped
    w1 = vt.state.viewportRow(1).wrapped
    #expect(w0)
    #expect(!w1)
  }

  @Test(
    "Terminal: eraseChars clearing wrapped wide char marks spacer head row dirty",
  )
  func eraseCharsClearingWrappedWideCharMarksSpacerHeadRowDirty() {
    var vt = VT(5, 3)
    vt.feed("ABCD字")
    let head = vt.cell(4, 0).flags.contains(.spacerHead)
    #expect(head)
    let wrapped = vt.state.viewportRow(0).wrapped
    #expect(wrapped)
    vt.feed("\(CSI)2;1H\(CSI)X")
    // Erasing the wide char also clears the spacer head on the previous row.
    let headAfter = vt.cell(4, 0).flags.contains(.spacerHead)
    #expect(!headAfter)
  }

  // MARK: reverseIndex

  @Test("Terminal: reverseIndex")
  func reverseIndex() {
    var vt = VT(2, 5)
    vt.feed("A\r\nB\r\nC\(ESC)MD\r\n\r\n")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\nBD\nC"))
  }

  @Test("Terminal: reverseIndex from the top")
  func reverseIndexFromTheTop() {
    var vt = VT(2, 5)
    vt.feed("A\r\nB\r\n\r\n")
    vt.feed("\(CSI)1;1H\(ESC)MD\r\n")
    vt.feed("\(CSI)1;1H\(ESC)ME\r\n")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("E\nD\nA\nB"))
  }

  @Test("Terminal: reverseIndex top of scrolling region")
  func reverseIndexTopOfScrollingRegion() {
    var vt = VT(2, 10)
    vt.feed("\(CSI)2;1HA\r\nB\r\nC\r\nD\r\n")
    vt.feed("\(CSI)2;5r\(CSI)2;1H\(ESC)MX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nX\nA\nB\nC"))
  }

  @Test("Terminal: reverseIndex top of screen")
  func reverseIndexTopOfScreen() {
    var vt = VT(5, 5)
    vt.feed("A\(CSI)2;1HB\(CSI)3;1HC\(CSI)1;1H\(ESC)MX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\nA\nB\nC"))
  }

  @Test("Terminal: reverseIndex not top of screen")
  func reverseIndexNotTopOfScreen() {
    var vt = VT(5, 5)
    vt.feed("A\(CSI)2;1HB\(CSI)3;1HC\(CSI)2;1H\(ESC)MX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\nB\nC"))
  }

  @Test("Terminal: reverseIndex top/bottom margins")
  func reverseIndexTopBottomMargins() {
    var vt = VT(5, 5)
    vt.feed("A\(CSI)2;1HB\(CSI)3;1HC\(CSI)2;3r\(CSI)2;1H\(ESC)M")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\n\nB"))
  }

  @Test("Terminal: reverseIndex outside top/bottom margins")
  func reverseIndexOutsideTopBottomMargins() {
    var vt = VT(5, 5)
    vt.feed("A\(CSI)2;1HB\(CSI)3;1HC\(CSI)2;3r\(CSI)1;1H\(ESC)M")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\nB\nC"))
  }

  @Test("Terminal: reverseIndex left/right margins")
  func reverseIndexLeftRightMargins() {
    var vt = VT(5, 5)
    vt.feed("ABC\(CSI)2;1HDEF\(CSI)3;1HGHI")
    vt.feed("\(CSI)?69h\(CSI)2;3s\(CSI)1;2H\(ESC)M")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\nDBC\nGEF\n HI"))
  }

  @Test("Terminal: reverseIndex outside left/right margins")
  func reverseIndexOutsideLeftRightMargins() {
    var vt = VT(5, 5)
    vt.feed("ABC\(CSI)2;1HDEF\(CSI)3;1HGHI")
    vt.feed("\(CSI)?69h\(CSI)2;3s\(CSI)1;1H\(ESC)M")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("ABC\nDEF\nGHI"))
  }

  // MARK: index

  @Test("Terminal: index")
  func index() {
    var vt = VT(2, 5)
    vt.feed("\(ESC)DA")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nA"))
  }

  @Test("Terminal: index from the bottom")
  func indexFromTheBottom() {
    var vt = VT(2, 5)
    vt.feed("\(CSI)5;1HA\(CSI)D\(ESC)DB")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\nA\nB"))
  }

  @Test("Terminal: index scrolling with hyperlink")
  func indexScrollingWithHyperlink() {
    var vt = VT(2, 5)
    vt.feed("\(CSI)5;1H\(t2Link)A\(t2Unlink)\(CSI)D\(ESC)DB")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\nA\nB"))
    let l3 = vt.cell(0, 3).attributes.link
    #expect(l3 != 0)
    let l4 = vt.cell(0, 4).attributes.link
    #expect(l4 == 0)
  }

  @Test("Terminal: index outside of scrolling region")
  func indexOutsideOfScrollingRegion() {
    var vt = VT(2, 5)
    var y = vt.cursor.y
    #expect(y == 0)
    vt.feed("\(CSI)2;5r\(ESC)D")
    y = vt.cursor.y
    #expect(y == 1)
  }

  @Test("Terminal: index from the bottom outside of scroll region")
  func indexFromTheBottomOutsideOfScrollRegion() {
    var vt = VT(2, 5)
    vt.feed("\(CSI)1;2r\(CSI)5;1HA\(ESC)DB")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\n\nAB"))
  }

  @Test("Terminal: index no scroll region, top of screen")
  func indexNoScrollRegionTopOfScreen() {
    var vt = VT(5, 5)
    vt.feed("A\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\n X"))
  }

  @Test("Terminal: index bottom of primary screen")
  func indexBottomOfPrimaryScreen() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)5;1HA\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\nA\n X"))
  }

  @Test("Terminal: index bottom of primary screen background sgr")
  func indexBottomOfPrimaryScreenBackgroundSgr() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)5;1HA\(t2RedBG)\(ESC)D")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\n\nA"))
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 4).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: index inside scroll region")
  func indexInsideScrollRegion() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;3rA\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\n X"))
  }

  @Test("Terminal: index bottom of scroll region with hyperlinks")
  func indexBottomOfScrollRegionWithHyperlinks() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;2rA\(ESC)D\r\(t2Link)B\(t2Unlink)\(ESC)D\rC")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("B\nC"))
    let l0 = vt.cell(0, 0).attributes.link
    #expect(l0 != 0)
    let l1 = vt.cell(0, 1).attributes.link
    #expect(l1 == 0)
  }

  @Test("Terminal: index bottom of scroll region clear hyperlinks")
  func indexBottomOfScrollRegionClearHyperlinks() {
    var vt = VT(5, 5, scrollback: 0)
    vt.feed("\(CSI)2;3r\(CSI)2;1H\(t2Link)A\(t2Unlink)\(ESC)D\rB\(ESC)D\rC")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nB\nC"))
    for y in 1 ..< 3 {
      let l = vt.cell(0, y).attributes.link
      #expect(l == 0, Comment(rawValue: escapedTestText("y=\(y)")))
    }
  }

  @Test("Terminal: index bottom of scroll region with background SGR")
  func indexBottomOfScrollRegionWithBackgroundSGR() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;3r\(CSI)4;1HB\(CSI)3;1HA\(t2RedBG)\(ESC)D")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nA\n\nB"))
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 2).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: index bottom of primary screen with scroll region")
  func indexBottomOfPrimaryScreenWithScrollRegion() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;3r\(CSI)3;1HA\(CSI)5;1H\(ESC)D\(ESC)D\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\nA\n\nX"))
  }

  @Test("Terminal: index outside left/right margin")
  func indexOutsideLeftRightMargin() {
    var vt = VT(10, 5)
    vt.feed("\(CSI)1;3r\(CSI)?69h\(CSI)4;6s")
    vt.feed("\(CSI)3;3HA\(CSI)3;1H\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n\nX A"))
  }

  @Test("Terminal: index inside left/right margin")
  func indexInsideLeftRightMargin() {
    var vt = VT(10, 5)
    vt.feed("AAAAAA\r\nAAAAAA\r\nAAAAAA")
    vt.feed("\(CSI)?69h\(CSI)1;3r\(CSI)1;3s\(CSI)3;1H\(ESC)D")
    let c = vt.cursor
    #expect(c.y == 2)
    #expect(c.x == 0)
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("AAAAAA\nAAAAAA\n   AAA"))
  }

  @Test("Terminal: index bottom of scroll region creates scrollback")
  func indexBottomOfScrollRegionCreatesScrollback() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;3r1\r\n2\r\n3\(CSI)4;1HX\(CSI)3;1H\(ESC)DY")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("2\n3\nY\nX"))
    let screen = t2Screen(vt)
    #expect(TestFixture(screen) == TestFixture("1\n2\n3\nY\nX"))
  }

  @Test("Terminal: index bottom of scroll region no scrollback")
  func indexBottomOfScrollRegionNoScrollback() {
    var vt = VT(5, 5, scrollback: 0)
    vt.feed("\(CSI)1;3r\(CSI)4;1HB\(CSI)3;1HA\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\nA\n X\nB"))
  }

  @Test("Terminal: index bottom of scroll region blank line preserves SGR")
  func indexBottomOfScrollRegionBlankLinePreservesSGR() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)1;3r1\r\n2\r\n3\(CSI)4;1HX\(CSI)3;1H\(t2RedBG)\(ESC)D")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("2\n3\n\nX"))
    let screen = t2Screen(vt)
    #expect(TestFixture(screen) == TestFixture("1\n2\n3\n\nX"))
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 2).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test(
    "Terminal: index bottom of scroll region with top margin and background SGR",
  )
  func indexBottomOfScrollRegionWithTopMarginAndBackgroundSGR() {
    var vt = VT(5, 5)
    vt.feed("1\r\n2\r\n3\r\n4\r\n5")
    vt.feed("\(CSI)2;4r\(CSI)4;1H\(t2RedBG)\(ESC)D")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("1\n3\n4\n\n5"))
    let y = vt.cursor.y
    #expect(y == 3)
    for x in 0 ..< 5 {
      let bg = vt.cell(x, 3).attributes.background
      #expect(bg == t2Red, Comment(rawValue: escapedTestText("x=\(x)")))
    }
  }

  @Test("Terminal: index bottom of alt screen full region")
  func indexBottomOfAltScreenFullRegion() {
    var vt = VT(5, 3)
    vt.feed("\(CSI)?1049h")
    vt.feed("A\r\nB\r\nC\(ESC)D\rD")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("B\nC\nD"))
    let hist = vt.state.grid.historyCount
    #expect(hist == 0)
    vt.feed("\(CSI)?1049l")
    let p = t2Plain(vt)
    #expect(p == "")
  }

  @Test("Terminal: index bottom of alt screen top region")
  func indexBottomOfAltScreenTopRegion() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?1049h")
    vt.feed("1\r\n2\r\n3\r\n4\r\n5")
    vt.feed("\(CSI)1;4r\(CSI)4;1H\(ESC)DX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("2\n3\n4\nX\n5"))
    let hist = vt.state.grid.historyCount
    #expect(hist == 0)
  }

  @Test("Terminal: scrollUp top region no scrollback")
  func scrollUpTopRegionNoScrollback() {
    var vt = VT(5, 5, scrollback: 0)
    vt.feed("A\r\nB\r\nC\r\nD\r\nE")
    vt.feed("\(CSI)1;3r\(CSI)S")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("B\nC\n\nD\nE"))
    let screen = t2Screen(vt)
    #expect(TestFixture(screen) == TestFixture("B\nC\n\nD\nE"))
  }

  // MARK: cursorUp / cursorLeft

  @Test("Terminal: cursorUp basic")
  func cursorUpBasic() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)3;1HA\(CSI)10AX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture(" X\n\nA"))
  }

  @Test("Terminal: cursorUp below top scroll margin")
  func cursorUpBelowTopScrollMargin() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)2;4r\(CSI)3;1HA\(CSI)5AX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("\n X\nA"))
  }

  @Test("Terminal: cursorUp above top scroll margin")
  func cursorUpAboveTopScrollMargin() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)3;5r\(CSI)3;1HA\(CSI)2;1H\(CSI)10AX")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("X\n\nA"))
  }

  @Test("Terminal: cursorUp resets wrap")
  func cursorUpResetsWrap() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)A")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "ABCDX")
  }

  @Test("Terminal: cursorLeft no wrap")
  func cursorLeftNoWrap() {
    var vt = VT(10, 5)
    vt.feed("A\r\nB\(CSI)10D")
    let s = t2Plain(vt)
    #expect(TestFixture(s) == TestFixture("A\nB"))
    let c = vt.cursor
    #expect(c.x == 0 && c.y == 1)
  }

  @Test("Terminal: cursorLeft unsets pending wrap state")
  func cursorLeftUnsetsPendingWrapState() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)D")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "ABCXE")
  }

  @Test("Terminal: cursorLeft unsets pending wrap state with longer jump")
  func cursorLeftUnsetsPendingWrapStateWithLongerJump() {
    var vt = VT(5, 5)
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)3D")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "AXCDE")
  }

  @Test("Terminal: cursorLeft reverse wrap with pending wrap state")
  func cursorLeftReverseWrapWithPendingWrapState() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?7h\(CSI)?45h")
    vt.feed("ABCDE")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)D")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "ABCDX")
  }

  @Test("Terminal: cursorLeft reverse wrap with pending wrap above top margin")
  func cursorLeftReverseWrapWithPendingWrapAboveTopMargin() {
    var vt = VT(5, 5)
    vt.feed("\(CSI)?7h\(CSI)?45h\(CSI)?69h")
    vt.feed("\(CSI)1;2s")
    vt.feed("AB")
    vt.feed("\(ESC)7")
    vt.feed("\(CSI)2;5s\(CSI)3;5r")
    vt.feed("\(ESC)8")
    var pw = vt.state.cursor.pendingWrap
    #expect(pw)
    vt.feed("\(CSI)D")
    pw = vt.state.cursor.pendingWrap
    #expect(!pw)
    let c = vt.cursor
    #expect(c.x == 1)
    #expect(c.y == 0)
    vt.feed("X")
    let s = t2Plain(vt)
    #expect(s == "AX")
  }
}
