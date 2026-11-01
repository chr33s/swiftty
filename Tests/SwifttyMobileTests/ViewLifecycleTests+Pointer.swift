import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

extension ViewLifecycleTests {
  @Test(.enabled(if: hasMetal))
  func `hover below a scrolled viewport does not target an invisible URL`()
    throws
  {
    let session = TerminalSession(columns: 24, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(
      Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nhttps://example.com".utf8)
    )
    session.scrollViewport(by: 1)
    view.draw(in: view)
    let rect = view.geometry.rect(column: 1, row: 2)
    view.refreshHoveredLink(at: CGPoint(x: rect.midX, y: rect.midY))
    #expect(!view.overLink)
    #expect(view.renderer.options.underlinedSpan == nil)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["resize", "reset", "evict", "height"]
  )
  func `selection drags reject an origin invalidated before the next frame`(
    _ change: String
  ) throws {
    var configuration = SessionConfiguration()
    configuration.scrollbackLimitRows = 0
    let session = TerminalSession(
      columns: 10,
      rows: 2,
      configuration: configuration
    )
    let view = try TerminalUIView(session: session)
    session.feed(Array("abcd".utf8))
    let start = view.geometry.rect(column: 0, row: 0)
    view.beginSelection(
      at: CGPoint(x: start.midX, y: start.midY),
      unit: change == "height" ? .word : .cell,
      rectangle: false
    )
    if change == "resize" {
      session.resize(columns: 20, rows: 2)
    } else if change == "height" {
      session.resize(columns: 10, rows: 3)
    } else if change == "reset" {
      session.reset()
      session.feed(Array("wxyz".utf8))
    } else {
      session.feed(Array("\r\nrow1\r\nrow2\r\nrow3".utf8))
    }
    let end = view.geometry.rect(column: 2, row: 0)
    view.extendSelection(
      to: CGPoint(x: end.midX, y: end.midY),
      rectangle: false
    )
    #expect(
      session.withState { $0.selectionText }
        == (change == "height" ? "abcd" : nil)
    )
    #expect(view.selectionOrigin == nil)
    #expect(view.hasSelection == (change == "height"))
  }

