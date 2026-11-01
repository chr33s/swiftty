import AppKit
import MetalKit
import SwiftMuxExport
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
@testable import SwifttyMac
import Testing
import Synchronization

@MainActor
@Suite(.serialized)
struct NativeAccessibilityParityTests {
  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func standaloneViewBoundsInputWithoutChangingPublicSessionSend() throws {
    _ = NSApplication.shared
    let view = try TerminalView(configuration: .init())
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let oversized = String(repeating: "x", count: 100_000)
    view.insertText(
      oversized,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    view.session.send(.text(oversized))
    _ = view.session.snapshot()
    #expect(writes.withLock { $0 } == [Array(oversized.utf8)])
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func directPointerDoesNotTargetContentRejectedForDisplay() throws {
    _ = NSApplication.shared
    let view = try TerminalView(configuration: .init())
    let window = InteractionTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    view.session.feed(Array("https://shown.example".utf8))
    view.draw(in: view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: NSPoint(
          x: (view.renderer.options.paddingX + view.renderer.cellSize.width / 2)
            / window.backingScaleFactor,
          y: view.bounds.height
            - (view.renderer.options.paddingY + view.renderer.cellSize.height
              / 2) / window.backingScaleFactor
        ),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 2,
        pressure: 0
      )
    )
    #expect(view.link(for: event)?.url == "https://shown.example")
    _ = view.session.snapshot()  // Unchanged polling is not a new presentation.
    #expect(view.link(for: event)?.url == "https://shown.example")
    view.isHidden = true
    view.session.feed(Array("\u{1B}[2J\u{1B}[Hhttps://unseen.example".utf8))
    view.draw(in: view)
    // Consuming damage again cannot admit the frame.
    _ = view.session.snapshot()
    #expect(view.link(for: event)?.url != "https://unseen.example")
    view.mouseDown(with: event)
    #expect(view.session.withState { $0.selection == nil })
    view.isHidden = false
    view.draw(in: view)
    #expect(view.link(for: event)?.url == "https://unseen.example")
    view.mouseDown(with: event)
    #expect(view.session.withState { $0.selection != nil })
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func invalidScrollDeltasPreserveFractionalInputInBothAdapters() throws {
    _ = NSApplication.shared
    let direct = try TerminalView(configuration: .init())
    let mux = try MuxPaneView(pane: .init(), configuration: .init())
    let event = SurfaceScrollEvent()
    for view in [direct as NSView, mux] {
      event.delta = 0.4
      view.scrollWheel(with: event)
      for invalid in [
        CGFloat.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
      ] {
        event.delta = invalid
        view.scrollWheel(with: event)
      }
    }
    #expect(direct.pointer.vertical.remainder == 0.4)
    #expect(mux.pointer.vertical.remainder == 0.4)

    event.delta = 1_000_000_000
    let pointer = TerminalPointer()
    var reports = 0
    pointer.scroll(event, in: direct, renderer: direct.renderer, mode: .mouse) {
      _ in reports += 1
    }
    #expect(reports > 0 && reports <= 256)
  }

  @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
  func displayedUnicodeRangesAndFrozenSelectionShareOnePresenter() throws {
    _ = NSApplication.shared
    let session = TerminalSession(columns: 8, rows: 3)
    let direct = try TerminalView(configuration: .init(), session: session)
    let mux = try MuxPaneView(pane: .init(), configuration: .init())
    let windows = [direct as NSView, mux]
      .map { view in
        let window = InteractionTestWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
          styleMask: [.borderless],
          backing: .buffered,
          defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
      }
    defer { windows.forEach { $0.close() } }
    session.resize(columns: 8, rows: 3)
    let server = ServerInstanceID()
    let attachment = AttachmentID()
    func deliver(_ text: String, revision: UInt64) throws {
      session.feed(Array(text.utf8))
      direct.draw(in: direct)
      let frame = try FrameExporter.frame(
        from: session.withState { $0.captureOwnedScreen() },
        identity: .init(
          server: server,
          attachment: attachment,
          pane: mux.pane,
          revision: revision,
          layoutRevision: 1,
          geometryGeneration: 0,
          viewportRevision: 0
        )
      )
      mux.receive(
        try #require(MuxPaneView.importFrame(frame, limits: .init())),
        server: server
      )
      mux.draw(in: mux)
      try #require(mux.renderer.waitUntilIdle(timeout: .now() + 2))
    }
    try deliver("A😀e\u{301}👩‍💻Z\r\nwrapped content", revision: 1)
    let visible = try #require(direct.accessibilityValue() as? String)
    #expect(mux.accessibilityValue() as? String == visible)
    #expect(mux.accessibilityNumberOfCharacters() == visible.utf16.count)
    for index in -1 ... visible.utf16.count {
      #expect(
        mux.accessibilityRange(for: index)
          == direct.accessibilityRange(for: index)
      )
      #expect(
        mux.accessibilityLine(for: index)
          == direct.accessibilityLine(for: index)
      )
    }
    #expect(
      mux.accessibilitySelectedTextRange()
        == direct.accessibilitySelectedTextRange()
    )
    for row in 0 ..< 3 {
      let range = direct.accessibilityRange(forLine: row)
      #expect(mux.accessibilityRange(forLine: row) == range)
      #expect(
        mux.accessibilityString(for: range)
          == direct.accessibilityString(for: range)
      )
      #expect(
        mux.accessibilityFrame(for: range).size
          == direct.accessibilityFrame(for: range).size
      )
    }
    direct.selectAll(nil)
    direct.draw(in: direct)
    mux.selectAll(nil)
    mux.draw(in: mux)
    try #require(mux.renderer.waitUntilIdle(timeout: .now() + 2))
    #expect(
      mux.accessibilitySelectedTextRanges()
        == direct.accessibilitySelectedTextRanges()
    )
    let selectedRanges = mux.accessibilitySelectedTextRanges()
    try deliver("\u{1B}[2J\u{1B}[Hnew", revision: 2)
    #expect(mux.accessibilityValue() as? String == visible)
    #expect(mux.accessibilitySelectedTextRanges() == selectedRanges)
    mux.clearSelection()
    mux.draw(in: mux)
    try #require(mux.renderer.waitUntilIdle(timeout: .now() + 2))
    #expect(
      mux.accessibilityValue() as? String == direct.accessibilityValue()
        as? String
    )
    #expect(
      mux.accessibilityString(for: NSRange(location: 0, length: 3)) == "new"
    )
    let oldValue = mux.accessibilityValue() as? String
    let address = try #require(mux.address(row: 0, in: mux.presented))
    mux.pendingOutput = CommandOutput(
      start: address,
      end: address,
      text: "deferred"
    )
    mux.isHidden = true
    try deliver("\u{1B}[Hdeferred", revision: 3)
    #expect(mux.frozen == nil)
    #expect(mux.accessibilityValue() as? String == oldValue)
    #expect(mux.pendingOutput != nil)
    mux.isHidden = false
    mux.draw(in: mux)
    try #require(mux.renderer.waitUntilIdle(timeout: .now() + 2))
    #expect(mux.pendingOutput == nil)
    #expect(mux.accessibilitySelectedText() == "deferred")
    #expect(mux.presented?.frame.identity.revision == 3)

  }
}

private final class SurfaceScrollEvent: NSEvent {
  var delta: CGFloat = 0
  override var scrollingDeltaY: CGFloat { delta }
  override var scrollingDeltaX: CGFloat { 0 }
  override var hasPreciseScrollingDeltas: Bool { false }
}
