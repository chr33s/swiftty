import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// VoiceOver throttling and text caching, and render options surviving a
/// configuration reload, in the macOS view.
extension ViewBehaviorTests {
  @Test(
    .enabled(if: hasMetal),
    arguments: [
      CGFloat.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
      CGFloat(Int.max), CGFloat(Int.min),
    ],
    [false, true]
  )
  func `invalid wheel distances preserve progress in both scroll routes`(
    _ distance: CGFloat,
    _ tracking: Bool
  ) throws {
    let view = try makeView()
    view.session.resize(columns: 10, rows: 2)
    view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3".utf8))
    if tracking { view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8)) }
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let event = ReviewScrollEvent()
    event.distance = 0.4
    view.scrollWheel(with: event)
    event.distance = distance
    view.scrollWheel(with: event)
    #expect(view.scrollAccumulator.remainder == 0.4)
    #expect(view.horizontalScrollAccumulator.remainder == (tracking ? 0.4 : 0))
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    event.distance = 0.6
    view.scrollWheel(with: event)
    let snapshot = view.session.snapshot()
    if tracking {
      #expect(writes.withLock { $0.count } == 2)
    } else {
      #expect(snapshot.viewportOffset == 1)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `search controls hide terminal links and mouse motion reports`() throws {
    let view = try makeView()
    let window = InteractionTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    view.session.feed(
      Array(
        ("\u{1B}]8;;https://a.test\u{1B}\\" + String(repeating: "x", count: 200))
          .utf8
      )
    )
    view.draw(in: view)
    view.showSearch(text: "x")
    view.draw(in: view)
    let bar = try #require(view.searchBar)
    let location = view.convert(
      NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY),
      from: bar.field
    )
    let hit = try #require(view.hitTest(location))
    #expect(hit === bar.field || hit.isDescendant(of: bar.field))
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: view.convert(location, to: nil),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    #expect(view.link(for: event) != nil)
    view.mouseMoved(with: event)
    #expect(view.hoveredLink == nil && view.renderer.options.hoveredLink == 0)
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    view.mouseMoved(with: event)
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    let exposed = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(x: 20, y: location.y),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    view.mouseMoved(with: exposed)
    _ = view.session.snapshot()
    #expect(writes.withLock { !$0.isEmpty })
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `modifier changes preserve the pointer location with terminal or search focus`(
      _ searching: Bool
    ) throws
  {
    _ = NSApplication.shared
    var config = Configuration()
    config.command = "/bin/sleep 30"
    let controller = try TerminalWindowController(configuration: config)
    let window = try #require(controller.window)
    defer { window.close() }
    let view = controller.terminal
    if searching { view.showSearch(text: "link") }
    let responder = try #require(window.firstResponder)
    view.session.feed(Array("https://a.test".utf8))
    // This test supplies an admitted snapshot to isolate responder routing
    // from window-server visibility; display admission has separate tests.
    view.lastSnapshot = view.session.snapshot()
    let scale = window.backingScaleFactor
    let location = NSPoint(
      x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
        / scale,
      y: view.bounds.height
        - (view.renderer.options.paddingY + view.renderer.cellSize.height / 2)
          / scale,
    )
    let motion = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    view.mouseMoved(with: motion)
    #expect(view.hoveredLink == nil)
    for flags: NSEvent.ModifierFlags in [.command, []] {
      let event = try #require(
        NSEvent.keyEvent(
          with: .flagsChanged,
          location: .zero,
          modifierFlags: flags,
          timestamp: 0,
          windowNumber: window.windowNumber,
          context: nil,
          characters: "",
          charactersIgnoringModifiers: "",
          isARepeat: false,
          keyCode: 55,
        )
      )
      responder.flagsChanged(with: event)
      #expect((view.hoveredLink != nil) == flags.contains(.command))
      #expect(view.hoverEvent?.locationInWindow == location)
      view.lastSnapshot = view.session.snapshot()
      #expect((view.hoveredLink != nil) == flags.contains(.command))
    }
    view.mouseExited(with: motion)
    let command = try #require(
      NSEvent.keyEvent(
        with: .flagsChanged,
        location: location,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: 55,
      )
    )
    responder.flagsChanged(with: command)
    #expect(view.hoverEvent == nil && view.hoveredLink == nil)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `window deactivation clears command hover even while search owns focus`(
    _ searching: Bool
  ) throws {
    let view = try makeView()
    let window = InteractionTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    #expect(window.makeFirstResponder(view))
    if searching {
      view.showSearch(text: "link")
      #expect(window.firstResponder !== view)
    }
    view.session.feed(Array("https://a.test".utf8))
    view.draw(in: view)
    let scale = window.backingScaleFactor
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / scale,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / scale,
        ),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    view.updateHover(event)
    #expect(view.hoveredLink != nil)
    NotificationCenter.default.post(
      name: NSWindow.didResignKeyNotification,
      object: window
    )
    #expect(
      view.hoveredLink == nil && view.hoverEvent == nil
        && view.renderer.options.underlinedSpan == nil
    )
    NotificationCenter.default.post(
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
    view.draw(in: view)
    #expect(view.hoveredLink == nil)
    view.updateHover(event)
    #expect(view.hoveredLink != nil)
    if searching { view.closeSearch() } else { view.showSearch(text: "link") }
    #expect(view.hoveredLink == nil && view.hoverEvent == nil)
  }

  @Test(.enabled(if: hasMetal))
  func
    `inactive views do not change the current pointer while refreshing hover`()
    throws
  {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 320, height: 240))
    view.session.feed(Array("https://a.test".utf8))
    view.draw(in: view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / 2,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / 2,
        ),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    let previous = NSCursor.current
    defer { previous.set() }
    NSCursor.crosshair.set()
    view.updateHover(event)
    #expect(view.hoveredLink != nil)
    #expect(NSCursor.current === NSCursor.crosshair)
  }

  @Test(.enabled(if: hasMetal))
  func `stationary command hover follows output settings and pointer exit`()
    throws
  {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 400, height: 200))
    view.session.feed(
      Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8)
    )
    view.draw(in: view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / 2,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / 2,
        ),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    view.updateHover(event)
    #expect(view.hoveredLink != nil && view.renderer.options.hoveredLink != 0)
    view.session.feed(Array("\r\u{1B}[2Khttps://a.test".utf8))
    view.draw(in: view)
    #expect(
      view.hoveredLink?.url == "https://a.test"
        && view.renderer.options.underlinedSpan != nil
    )
    view.apply(Configuration.parse("link-url=false"))
    #expect(
      view.hoveredLink == nil && view.renderer.options.underlinedSpan == nil
    )
    view.apply(Configuration.parse("link-url=true"))
    #expect(view.hoveredLink?.url == "https://a.test")
    view.mouseExited(with: event)
    #expect(
      view.hoveredLink == nil && view.renderer.options.underlinedSpan == nil
    )
  }

  @Test(.enabled(if: hasMetal))
  func `command hover updates a wrapped URL span as the viewport moves`() throws
  {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 400, height: 200))
    view.session.mutate { $0.resize(columns: 10, rows: 2) }
    let url = "https://example.com/abcdefghijklmno"
    view.session.feed(Array(url.utf8))
    view.draw(in: view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / 2,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / 2,
        ),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0,
      )
    )
    view.updateHover(event)
    #expect(view.hoveredLink?.url == url)
    let link = try #require(view.hoveredLink)
    let before = try #require(view.renderer.options.underlinedSpan)
    view.session.scrollViewport(by: 1)
    view.draw(in: view)
    #expect(view.hoveredLink == link)
    let after = try #require(view.renderer.options.underlinedSpan)
    #expect(after.startRow == before.startRow + 1)
    #expect(after.endRow == before.endRow + 1)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `selection reaches the mouse up cell while plain clicks remain unselected`(
      _ dragged: Bool
    ) throws
  {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 400, height: 200))
    view.session.feed(Array("abcdef".utf8))
    view.draw(in: view)
    func event(_ type: NSEvent.EventType, column: Int) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type,
          location: NSPoint(
            x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5)
              * view.renderer.cellSize.width)
              / 2,
            y: view.bounds.height
              - (view.renderer.options.paddingY + view.renderer.cellSize.height
                / 2) / 2,
          ),
          modifierFlags: [],
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: 0,
        )
      )
    }
    try view.mouseDown(with: event(.leftMouseDown, column: 0))
    if dragged {
      try view.mouseDragged(with: event(.leftMouseDragged, column: 1))
      #expect(view.session.withState { $0.selectionText } == "ab")
    }
    try view.mouseUp(with: event(.leftMouseUp, column: dragged ? 4 : 0))
    #expect(
      view.session.withState { $0.selectionText } == (dragged ? "abcde" : nil)
    )
    #expect(view.selectionOrigin == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `releasing an edge drag does not add an automatic scroll step`() throws {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 400, height: 200))
    view.session.mutate { $0.resize(columns: 10, rows: 2) }
    view.session.feed(Array("row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4".utf8))
    view.draw(in: view)
    func event(_ type: NSEvent.EventType, outside: Bool) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type,
          location: NSPoint(
            x: (view.renderer.options.paddingX + view.renderer.cellSize.width
              / 2) / 2,
            y: outside
              ? view.bounds.height + view.renderer.cellSize.height
              : view.bounds.height
                - (view.renderer.options.paddingY + view.renderer.cellSize
                  .height / 2) / 2,
          ),
          modifierFlags: [],
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: 0,
        )
      )
    }
    try view.mouseDown(with: event(.leftMouseDown, outside: false))
    try view.mouseDragged(with: event(.leftMouseDragged, outside: true))
    let offset = view.session.snapshot().viewportOffset
    try #require(offset > 0)
    try view.mouseUp(with: event(.leftMouseUp, outside: true))
    #expect(view.session.snapshot().viewportOffset == offset)
  }

  @Test(.enabled(if: hasMetal), arguments: [-3, 3], [0, 2])
  func `horizontal wheel reports reach mouse tracking applications`(
    _ horizontal: Int32,
    _ vertical: Int32
  ) throws {
    let view = try makeView()
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let cg = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 2,
        wheel1: vertical,
        wheel2: horizontal,
        wheel3: 0,
      )
    )
    cg.location = .zero
    let event = try #require(NSEvent(cgEvent: cg))
    #expect(event.scrollingDeltaX == CGFloat(horizontal))
    #expect(event.scrollingDeltaY == CGFloat(vertical))
    view.scrollWheel(with: event)
    _ = view.session.snapshot()
    let sent = writes.withLock {
      $0.map { String(decoding: $0, as: UTF8.self) }
    }
    let verticalReports = Array(
      repeating: "\u{1B}[<64;1;1M",
      count: Int(vertical)
    )
    let horizontalReports = Array(
      repeating: "\u{1B}[<\(horizontal > 0 ? 66 : 67);1;1M",
      count: Int(abs(horizontal))
    )
    #expect(sent == verticalReports + horizontalReports)
  }

  @Test(.enabled(if: hasMetal), arguments: [-1, 1])
  func
    `precise horizontal wheel movement accumulates and clears outside tracking`(
      _ direction: Int32
    ) throws
  {
    let view = try makeView()
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    let cg = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: 0,
        wheel2: direction,
        wheel3: 0,
      )
    )
    cg.location = .zero
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(
      .scrollWheelEventPointDeltaAxis2,
      value: Int64(direction)
    )
    let event = try #require(NSEvent(cgEvent: cg))
    #expect(event.hasPreciseScrollingDeltas)
    #expect(event.scrollingDeltaX == CGFloat(direction))
    let width =
      view.renderer.cellSize.width / (view.window?.backingScaleFactor ?? 2)
    try #require(width > 1)
    view.scrollWheel(with: event)
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(
      view.horizontalScrollAccumulator.remainder == CGFloat(direction) / width
    )
    for _ in 1 ..< Int(ceil(width)) { view.scrollWheel(with: event) }
    _ = view.session.snapshot()
    #expect(
      TestFixture(
        writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
      ) == TestFixture(["\u{1B}[<\(direction > 0 ? 66 : 67);1;1M"])
    )
    view.session.feed(Array("\u{1B}[?1000l".utf8))
    view.draw(in: view)
    view.scrollWheel(with: event)
    #expect(view.horizontalScrollAccumulator.remainder == 0)
  }

  @Test(.enabled(if: hasMetal), arguments: [1000, 1002, 1003], [false, true])
  func `right and middle drags report motion in the requested tracking mode`(
    _ mode: Int,
    _ middle: Bool
  ) throws {
    let view = try makeView()
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?\(mode)h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    func event(_ type: CGEventType) throws -> NSEvent {
      let cg = try #require(
        CGEvent(
          mouseEventSource: nil,
          mouseType: type,
          mouseCursorPosition: .zero,
          mouseButton: middle ? .center : .right,
        )
      )
      return try #require(NSEvent(cgEvent: cg))
    }
    if middle {
      try view.otherMouseDown(with: event(.otherMouseDown))
      try view.otherMouseDragged(with: event(.otherMouseDragged))
      try view.otherMouseUp(with: event(.otherMouseUp))
    } else {
      try view.rightMouseDown(with: event(.rightMouseDown))
      try view.rightMouseDragged(with: event(.rightMouseDragged))
      try view.rightMouseUp(with: event(.rightMouseUp))
    }
    _ = view.session.snapshot()
    let code = middle ? 1 : 2
    var expected = ["\u{1B}[<\(code);1;1M"]
    if mode != 1000 { expected.append("\u{1B}[<\(code + 32);1;1M") }
    expected.append("\u{1B}[<\(code);1;1m")
    #expect(writes.withLock { $0 } == expected.map { Array($0.utf8) })
  }

  @Test(.enabled(if: hasMetal), arguments: [3, 4, 5])
  func `unsupported mouse buttons do not emit middle button reports`(
    _ button: Int
  ) throws {
    let view = try makeView()
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?1003h\u{1B}[?1006h".utf8))
    view.draw(in: view)
    for type in [CGEventType.otherMouseDown, .otherMouseDragged, .otherMouseUp]
    {
      let cg = try #require(
        CGEvent(
          mouseEventSource: nil,
          mouseType: type,
          mouseCursorPosition: .zero,
          mouseButton: .center,
        )
      )
      cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
      let event = try #require(NSEvent(cgEvent: cg))
      #expect(event.buttonNumber == button)
      switch type {
      case .otherMouseDown: view.otherMouseDown(with: event)
      case .otherMouseDragged: view.otherMouseDragged(with: event)
      default: view.otherMouseUp(with: event)
      }
    }
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal), arguments: ["crosshair", "none"])
  func `terminal reset restores the frontend pointer cursor`(
    _ shape: String
  ) async throws {
    let view = try makeView()
    func waitForCursor(_ cursor: NSCursor) async throws {
      let deadline = Date().addingTimeInterval(2)
      while view.applicationCursor !== cursor, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(view.applicationCursor === cursor)
    }
    view.session.feed(Array("\u{1B}]22;\(shape)\u{7}".utf8))
    _ = view.session.snapshot()
    try await waitForCursor(TerminalView.cursor(named: shape))
    view.session.reset()
    _ = view.session.snapshot()
    try await waitForCursor(.iBeam)
  }

  @Test(.enabled(if: hasMetal))
  func
    `extreme cell sizes and padding remain safe during layout and pointer input`()
    throws
  {
    let view = try makeView(
      configuration: Configuration.parse(
        "adjust-cell-height = 1e308\nwindow-padding-x = 1e308"
      )
    )
    let preferred = view.preferredSize(columns: 100, rows: 30)
    #expect(preferred.width.isFinite && preferred.height.isFinite)
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    view.updateGrid()
    let size = view.session.withState {
      ($0.columns, $0.rows, $0.cellPixelSize.height)
    }
    #expect(size.0 == 1 && size.1 == 1 && size.2 == Int.max)
    let cell = view.unclampedCell(at: .zero)
    #expect(cell.column == -Int(UInt16.max) && cell.row == 0)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `output clearing selection ends its drag`(
    _ extendBeforeFrame: Bool
  ) throws {
    let view = try makeView()
    view.session.feed(Array("abc".utf8))
    view.selectAll(nil)
    let point = TerminalPoint(row: 0, column: 0)
    view.selectionOrigin = (
      point, point, view.session.withState { $0.addressingGeneration }
    )
    #expect(view.hasSelection)
    view.session.feed(Array("\u{1B}[H\u{1B}[2J".utf8))
    if extendBeforeFrame {
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDragged,
          location: .zero,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          eventNumber: 0,
          clickCount: 1,
          pressure: 0,
        )
      )
      view.mouseDragged(with: event)
      #expect(view.session.withState { $0.selection == nil })
    }
    view.draw(in: view)
    #expect(!view.hasSelection)
    #expect(view.selectionOrigin == nil)
    // A single click has a drag origin but no core selection yet.
    view.selectionOrigin = (
      point, point, view.session.withState { $0.addressingGeneration }
    )
    view.draw(in: view)
    #expect(view.selectionOrigin != nil)
  }

  @Test(.enabled(if: hasMetal))
  func `reloading the configuration keeps the hovered link underlined`() throws
  {
    let view = try makeView()
    let span = HighlightSpan(
      startRow: 0,
      startColumn: 2,
      endRow: 0,
      endColumn: 9
    )
    view.renderer.options.hoveredLink = 0
    view.renderer.options.underlinedSpan = span
    var config = Configuration()
    _ = config.set("window-padding-x", "12")
    _ = config.set("minimum-contrast", "2")
    view.apply(config)
    #expect(view.renderer.options.underlinedSpan == span)
    #expect(view.renderer.options.minimumContrast == 2)
    // points at the default 2x scale
    #expect(view.renderer.options.paddingX == 24)
  }
}