  @Test(.enabled(if: hasMetal), arguments: [-1, 2])
  func `selection begins on the nearest visible row outside a scrolled grid`(
    _ row: Int
  ) throws {
    let session = TerminalSession(columns: 4, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
    session.scrollViewport(by: 1)
    view.draw(in: view)
    let expectedRow = session.withState {
      $0.absoluteRow(viewportRow: row < 0 ? 0 : 1)
    }
    let rect = view.geometry.rect(column: 0, row: row)
    view.beginSelection(
      at: CGPoint(x: rect.midX, y: rect.midY),
      unit: .word,
      rectangle: false
    )
    #expect(session.withState { $0.selection?.start.row } == expectedRow)
    #expect(session.withState { $0.selectionText } == "row\(expectedRow)")
    view.endSelection()
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `selection release outside the view does not add an automatic scroll step`(
      _ longPress: Bool
    ) throws
  {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    defer { view.editMenu.dismissMenu() }
    session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
    view.draw(in: view)
    let pan = ReviewScrollGesture()
    let press = ReviewLongPressGesture()
    func select(_ state: UIGestureRecognizer.State, at point: CGPoint) {
      if longPress {
        press.point = point
        press.state = state
        _ = view.perform(NSSelectorFromString("handleLongPress:"), with: press)
      } else {
        pan.point = point
        pan.state = state
        _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
      }
    }
    let rect = view.geometry.rect(column: 0, row: 0)
    select(.began, at: CGPoint(x: rect.midX, y: rect.midY))
    let outside = CGPoint(x: rect.midX, y: -view.geometry.lineHeight)
    select(.changed, at: outside)
    let offset = session.snapshot().viewportOffset
    try #require(offset > 0)
    select(.ended, at: outside)
    #expect(session.snapshot().viewportOffset == offset)
  }

  @Test(.enabled(if: hasMetal))
  func `stationary hover follows scrollback and link detection settings`()
    throws
  {
    let session = TerminalSession(columns: 20, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(Array("https://a.test\r\nplain1\r\nplain2\r\nplain3".utf8))
    view.draw(in: view)
    let hover = ReviewHoverGesture()
    let rect = view.geometry.rect(column: 0, row: 0)
    hover.point = CGPoint(x: rect.midX, y: rect.midY)
    hover.state = .began
    _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
    #expect(!view.overLink)
    session.scrollViewport(by: 2)
    view.draw(in: view)
    #expect(view.overLink && view.renderer.options.underlinedSpan != nil)
    view.apply(Configuration.configured([("link-url", "false")]))
    #expect(!view.overLink && view.renderer.options.underlinedSpan == nil)
    view.apply(Configuration.configured([("link-url", "true")]))
    #expect(view.overLink && view.renderer.options.underlinedSpan != nil)
    session.scrollViewport(by: -2)
    view.draw(in: view)
    #expect(!view.overLink && view.renderer.options.underlinedSpan == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `hover follows content tracking modes and modifier changes`() throws {
    let session = TerminalSession(columns: 20, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(
      Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8)
    )
    view.draw(in: view)
    let hover = ReviewHoverGesture()
    let rect = view.geometry.rect(column: 0, row: 0)
    hover.point = CGPoint(x: rect.midX, y: rect.midY)
    hover.state = .began
    _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
    #expect(view.overLink && view.renderer.options.hoveredLink != 0)
    session.feed(Array("\u{1B}[?1000h".utf8))
    view.draw(in: view)
    #expect(!view.overLink && view.renderer.options.hoveredLink == 0)
    session.feed(Array("\u{1B}[?1000l".utf8))
    view.draw(in: view)
    #expect(view.overLink && view.renderer.options.hoveredLink != 0)
    session.feed(Array("\r\u{1B}[2Kplain".utf8))
    view.draw(in: view)
    #expect(!view.overLink && view.renderer.options.hoveredLink == 0)

    session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    hover.state = .changed
    _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
    hover.flags = .control
    _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
    _ = session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(["\u{1B}[<35;1;1M", "\u{1B}[<51;1;1M"])
    )
    hover.state = .ended
    _ = view.perform(NSSelectorFromString("handleHover:"), with: hover)
    #expect(view.hoverCell == nil && !view.overLink)
  }

  @Test(.enabled(if: hasMetal))
  func `long press selection includes the release location`() throws {
    let session = TerminalSession(columns: 20, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("one two three".utf8))
    view.draw(in: view)
    let press = ReviewLongPressGesture()
    func select(_ state: UIGestureRecognizer.State, at column: Int) {
      let rect = view.geometry.rect(column: column, row: 0)
      press.point = CGPoint(x: rect.midX, y: rect.midY)
      press.state = state
      _ = view.perform(NSSelectorFromString("handleLongPress:"), with: press)
    }
    select(.began, at: 1)
    #expect(session.withState { $0.selectionText } == "one")
    select(.changed, at: 5)
    #expect(session.withState { $0.selectionText } == "one two")
    select(.ended, at: 9)
    #expect(session.withState { $0.selectionText } == "one two three")
    #expect(view.selectionOrigin == nil)
    view.editMenu.dismissMenu()
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `pointer selection retains its local gesture after Shift is released or output clears it`(
      _ clear: Bool
    ) throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("abcd\u{1B}[?1003h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let pan = ReviewScrollGesture()
    func drag(_ state: UIGestureRecognizer.State, to column: Int) {
      let rect = view.geometry.rect(column: column, row: 0)
      pan.point = CGPoint(x: rect.midX, y: rect.midY)
      pan.state = state
      _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
    }
    pan.flags = .shift
    drag(.began, to: 0)
    drag(.changed, to: 1)
    #expect(session.withState { $0.selectionText } == "ab")
    if clear {
      session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
      view.draw(in: view)
    }
    pan.flags = []
    drag(.changed, to: 2)
    drag(.ended, to: 3)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(session.withState { $0.selectionText } == (clear ? nil : "abcd"))
    drag(.began, to: 0)
    drag(.ended, to: 0)
    _ = session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(["\u{1B}[<0;1;1M", "\u{1B}[<0;1;1m"])
    )
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [9, 1000, 1002, 1003],
    [
      (0, 0, UIGestureRecognizer.State.ended), (2, 1, .ended), (-2, -1, .ended),
      (0, 0, .cancelled), (2, 1, .cancelled), (-2, -1, .cancelled),
    ],
  )
  func `reported pointer drags include their start and initial motion`(
    _ mode: Int,
    _ fixture: (Int, Int, UIGestureRecognizer.State),
  ) throws {
    let session = TerminalSession(columns: 10, rows: 5)
    let view = try TerminalUIView(session: session)
    session.feed(Array("\u{1B}[?\(mode)h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let pan = ReviewScrollGesture()
    let (dx, dy, ending) = fixture
    let origin = view.geometry.rect(column: 4, row: 2)
    let current = view.geometry.rect(column: 4 + dx, row: 2 + dy)
    pan.point = CGPoint(x: current.midX, y: current.midY)
    pan.distance = CGPoint(
      x: current.midX - origin.midX,
      y: current.midY - origin.midY
    )
    pan.state = .began
    _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
    pan.state = ending
    _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
    _ = session.snapshot()
    var expected = ["\u{1B}[<0;5;3M"]
    if mode >= 1002, dx != 0 || dy != 0 {
      expected.append("\u{1B}[<32;\(5 + dx);\(3 + dy)M")
    }
    if mode != 9 { expected.append("\u{1B}[<0;\(5 + dx);\(3 + dy)m") }
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(expected)
    )
    #expect(!view.reportsPointerMouseGesture && view.selectionOrigin == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `pointer selection includes the release location`() throws {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("abcdef".utf8))
    view.draw(in: view)
    let pan = ReviewScrollGesture()
    func drag(_ state: UIGestureRecognizer.State, to column: Int) {
      let rect = view.geometry.rect(column: column, row: 0)
      pan.point = CGPoint(x: rect.midX, y: rect.midY)
      pan.state = state
      _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
    }
    drag(.began, to: 0)
    drag(.changed, to: 1)
    #expect(session.withState { $0.selectionText } == "ab")
    drag(.ended, to: 4)
    #expect(session.withState { $0.selectionText } == "abcde")
    #expect(view.selectionOrigin == nil)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [UIGestureRecognizer.State.began, .ended]
  )
  func `scroll gesture boundary events consume their remaining movement`(
    _ state: UIGestureRecognizer.State
  ) throws {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let pan = ReviewScrollGesture()
    pan.point = view.geometry.rect(column: 0, row: 0).origin
    pan.state = state
    pan.distance = CGPoint(
      x: -2 * view.geometry.cellSize.width / view.geometry.scale,
      y: 2 * view.geometry.lineHeight,
    )
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    _ = session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      )
        == TestFixture([
          "\u{1B}[<64;1;1M", "\u{1B}[<64;1;1M", "\u{1B}[<67;1;1M",
          "\u{1B}[<67;1;1M",
        ])
    )
    #expect(pan.distance == .zero)
    #expect(!view.momentum.isActive)
    #expect(!view.horizontalMomentum.isActive)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [UIGestureRecognizer.State.cancelled, .failed]
  )
  func
    `cancelled scrolling discards fractional movement without starting momentum`(
      _ state: UIGestureRecognizer.State
    ) throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.scroll(lines: 0.5, columns: 0.5, at: .zero)
    let pan = ReviewScrollGesture()
    pan.state = state
    pan.distance = CGPoint(x: 100, y: 100)
    pan.speed = CGPoint(x: 100, y: 100)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    #expect(view.scrollAccumulator.remainder == 0)
    #expect(view.horizontalScrollAccumulator.remainder == 0)
    #expect(!view.momentum.isActive)
    #expect(!view.horizontalMomentum.isActive)
    view.scroll(lines: 0.75, columns: 0.75, at: .zero)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal), arguments: [-1, 1])
  func
    `horizontal scroll gestures report both axes and retain fractional movement`(
      _ direction: Int
    ) throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let pan = ReviewScrollGesture()
    let width = view.geometry.cellSize.width / view.geometry.scale
    let point = view.geometry.rect(column: 0, row: 0).origin
    pan.point = point
    pan.state = .began
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    pan.state = .changed
    pan.distance = CGPoint(
      x: CGFloat(direction) * width * 0.75,
      y: view.geometry.lineHeight * 2
    )
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    _ = session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(Array(repeating: "\u{1B}[<64;1;1M", count: 2, ))
    )
    pan.distance = CGPoint(x: CGFloat(direction) * width * 0.75, y: 0)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    _ = session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      )
        == TestFixture([
          "\u{1B}[<64;1;1M", "\u{1B}[<64;1;1M",
          "\u{1B}[<\(direction > 0 ? 66 : 67);1;1M",
        ])
    )
    #expect(pan.distance == .zero)
    pan.speed = CGPoint(x: CGFloat(direction) * width * 10, y: 0)
    pan.state = .ended
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    #expect(!view.momentum.isActive)
    #expect(view.horizontalMomentum.isActive)
    view.stopMomentum()
    #expect(!view.horizontalMomentum.isActive)

    writes.withLock { $0.removeAll() }
    session.feed(Array("\u{1B}[?1000l".utf8))
    view.draw(in: view)
    pan.state = .changed
    pan.distance = CGPoint(x: CGFloat(direction) * width, y: 0)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    #expect(view.horizontalScrollAccumulator.remainder == 0)
    session.feed(Array("\u{1B}[?1000h".utf8))
    view.draw(in: view)
    pan.distance = CGPoint(x: CGFloat(direction) * width * 0.75, y: 0)
    _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `output clearing selection disables copy and ends its drag`(
    _ extendBeforeFrame: Bool
  ) throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(Array("abc".utf8))
    view.selectAll(nil)
    let point = TerminalPoint(row: 0, column: 0)
    view.selectionOrigin = (
      point, point, session.withState { $0.addressingGeneration }
    )
    #expect(view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
    session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
    _ = session.snapshot()
    // Menu validation can happen before the next frame.
    #expect(!view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
    if extendBeforeFrame {
      view.extendSelection(to: .zero, rectangle: false)
      #expect(session.withState { $0.selection == nil })
    }
    view.draw(in: view)
    #expect(!view.hasSelection)
    #expect(view.selectionOrigin == nil)
    view.selectionOrigin = (
      point, point, session.withState { $0.addressingGeneration }
    )
    view.draw(in: view)
    #expect(view.selectionOrigin != nil)
  }
}

#endif
