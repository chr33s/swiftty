import TestSupport
import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

/// Direct-view behaviour in workspace panes: mouse reports, copy on
/// select, command output, links, prompt jumps, clear, mouse hiding and
/// the custom shader.
extension MuxNativeTests {
  /// A mouse event at the centre of a viewport cell.
  func mouse(
    _ type: NSEvent.EventType,
    _ view: MuxPaneView,
    row: Int,
    column: Int,
    modifiers: NSEvent.ModifierFlags = [],
    clicks: Int = 1
  ) throws -> NSEvent {
    let scale = view.window?.backingScaleFactor ?? 2
    let point = NSPoint(
      x: (view.renderer.options.paddingX + (CGFloat(column) + 0.5)
        * view.renderer.cellSize.width)
        / scale,
      y: view.bounds.height
        - (view.renderer.options.paddingY + (CGFloat(row) + 0.5)
          * view.renderer.cellSize.height)
        / scale
    )
    return try #require(
      NSEvent.mouseEvent(
        with: type,
        location: view.convert(point, to: nil),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: clicks,
        pressure: 1
      )
    )
  }

  @Test(.enabled(if: hasMetal))
  func `clicks reach a program that tracks the mouse, not selection`()
    async throws
  {
    try await withFixture { f in
      let view = try #require(activeView(f.controller))
      #expect(f.controller.features == .supported)
      _ = await waitPresented(view) { $0.lines.first?.hasPrefix("$") == true }
      f.controller.send(
        .text(
          "clear; stty raw -echo; printf 'R\\033[?1000h\\033[?1006h'; "
            + "dd bs=1 count=9 2>/dev/null | od -An -c\r"
        ),
        to: view.pane
      )
      _ = await waitPresented(view) { $0.modes.contains(.mouseTracking) }
      #expect(view.reportsMouse)
      view.mouseDown(with: try mouse(.leftMouseDown, view, row: 2, column: 4))
      #expect(view.selection == nil)
      let frame = await waitPresented(view) {
        $0.lines.joined().contains("<   0   ;   5   ;   3   M")
      }
      #expect(frame != nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `drag selection copies on select and command output selects`()
    async throws
  {
    try await withFixture { f in
      var config = Configuration()
      config.copyOnSelect = true
      f.controller.apply(config)
      let view = try #require(activeView(f.controller))
      _ = await waitPresented(view) { $0.lines.first?.hasPrefix("$") == true }
      f.controller.send(
        .text(
          "clear; printf '\\033]133;A\\007P\\n\\033]133;C\\007o1\\no2\\n"
            + "\\033]133;A\\007'\r"
        ),
        to: view.pane
      )
      let frame = try #require(
        await waitPresented(view) { $0.lines.contains("o2") }
      )
      let row = try #require(frame.lines.firstIndex(of: "o1"))
      let pasteboard = NSPasteboard.general
      let saved = pasteboard.string(forType: .string)
      defer {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
      }
      view.mouseDown(with: try mouse(.leftMouseDown, view, row: row, column: 0))
      view.mouseDragged(
        with: try mouse(.leftMouseDragged, view, row: row, column: 1)
      )
      view.mouseUp(with: try mouse(.leftMouseUp, view, row: row, column: 1))
      #expect(pasteboard.string(forType: .string) == "o1")
      view.clearSelection()
      view.selectCommandOutput(nil)
      #expect(await until { view.accessibilitySelectedText() == "o1\no2" })
      view.copy(nil)
      #expect(pasteboard.string(forType: .string) == "o1\no2")
    }
  }

  @Test(.enabled(if: hasMetal))
  func `command hover underlines a link`() async throws {
    try await withFixture { f in
      let view = try #require(activeView(f.controller))
      _ = await waitPresented(view) { $0.lines.first?.hasPrefix("$") == true }
      f.controller.send(
        .text("clear; echo https://example.com/a\r"),
        to: view.pane
      )
      let frame = try #require(
        await waitPresented(view) { $0.lines.contains("https://example.com/a") }
      )
      let row = try #require(
        frame.lines.firstIndex(of: "https://example.com/a")
      )
      view.updateHover(
        try mouse(.mouseMoved, view, row: row, column: 3, modifiers: .command)
      )
      #expect(await until { view.renderer.options.underlinedSpan != nil })
      #expect(view.hoveredLink?.url == "https://example.com/a")
      #expect(view.renderer.options.underlinedSpan?.endColumn == 20)
      // Releasing Command removes the underline.
      view.updateHover(try mouse(.mouseMoved, view, row: row, column: 3))
      #expect(view.renderer.options.underlinedSpan == nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `prompt jumps, clear screen and click to move use the service`()
    async throws
  {
    try await withFixture { f in
      var config = Configuration()
      config.cursorClickToMove = true
      f.controller.apply(config)
      let view = try #require(activeView(f.controller))
      _ = await waitPresented(view) { $0.lines.first?.hasPrefix("$") == true }
      f.controller.send(
        .text("clear; printf '\\033]133;A\\007MARK\\n'; seq 1 60\r"),
        to: view.pane
      )
      _ = await waitPresented(view) { $0.lines.contains("60") }
      #expect(view.perform(.jumpToPrompt(-1)))
      #expect(await waitPresented(view) { $0.text(row: 0) == "MARK" } != nil)
      #expect(view.perform(.scrollToBottom))
      #expect(view.perform(.clearScreen))
      #expect(
        await waitPresented(view) { $0.lines.filter { !$0.isEmpty }.count <= 1 }
          != nil
      )
      // Click-to-move: the shell (no OSC 133 input) gets nothing; a
      // plain click is not a selection either.
      view.mouseDown(with: try mouse(.leftMouseDown, view, row: 0, column: 0))
      view.mouseUp(with: try mouse(.leftMouseUp, view, row: 0, column: 0))
      #expect(view.selection == nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `the custom shader loads and drives frames`() async throws {
    try await withFixture { f in
      let shader = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftty-pane-\(UUID()).metal")
      try """
      float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
          return float4(sin(u.time), 0, 0, 1);
      }
      """
      .write(to: shader, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: shader) }
      let view = try #require(activeView(f.controller))
      #expect(view.isPaused)
      f.controller.apply(
        Configuration.configured([("custom-shader", "\(shader.path)")])
      )
      #expect(view.renderer.isAnimating)
      #expect(!view.isPaused)
      f.controller.apply(Configuration())
      #expect(!view.renderer.isAnimating)
      #expect(view.isPaused)
    }
  }
}
