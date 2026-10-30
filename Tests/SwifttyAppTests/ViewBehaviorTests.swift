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
@MainActor
@Suite(.serialized)
struct ViewBehaviorTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  init() { DisplayAccommodations.override = DisplayAccommodations() }

  func makeView(
    configuration: Configuration = Configuration()
  ) throws -> TerminalView {
    _ = NSApplication.shared
    return try TerminalView(configuration: configuration)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (Double(-20), Double(1)), (0, 1), (0.5, 1), (201, 200),
      (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1),
      (.nan, 13),
    ]
  )
  func `programmatic font sizes remain bounded across reload and reset`(
    _ input: Double,
    _ expected: Double
  ) throws {
    var configuration = Configuration()
    configuration.fontSize = input
    let view = try makeView(configuration: configuration)
    #expect(
      view.fontSize == CGFloat(expected)
        && view.renderer.font.descriptor.size == CGFloat(expected)
    )
    view.setFontSize(40)
    #expect(view.fontSize == 40)
    view.setFontSize(nil)
    #expect(
      view.fontSize == CGFloat(expected)
        && view.renderer.font.descriptor.size == CGFloat(expected)
    )
    view.apply(Configuration.parse("font-size=20"))
    #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
    view.apply(configuration)
    #expect(
      view.fontSize == CGFloat(expected)
        && view.renderer.font.descriptor.size == CGFloat(expected)
    )
    view.setFontSize(CGFloat(input))
    #expect(
      view.fontSize == CGFloat(expected)
        && view.renderer.font.descriptor.size == CGFloat(expected)
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [Int.min, -1, 0, Int.max])
  func `unknown find menu tags open the find bar without trapping`(
    _ tag: Int
  ) throws {
    let view = try makeView()
    let item = NSMenuItem(
      title: "Find",
      action: #selector(TerminalView.performFindPanelAction(_:)),
      keyEquivalent: ""
    )
    item.tag = tag
    view.performFindPanelAction(item)
    let bar = try #require(view.searchBar)
    view.showSearch(text: "needle")
    view.performFindPanelAction(item)
    #expect(view.searchBar === bar)
    #expect(TestFixture(bar.text) == TestFixture("needle"))
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `find menu navigation reaches the terminal while its query field is editing`(
      _ next: Bool
    ) throws
  {
    _ = NSApplication.shared
    let controller = try TerminalWindowController(
      configuration: Configuration.parse("command=/bin/sleep 30")
    )
    let window = try #require(controller.window)
    let view = controller.terminal
    defer { window.close() }
    view.session.feed(Array("needle0\r\nneedle1\r\nneedle2".utf8))
    view.showSearch(text: "needle")
    let editor = try #require(view.searchBar?.field.currentEditor())
    #expect(window.fieldEditor(true, for: nil) !== editor)
    #expect(view.session.snapshot().searchSelectedIndex == 2)
    let item = NSMenuItem(
      title: "Find Next",
      action: #selector(TerminalView.performFindPanelAction(_:)),
      keyEquivalent: "g"
    )
    item.tag = Int((next ? NSFindPanelAction.next : .previous).rawValue)
    let action = try #require(item.action)
    #expect(NSApp.sendAction(action, to: window.firstResponder, from: item))
    #expect(view.session.snapshot().searchSelectedIndex == (next ? 1 : 0))
    #expect(editor.string == "needle")
    let textView = try #require(editor as? NSTextView)
    textView.insertText(
      "needle1",
      replacementRange: NSRange(location: 0, length: 6)
    )
    #expect(TestFixture(view.searchBar?.text) == TestFixture("needle1"))
    #expect(view.session.snapshot().searchMatchCount == 1)
  }

  @Test(.enabled(if: hasMetal))
  func `default glass windows keep terminal content below the title bar`()
    throws
  {
    _ = NSApplication.shared
    let config = Configuration.parse("command=/bin/sleep 30")
    let controller = try TerminalWindowController(configuration: config)
    let window = try #require(controller.window)
    defer { window.close() }
    let view = controller.terminal
    #expect(window.contentView is NSGlassEffectView)
    #expect(!window.isOpaque && view.layer?.isOpaque == false)
    #expect(view.renderer.options.backgroundOpacity > 0)
    #expect(view.renderer.options.backgroundOpacity < 1)
    for size in [
      NSSize(width: 320, height: 160), NSSize(width: 800, height: 240),
    ] {
      window.setContentSize(size)
      window.contentView?.layoutSubtreeIfNeeded()
      let frame = view.convert(view.bounds, to: window.contentView)
      #expect(frame.width > 0 && frame.height > 0)
      #expect(window.contentLayoutRect.contains(frame))
      view.showSearch(text: "retained query")
      let field = try #require(view.searchBar?.field)
      let location = view.convert(
        NSPoint(x: field.bounds.midX, y: field.bounds.midY),
        from: field
      )
      let hit = try #require(view.hitTest(location))
      #expect(hit === field || hit.isDescendant(of: field))
      #expect(field.currentEditor() != nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `configuration reload preserves search focus across background layouts`()
    throws
  {
    _ = NSApplication.shared
    var config = Configuration()
    config.command = "/bin/sleep 30"
    let controller = try TerminalWindowController(configuration: config)
    let window = try #require(controller.window)
    defer { window.close() }
    let view = controller.terminal
    view.showSearch(text: "needle")
    let field = try #require(view.searchBar?.field)
    let editor = try #require(field.currentEditor())
    try #require(editor.string == "needle")
    let selection = NSRange(location: 2, length: 2)
    editor.selectedRange = selection
    try #require(editor.selectedRange == selection)
    #expect(window.firstResponder === editor)
    controller.apply(config)
    #expect(
      field.currentEditor() != nil
        && window.firstResponder === field.currentEditor()
    )
    #expect(field.currentEditor()?.selectedRange == selection)
    config.backgroundBlur = 0
    controller.apply(config)
    #expect(window.contentView === view && !window.isOpaque)
    #expect(window.firstResponder === field.currentEditor())
    #expect(field.currentEditor()?.selectedRange == selection)
    config.backgroundOpacity = 0.5
    config.backgroundBlur = 20
    controller.apply(config)
    #expect(window.contentView is NSGlassEffectView)
    #expect(
      field.currentEditor() != nil
        && window.firstResponder === field.currentEditor()
    )
    #expect(field.currentEditor()?.selectedRange == selection)
    config.backgroundOpacity = 1
    controller.apply(config)
    #expect(window.contentView === view)
    #expect(
      field.currentEditor() != nil
        && window.firstResponder === field.currentEditor()
    )
    #expect(field.currentEditor()?.selectedRange == selection)
  }

  @Test(.enabled(if: hasMetal))
  func `detached blinking text stays visible through restart`() throws {
    let view = try makeView(
      configuration: Configuration.parse("command=/bin/sleep 30")
    )
    defer { view.stop() }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 256,
      height: 128,
      mipmapped: false,
    )
    descriptor.usage = [.renderTarget]
    let texture = try #require(view.device?.makeTexture(descriptor: descriptor))
    view.session.feed(Array("\u{1B}[5mX".utf8))
    let command = try view.renderer.render(view.session.snapshot(), to: texture)
    command.waitUntilCompleted()
    try #require(
      command.status == .completed,
      Comment(rawValue: escapedTestText("\(String(describing: command.error))"))
    )
    #expect(view.renderer.hasBlinkingText)
    view.draw(in: view)

    RunLoop.main.run(until: Date().addingTimeInterval(0.65))
    view.draw(in: view)
    #expect(view.renderer.options.textBlinkVisible)
    view.stop()
    view.draw(in: view)
    #expect(view.renderer.options.textBlinkVisible)
    try view.start()
    view.draw(in: view)
    RunLoop.main.run(until: Date().addingTimeInterval(0.65))
    view.draw(in: view)
    #expect(view.renderer.options.textBlinkVisible)
  }

  @Test(.enabled(if: hasMetal))
  func `detached animated shader frames stay suspended through restart`() throws
  {
    let view = try makeView(
      configuration: Configuration.parse("command=/bin/sleep 30")
    )
    defer { view.stop() }
    try view.renderer.setPostProcessShader(
      """
      float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
          return float4(sin(u.time), 0, 0, 1);
      }
      """
    )
    view.draw(in: view)
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    view.stop()
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    view.draw(in: view)  // An update already queued before stop can still draw.
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    try view.start()
    view.draw(in: view)
    #expect(view.isPaused && view.enableSetNeedsDisplay)
  }

  @Test(.enabled(if: hasMetal))
  func `select command output finds output whose prompt has left history`()
    throws
  {
    let view = try makeView(
      configuration: Configuration.parse("scrollback-limit=0")
    )
    view.session.resize(columns: 20, rows: 3)
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
    let output = "\r\n\u{1B}]133;C\u{7}"
    let done = "\u{1B}]133;D;0\u{7}"
    view.session.feed(
      Array(
        (prompt + "first" + output + "first output\r\n" + done + prompt + "true"
          + output + done + prompt)
          .utf8
      )
    )
    #expect(view.session.withState { $0.firstAbsoluteRow } > 0)
    view.selectCommandOutput(nil)
    #expect(view.session.withState { $0.selectionText } == "first output")
    #expect(view.hasSelection)
  }

  @Test(.enabled(if: hasMetal), arguments: [1, 3])
  func `select command output skips intervening commands without output`(
    _ emptyCommands: Int
  ) throws {
    let view = try makeView()
    view.session.resize(columns: 20, rows: 10)
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
    let output = "\r\n\u{1B}]133;C\u{7}"
    let done = "\u{1B}]133;D;0\u{7}"
    view.session.feed(
      Array((prompt + "first" + output + "first output\r\n" + done).utf8)
    )
    for _ in 0 ..< emptyCommands {
      view.session.feed(Array((prompt + "true" + output + done).utf8))
    }
    view.session.feed(Array(prompt.utf8))
    view.selectCommandOutput(nil)
    #expect(view.session.withState { $0.selectionText } == "first output")
    #expect(view.hasSelection)
  }

  @Test(.enabled(if: hasMetal), arguments: ["resize", "reset", "evict"])
  func
    `select command output ignores a click whose coordinates are no longer valid`(
      _ change: String
    ) throws
  {
    let view = try makeView(
      configuration: Configuration.parse("scrollback-limit=0")
    )
    view.session.resize(columns: 20, rows: change == "evict" ? 5 : 8)
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
    let output = "\r\n\u{1B}]133;C\u{7}"
    let done = "\r\n\u{1B}]133;D;0\u{7}"
    view.session.feed(
      Array((prompt + "first" + output + "first output" + done + prompt).utf8)
    )
    view.lastClick = (
      TerminalPoint(row: 0, column: 0),
      view.session.withState { $0.addressingGeneration }
    )
    if change == "reset" {
      view.session.reset()
      view.session.feed(
        Array(
          (prompt + "first" + output + "new first" + done + prompt + "second"
            + output + "new last" + done + prompt)
            .utf8
        )
      )
    } else {
      view.session.feed(
        Array(
          ("second" + output + "second output" + done + prompt + "third"
            + output + "third output" + done + prompt)
            .utf8
        )
      )
      if change == "resize" { view.session.resize(columns: 30, rows: 8) }
    }
    view.selectCommandOutput(nil)
    #expect(
      view.session.withState { $0.selectionText }
        == (change == "reset" ? "new last" : "third output")
    )
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `select command output chooses the most recent available output`(
    _ editingNextPrompt: Bool
  ) throws {
    let view = try makeView()
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}"
    let output = "\r\n\u{1B}]133;C\u{7}"
    let done = "\r\n\u{1B}]133;D;0\u{7}"
    view.session.feed(
      Array(
        (prompt + "first" + output + "first output" + done + prompt + "second"
          + output + "second output")
          .utf8
      )
    )
    if editingNextPrompt { view.session.feed(Array((done + prompt).utf8)) }
    view.selectCommandOutput(nil)
    #expect(view.session.withState { $0.selectionText } == "second output")
    #expect(view.hasSelection)
    // An explicit click continues to select that command's output.
    view.lastClick = (
      TerminalPoint(row: 0, column: 0),
      view.session.withState { $0.addressingGeneration }
    )
    view.selectCommandOutput(nil)
    #expect(view.session.withState { $0.selectionText } == "first output")
  }

  @Test(.enabled(if: hasMetal))
  func `navigation actions report whether they can run`() throws {
    let view = try makeView()
    #expect(!view.perform(.scrollPageUp))
    #expect(!view.perform(.jumpToPrompt(-1)))
    #expect(!view.perform(.navigateSearch(next: true)))
    #expect(!view.perform(.searchSelection))
    #expect(!view.perform(.endSearch))
    view.session.feed(Array(String(repeating: "row\r\n", count: 30).utf8))
    #expect(view.perform(.scrollPageUp))
    #expect(view.perform(.scrollToBottom))
    #expect(!view.perform(.scrollToBottom))
  }

  @Test(.enabled(if: hasMetal))
  func `responder changes in inactive windows do not report focus`() throws {
    let view = try makeView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    #expect(!window.isKeyWindow)
    let writes = Mutex<[[UInt8]]>([])
    view.session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.session.feed(Array("\u{1B}[?1004h".utf8))
    #expect(window.makeFirstResponder(view))
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `negative font size steps stay within view bounds`() throws {
    let view = try makeView()
    view.perform(.increaseFontSize(-1000))
    #expect(view.fontSize == 1)
    view.perform(.decreaseFontSize(-1000))
    #expect(view.fontSize == 200)
  }

  @Test(.enabled(if: hasMetal), arguments: [1, 3, 100, 200])
  func
    `zoom actions follow their direction throughout the configured font range`(
      _ size: Int
    ) throws
  {
    let view = try makeView(
      configuration: Configuration.parse("font-size=\(size)")
    )
    view.perform(.increaseFontSize(1))
    #expect(view.fontSize == CGFloat(min(size + 1, 200)))
    view.perform(.resetFontSize)
    view.perform(.decreaseFontSize(1))
    #expect(view.fontSize == CGFloat(max(size - 1, 1)))
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `font configuration reload preserves manual zoom and reset follows new settings`(
      _ zoomed: Bool
    ) throws
  {
    let view = try makeView(configuration: Configuration.parse("font-size=14"))
    if zoomed { view.perform(.increaseFontSize(5)) }
    view.apply(Configuration.parse("font-size=20\nfont-feature=-liga"))
    #expect(view.fontSize == (zoomed ? 19 : 20))
    #expect(view.renderer.font.descriptor.size == view.fontSize)
    #expect(view.renderer.font.descriptor.features == ["-liga"])
    view.perform(.resetFontSize)
    #expect(view.fontSize == 20)
    view.apply(Configuration.parse("font-size=22\nfont-feature=-liga"))
    #expect(view.fontSize == 22)
    #expect(view.renderer.font.descriptor.size == 22)
  }

  @Test(.enabled(if: hasMetal))
  func `reset action clears incomplete output sequences`() throws {
    let view = try makeView()
    view.session.feed(Array("\u{1B}]2;pending".utf8))
    view.perform(.reset)
    view.session.receive(Array("ok".utf8))
    #expect(
      TestFixture(view.session.snapshot().text.first) == TestFixture("ok")
    )
  }

  // MARK: Render options

  @Test
  func `merging keeps what the view drives`() {
    var current = RenderOptions()
    current.preedit = ["x"]
    current.preeditSelection = NSRange(location: 1, length: 0)
    current.hoveredLink = 3
    current.underlinedSpan = HighlightSpan(
      startRow: 0,
      startColumn: 1,
      endRow: 0,
      endColumn: 4
    )
    current.textBlinkVisible = false
    current.cursorVisible = false
    current.isFocused = false
    var configured = RenderOptions()
    configured.paddingX = 20
    configured.minimumContrast = 3
    let merged = TerminalView.merge(configured: configured, current: current)
    #expect(merged.paddingX == 20 && merged.minimumContrast == 3)
    #expect(
      merged.preedit == ["x"] && merged.hoveredLink == 3
        && merged.underlinedSpan == current.underlinedSpan
    )
    #expect(merged.preeditSelection == current.preeditSelection)
    #expect(
      !merged.textBlinkVisible && !merged.cursorVisible && !merged.isFocused
    )
  }

}
