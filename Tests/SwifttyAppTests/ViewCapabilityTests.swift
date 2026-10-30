import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Surface capabilities in the macOS view: remote presentations hide or
/// disable local-emulator features and program side effects.
@MainActor
@Suite(.serialized)
struct ViewCapabilityTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  init() { DisplayAccommodations.override = DisplayAccommodations() }

  func makeView(session: TerminalSession? = nil) throws -> TerminalView {
    _ = NSApplication.shared
    guard let session else { return try TerminalView(configuration: .init()) }
    return try TerminalView(configuration: .init(), session: session)
  }

  /// Runs the main run loop until `condition` holds or a second passes.
  /// Suspends rather than nesting the run loop: events reach the view
  /// through the main queue, which cannot run while a block on it does.
  private func spin(until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(1)
    while !condition(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  static let osc52 = TestFixture(Array("\u{1B}]52;c;aGk=\u{7}".utf8))

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `read only surfaces reject keyboard and IME input`(
    _ presentation: Bool
  ) throws {
    let session =
      presentation
      ? TerminalSession(presentationColumns: 20, rows: 2)
      : TerminalSession(columns: 20, rows: 2)
    let view = try makeView(session: session)
    let writes = Mutex<[[UInt8]]>([])
    let semantic = Mutex(0)
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    session.semanticInputHandler = { _ in semantic.withLock { $0 += 1 } }
    view.capabilities.textInput = false
    let enter = try KeyHandlingTests().key(36, "\r")
    view.keyDown(with: enter)
    #expect(view.sendKey(enter))
    view.sendHardwareKey(KeyEvent(.enter), event: enter)
    view.insertText(
      "typed",
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    view.interpretingEvent = try KeyHandlingTests().key(0, "a")
    view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    view.interpretingEvent = nil
    view.setMarkedText(
      "composing",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(!view.hasMarkedText())
    view.unmarkText()
    session.queue.sync {}
    #expect(writes.withLock { $0.isEmpty })
    #expect(semantic.withLock { $0 } == 0)
    #expect(view.heldKeys.isEmpty)
    view.capabilities.textInput = true
    view.insertText(
      "resumed",
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    session.queue.sync {}
    #expect(
      presentation
        ? semantic.withLock { $0 } == 1
        : writes.withLock { $0 } == [Array("resumed".utf8)]
    )
  }

  @Test(.enabled(if: hasMetal))
  func `disabling text input releases held keys and discards composition`()
    throws
  {
    let view = try makeView()
    view.session.feed(Array("\u{1B}[=10u".utf8))
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in writes.withLock { $0 += bytes } }
    let up = try KeyHandlingTests().key(126, "\u{F700}")
    #expect(view.sendKey(up))
    view.setMarkedText(
      "pending",
      selectedRange: NSRange(location: 0, length: 1),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    view.capabilities.textInput = false
    #expect(view.heldKeys.isEmpty)
    #expect(!view.hasMarkedText())
    #expect(view.renderer.options.preedit.isEmpty)
    #expect(view.renderer.options.preeditSelection == nil)
    view.keyUp(with: up)
    view.unmarkText()
    view.session.queue.sync {}
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture(Array("\u{1B}[A\u{1B}[1;1:3A".utf8))
    )
  }

  @Test(.enabled(if: hasMetal))
  func `read only surfaces keep local shortcuts without clearing selection`()
    throws
  {
    _ = NSApplication.shared
    let view = try TerminalView(
      configuration: Configuration.parse("keybind=ctrl+a=increase_font_size:1")
    )
    view.session.feed(Array("selected".utf8))
    view.selectAll(nil)
    view.capabilities.textInput = false
    let before = view.fontSize
    try view.keyDown(
      with: KeyHandlingTests().key(0, "\u{1}", unmodified: "a", [.control])
    )
    #expect(view.fontSize == before + 1)
    view.selectAll(nil)
    try view.keyDown(with: KeyHandlingTests().key(36, "\r"))
    #expect(view.session.withState { $0.selection != nil })
  }

  @Test(.enabled(if: hasMetal), arguments: ["click", "scroll"], [false, true])
  func `generated cursor keys respect the text input capability`(
    _ gesture: String,
    _ allowed: Bool
  ) throws {
    _ = NSApplication.shared
    let view = try TerminalView(
      configuration: Configuration.parse("cursor-click-to-move=true")
    )
    view.setFrameSize(NSSize(width: 400, height: 200))
    let program =
      gesture == "click"
      ? "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abc" : "\u{1B}[?1049h\u{1B}[?1007h"
    view.session.feed(Array(program.utf8))
    view.draw(in: view)
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in writes.withLock { $0 += bytes } }
    view.capabilities.textInput = allowed
    if gesture == "click" {
      func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(
          NSEvent.mouseEvent(
            with: type,
            location: NSPoint(
              x: (view.renderer.options.paddingX + 2.5
                * view.renderer.cellSize.width) / 2,
              y: view.bounds.height
                - (view.renderer.options.paddingY + view.renderer.cellSize
                  .height / 2) / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
          )
        )
      }
      try view.mouseDown(with: event(.leftMouseDown))
      try view.mouseUp(with: event(.leftMouseUp))
    } else {
      let cg = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil,
          units: .line,
          wheelCount: 1,
          wheel1: 1,
          wheel2: 0,
          wheel3: 0
        )
      )
      view.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    }
    view.session.queue.sync {}
    let expected =
      !allowed
      ? "" : gesture == "click" ? "\u{1B}[D\u{1B}[D\u{1B}[D" : "\u{1B}[A"
    #expect(
      TestFixture(writes.withLock { $0 }) == TestFixture(Array(expected.utf8))
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `link capability changes refresh stationary hover`(
    _ explicit: Bool
  ) throws {
    let view = try makeView()
    view.setFrameSize(NSSize(width: 400, height: 200))
    let text =
      explicit
      ? "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"
      : "https://example.com"
    view.session.feed(Array(text.utf8))
    view.draw(in: view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / 2,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / 2
        ),
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    view.updateHover(event)
    let link = try #require(view.hoveredLink)
    #expect((view.renderer.options.hoveredLink != 0) == explicit)
    #expect((view.renderer.options.underlinedSpan != nil) == !explicit)
    view.capabilities.openURLs = false
    view.draw(in: view)
    #expect(view.hoveredLink == nil)
    #expect(view.renderer.options.hoveredLink == 0)
    #expect(view.renderer.options.underlinedSpan == nil)
    view.capabilities.openURLs = true
    view.draw(in: view)
    #expect(view.hoveredLink == link)
    #expect((view.renderer.options.hoveredLink != 0) == explicit)
    #expect((view.renderer.options.underlinedSpan != nil) == !explicit)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `program clipboard writes pass the capability gate`(
    _ allowed: Bool
  ) async throws {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("before", forType: .string)
    view.capabilities.remoteClipboardWrites = allowed
    view.session.feed(Self.osc52.value)
    try await spin { clipboard.string(forType: .string) != "before" }
    #expect(clipboard.string(forType: .string) == (allowed ? "hi" : "before"))
  }

  @Test(.enabled(if: hasMetal))
  func `roaming surfaces disable search, paste and scrollback`() throws {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("pasted", forType: .string)
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.capabilities = .roaming
    view.capabilities.paste = false
    #expect(!view.perform(.startSearch))
    #expect(view.searchBar == nil)
    #expect(!view.perform(.scrollPageUp))
    #expect(!view.perform(.pasteFromClipboard))
    view.paste(nil)
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })

    func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      item.tag = tag
      return item
    }
    #expect(!view.validateMenuItem(item(#selector(TerminalView.paste(_:)))))
    #expect(
      !view.validateMenuItem(
        item(#selector(TerminalView.performFindPanelAction(_:)))
      )
    )
    #expect(
      view.validateMenuItem(item(#selector(TerminalView.resetTerminal(_:))))
    )

    view.capabilities = .full
    #expect(view.validateMenuItem(item(#selector(TerminalView.paste(_:)))))
    #expect(view.perform(.startSearch))
    #expect(view.searchBar != nil)
    view.capabilities.search = false
    #expect(view.searchBar == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `presentation views hide local actions and send semantic input`() throws
  {
    let session = TerminalSession(presentationColumns: 20, rows: 4)
    let view = try makeView(session: session)
    view.capabilities = .roaming
    view.capabilities.paste = false
    let writes = Mutex<[UInt8]>([])
    let semantic = Mutex<[String]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    session.semanticInputHandler = { input in
      if case let .paste(text) = input { semantic.withLock { $0.append(text) } }
    }
    #expect(!view.perform(.reset))
    #expect(!view.perform(.clearScreen))
    #expect(
      !view.validateMenuItem(
        NSMenuItem(
          title: "",
          action: #selector(TerminalView.resetTerminal(_:)),
          keyEquivalent: ""
        )
      )
    )
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )
    )
    let menu = try #require(view.menu(for: event))
    let titles = menu.items.map(\.title)
    #expect(titles.contains("Copy"))
    #expect(!titles.contains("Paste"))

    view.capabilities.paste = true
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("text", forType: .string)
    #expect(view.perform(.pasteFromClipboard))
    session.queue.sync {}
    #expect(semantic.withLock { $0 } == ["text"])
    #expect(writes.withLock { $0.isEmpty })
  }
}
