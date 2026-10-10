import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct ViewTextInputTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  @Test(
    .enabled(if: hasMetal),
    arguments: [false, true],
    [KeyModifiers.control, .alt]
  )
  func `empty text commits preserve selection and latched modifiers`(
    _ composing: Bool,
    _ modifier: KeyModifiers
  ) throws {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    session.feed(Array("selected output".utf8))
    view.selectAll(nil)
    let selection = session.withState { $0.selection }
    try #require(selection != nil)
    view.sticky.tap(modifier)
    if composing {
      view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    }
    view.insertText("")
    _ = session.snapshot()
    #expect(view.hasSelection)
    #expect(session.withState { $0.selection } == selection)
    #expect(view.sticky.active == modifier)
    #expect(view.markedText.isEmpty && view.renderer.options.preedit.isEmpty)
    #expect(view.renderer.options.preeditSelection == nil)
    #expect(writes.withLock { $0.isEmpty })

    view.insertText("c")
    _ = session.snapshot()
    #expect(!view.hasSelection && session.withState { $0.selection == nil })
    #expect(view.sticky.active.isEmpty)
    #expect(
      writes.withLock { $0 } == [modifier == .control ? [0x03] : [0x1B, 0x63]]
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `composition renderer follows selection changes and configuration reloads`()
    throws
  {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 20, rows: 3)
    )
    view.setMarkedText("A👩‍💻Z", selectedRange: NSRange(location: 1, length: 5))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 1, length: 5)
    )
    view.setMarkedText("A👩‍💻Z", selectedRange: NSRange(location: 6, length: 0))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 6, length: 0)
    )
    view.selectedTextRange = TerminalTextRange(NSRange(location: 0, length: 1))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 0, length: 1)
    )
    view.apply(Configuration.parse("font-size=20"))
    #expect(
      view.renderer.options.preeditSelection == NSRange(location: 0, length: 1)
    )
    view.unmarkText()
    #expect(
      view.renderer.options.preeditSelection == nil
        && view.renderer.options.preedit.isEmpty
    )
  }

  @Test(.enabled(if: hasMetal))
  func `composition selection rectangles enclose rendered graphemes`() throws {
    let session = TerminalSession(columns: 20, rows: 3)
    session.feed(Array("\u{1B}[2;4H".utf8))
    let view = try TerminalUIView(session: session)
    view.lastCursor = session.snapshot().cursor
    view.setMarkedText(
      "A👩‍💻e\u{301}Z",
      selectedRange: NSRange(location: 1, length: 5)
    )
    let selected = try #require(view.selectedTextRange)
    let rectangles = view.selectionRects(for: selected)
    let rectangle = try #require(rectangles.first)
    #expect(rectangles.count == 1)
    #expect(rectangle.rect == view.firstRect(for: selected))
    #expect(rectangle.containsStart && rectangle.containsEnd)
    #expect(rectangle.writingDirection == .leftToRight && !rectangle.isVertical)
    let cell = view.geometry.rect(column: 4, row: 1)
    #expect(
      rectangle.rect.minX == cell.minX && rectangle.rect.minY == cell.minY
    )
    #expect(
      rectangle.rect.width == cell.width * 2
        && rectangle.rect.height == cell.height
    )
    #expect(
      view.selectionRects(
        for: TerminalTextRange(NSRange(location: 1, length: 0))
      )
      .isEmpty
    )
    #expect(
      view.selectionRects(
        for: TerminalTextRange(NSRange(location: .max, length: .max))
      )
      .isEmpty
    )
    view.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.selectionRects(for: selected).isEmpty)
  }

  @Test(.enabled(if: hasMetal))
  func
    `composition hit testing follows graphemes and respects restricted ranges`()
    throws
  {
    let session = TerminalSession(columns: 20, rows: 3)
    session.feed(Array("\u{1B}[2;4H".utf8))
    let view = try TerminalUIView(session: session)
    view.lastCursor = session.snapshot().cursor
    view.setMarkedText(
      "A👩‍💻e\u{301}Z",
      selectedRange: NSRange(location: 0, length: 0)
    )
    let cell = view.geometry.rect(column: 3, row: 1)
    func point(_ column: CGFloat) -> CGPoint {
      CGPoint(x: cell.minX + column * cell.width, y: cell.midY)
    }
    for (column, expected): (CGFloat, Int) in [
      (-1, 0), (0.2, 0), (0.8, 1), (1.8, 1), (2.2, 6), (3.2, 6), (3.8, 8),
      (8, 9),
    ] {
      let position = try #require(view.closestPosition(to: point(column)))
      #expect(
        view.offset(from: view.beginningOfDocument, to: position) == expected
      )
    }
    for column: CGFloat in [1.2, 2.8] {
      let range = try #require(view.characterRange(at: point(column)))
      #expect(TestFixture(view.text(in: range)) == TestFixture("👩‍💻"))
    }
    #expect(view.characterRange(at: point(-1)) == nil)
    #expect(view.characterRange(at: point(8)) == nil)
    #expect(
      view.characterRange(
        at: CGPoint(x: point(1).x, y: cell.minY - cell.height)
      ) == nil
    )
    let range = TerminalTextRange(NSRange(location: 1, length: 5))
    let first = try #require(view.closestPosition(to: point(-1), within: range))
    let last = try #require(view.closestPosition(to: point(8), within: range))
    #expect(view.offset(from: view.beginningOfDocument, to: first) == 1)
    #expect(view.offset(from: view.beginningOfDocument, to: last) == 6)
    for point in [
      CGPoint(x: .nan, y: cell.midY), CGPoint(x: .infinity, y: cell.midY),
      CGPoint(x: cell.minX, y: .nan),
    ] {
      #expect(view.closestPosition(to: point) == nil)
      #expect(view.closestPosition(to: point, within: range) == nil)
      #expect(view.characterRange(at: point) == nil)
    }
    let invalid = TerminalTextRange(NSRange(location: .max, length: .max))
    #expect(view.closestPosition(to: point(0), within: invalid) == nil)
    view.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.closestPosition(to: point(0), within: range) == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `empty composition rejects stale replacement ranges`() throws {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.setMarkedText("ab", selectedRange: NSRange(location: 0, length: 0))
    let stale = try #require(view.markedTextRange)
    view.unmarkText()
    _ = session.snapshot()
    writes.withLock { $0.removeAll() }
    view.replace(stale, withText: "stale")
    for range in [
      NSRange(location: 1, length: 0), NSRange(location: .max, length: 1),
    ] { view.replace(TerminalTextRange(range), withText: "invalid") }
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    view.replace(
      TerminalTextRange(NSRange(location: 0, length: 0)),
      withText: "漢"
    )
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array("漢".utf8))
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (
        NSRange(location: NSNotFound, length: 0),
        NSRange(location: 4, length: 0)
      ),
      (NSRange(location: .max, length: .max), NSRange(location: 4, length: 0)),
      (NSRange(location: .min, length: 1), NSRange(location: 0, length: 1)),
      (NSRange(location: 3, length: .max), NSRange(location: 3, length: 1)),
      (NSRange(location: 1, length: -1), NSRange(location: 1, length: 0)),
      (NSRange(location: 0, length: .max), NSRange(location: 0, length: 4)),
      (NSRange(location: 4, length: 1), NSRange(location: 4, length: 0)),
    ]
  )
  func `marked text selections stay within the composition`(
    _ input: NSRange,
    _ expected: NSRange
  ) throws {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.setMarkedText("A😀B", selectedRange: input)
    #expect((view.selectedTextRange as? TerminalTextRange)?.range == expected)
    // A selection-only update must validate the new range too.
    view.setMarkedText("A😀B", selectedRange: NSRange(location: 0, length: 0))
    view.setMarkedText("A😀B", selectedRange: input)
    #expect((view.selectedTextRange as? TerminalTextRange)?.range == expected)
    let selected = try #require(view.selectedTextRange as? TerminalTextRange)
    try #require(selected.range == expected)
    #expect(
      (selected.end as? TerminalTextPosition)?.offset == expected.location
        + expected.length
    )
    #expect(TestFixture(view.text(in: selected)) != TestFixture(nil))
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    view.unmarkText()
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array("A😀B".utf8))
    #expect(
      (view.selectedTextRange as? TerminalTextRange)?.range
        == NSRange(location: 0, length: 0)
    )
  }

  @Test(.enabled(if: hasMetal))
  func `text navigation rejects expired positions and overflowing offsets`()
    throws
  {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 20, rows: 2)
    )
    view.setMarkedText("A😀B", selectedRange: NSRange(location: 4, length: 0))
    let beginning = view.beginningOfDocument
    let end = view.endOfDocument
    let middle = try #require(view.position(from: beginning, offset: 3))
    #expect(
      try view.compare(
        #require(view.position(from: middle, offset: -3)),
        to: beginning
      ) == .orderedSame
    )
    #expect(
      try view.compare(
        #require(view.position(from: middle, in: .right, offset: 1)),
        to: end
      ) == .orderedSame
    )
    let reversed = try #require(view.textRange(from: end, to: beginning))
    #expect(
      (reversed as? TerminalTextRange)?.range == NSRange(location: 0, length: 4)
    )
    #expect(
      view.textRange(from: beginning, to: TerminalTextPosition(-1)) == nil
    )
    #expect(view.textRange(from: beginning, to: TerminalTextPosition(5)) == nil)
    view.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.textRange(from: beginning, to: end) == nil)
    #expect(view.position(from: end, offset: -3) == nil)
    #expect(view.position(within: reversed, farthestIn: .right) == nil)
    view.selectedTextRange = reversed
    #expect(
      (view.selectedTextRange as? TerminalTextRange)?.range
        == NSRange(location: 1, length: 0)
    )
    #expect(view.position(from: view.endOfDocument, offset: .max) == nil)
    #expect(
      view.position(from: view.beginningOfDocument, in: .left, offset: .min)
        == nil
    )
    #expect(view.position(from: view.endOfDocument, offset: .min) == nil)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (
        "😀ab", NSRange(location: 4, length: 0), "😀a",
        NSRange(location: 3, length: 0)
      ),
      (
        "😀ab", NSRange(location: 2, length: 1), "😀b",
        NSRange(location: 2, length: 0)
      ),
      (
        "😀ab", NSRange(location: 0, length: 0), "😀ab",
        NSRange(location: 0, length: 0)
      ),
      (
        "👩‍💻ab", NSRange(location: 5, length: 0), "ab",
        NSRange(location: 0, length: 0)
      ),
      (
        "e\u{301}", NSRange(location: 2, length: 0), "",
        NSRange(location: 0, length: 0)
      ),
    ]
  )
  func `backspace edits marked text without reaching the terminal`(
    _ text: String,
    _ selection: NSRange,
    _ expected: String,
    _ expectedSelection: NSRange,
  ) throws {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.setMarkedText(text, selectedRange: selection)
    view.deleteBackward()
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(
      view.markedText == expected
        && view.renderer.options.preedit == Array(expected.unicodeScalars)
    )
    #expect(
      (view.selectedTextRange as? TerminalTextRange)?.range == expectedSelection
    )
    view.unmarkText()
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array(expected.utf8))
    if expected.isEmpty {
      // Once composition is empty, backspace reaches the shell again.
      view.deleteBackward()
      _ = session.snapshot()
      #expect(writes.withLock { $0 } == [0x7F])
    }
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (
        NSRange(location: 4, length: 0), NSRange(location: 2, length: 1), "中",
        "😀中b", NSRange(location: 4, length: 0)
      ),
      (
        NSRange(location: 4, length: 0), NSRange(location: 2, length: 1),
        "e\u{301}", "😀e\u{301}b", NSRange(location: 5, length: 0)
      ),
      (
        NSRange(location: 0, length: 0), NSRange(location: 2, length: 1), "中",
        "😀中b", NSRange(location: 0, length: 0)
      ),
      (
        NSRange(location: 2, length: 1), NSRange(location: 2, length: 1), "中",
        "😀中b", NSRange(location: 3, length: 0)
      ),
      (
        NSRange(location: 2, length: 0), NSRange(location: 2, length: 0), "X",
        "😀Xab", NSRange(location: 3, length: 0)
      ),
      (
        NSRange(location: 4, length: 0), NSRange(location: 2, length: 1), "",
        "😀b", NSRange(location: 3, length: 0)
      ),
      (
        NSRange(location: 4, length: 0), NSRange(location: 0, length: 4), "",
        "", NSRange(location: 0, length: 0)
      ),
      (
        NSRange(location: 4, length: 0), NSRange(location: 8, length: 1), "X",
        "😀ab", NSRange(location: 4, length: 0)
      ),
      (
        NSRange(location: 4, length: 0), NSRange(location: 1, length: 1), "X",
        "😀ab", NSRange(location: 4, length: 0)
      ),
    ]
  )
  func `replacing a marked text range preserves uncommitted composition`(
    _ selection: NSRange,
    _ range: NSRange,
    _ text: String,
    _ expected: String,
    _ expectedSelection: NSRange,
  ) throws {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.setMarkedText("😀ab", selectedRange: selection)
    view.replace(TerminalTextRange(range), withText: text)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(
      view.markedText == expected
        && view.renderer.options.preedit == Array(expected.unicodeScalars)
    )
    #expect(
      (view.selectedTextRange as? TerminalTextRange)?.range == expectedSelection
    )
    view.unmarkText()
    _ = session.snapshot()
    #expect(writes.withLock { $0 } == Array(expected.utf8))
    #expect(view.markedTextRange == nil)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      ("e\u{301}", 1), ("中", 2), ("👩‍💻", 2), ("🇻🇳", 2), ("❤\u{FE0F}", 2),
      ("⌚\u{FE0E}", 1),
    ]
  )
  func `IME rectangles follow rendered grapheme columns`(
    _ prefix: String,
    _ columns: Int
  ) throws {
    let session = TerminalSession(columns: 20, rows: 3)
    session.feed(Array("\u{1B}[2;4H".utf8))
    let view = try TerminalUIView(session: session)
    view.lastCursor = session.snapshot().cursor
    view.setMarkedText(
      prefix + "X",
      selectedRange: NSRange(location: prefix.utf16.count, length: 0)
    )
    let origin = view.geometry.rect(column: 3, row: 1)
    let position = try #require(
      view.position(from: view.beginningOfDocument, offset: prefix.utf16.count)
    )
    let caret = view.caretRect(for: position)
    #expect(
      abs(caret.minX - (origin.minX + CGFloat(columns) * origin.width)) < 0.001
    )
    let suffix = try #require(
      view.textRange(from: position, to: view.endOfDocument)
    )
    let rectangle = view.firstRect(for: suffix)
    #expect(abs(rectangle.minX - caret.minX) < 0.001)
    #expect(abs(rectangle.width - origin.width) < 0.001)
    let whole = try #require(view.markedTextRange)
    #expect(
      abs(
        view.firstRect(for: whole).width - CGFloat(columns + 1) * origin.width
      ) < 0.001
    )
    let partial = TerminalTextRange(NSRange(location: 0, length: 1))
    #expect(
      abs(view.firstRect(for: partial).width - CGFloat(columns) * origin.width)
        < 0.001
    )
    #expect(caret.minY == origin.minY && rectangle.minY == origin.minY)
  }
}
#endif
