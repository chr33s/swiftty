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
struct ViewLifecycleTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  func makeWindow() -> UIWindow {
    let frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    if let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    {
      let window = UIWindow(windowScene: scene)
      window.frame = frame
      return window
    }
    return UIWindow(frame: frame)
  }

  @Test(.enabled(if: hasMetal))
  func presentationFontChangesProposeGeometryWithoutReplacingTheHostGrid()
    throws
  {
    let session = TerminalSession(presentationColumns: 80, rows: 24)
    let proposals = Mutex<[[Int]]>([])
    session.gridProposalHandler = { columns, rows in
      proposals.withLock { $0.append([columns, rows]) }
    }
    let view = try TerminalUIView(session: session)
    view.capabilities = .roaming
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    view.sceneDidActivate()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    try #require(view.isSurfaceVisible)
    let frame = PresentationFrame(
      columns: 6,
      rows: 2,
      cells: "host  remote".map { .init(text: String($0), width: 1, style: 0) },
      wrapped: [false, false],
      styles: [.init()],
      cursorX: 5,
      cursorY: 1
    )
    try #require(session.installPresentation(frame))
    session.mutate { state in
      state.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 3)
        )
      )
      state.search("host")
    }
    let original = session.snapshot()
    try #require(original.selection != nil && original.searchMatchCount == 1)
    let selectedText = session.withState { $0.selectionText }
    for change in ["configuration", "zoom", "layout"] {
      proposals.withLock { $0.removeAll() }
      switch change {
      case "configuration":
        view.apply(Configuration.configured([("font-size", "18")]))
      case "zoom": try #require(view.perform(.increaseFontSize(4)))
      default:
        view.frame.size = CGSize(width: 640, height: 360)
        view.layoutSubviews()
      }
      let snapshot = session.snapshot()
      #expect(
        proposals.withLock { $0.last } == [
          view.gridSize.columns, view.gridSize.rows,
        ]
      )
      #expect(
        view.gridSize.columns != frame.columns
          || view.gridSize.rows != frame.rows
      )
      #expect(
        snapshot.columns == original.columns
          && snapshot.rowCount == original.rowCount
      )
      #expect(snapshot.text == original.text)
      #expect(
        snapshot.cursor.x == original.cursor.x
          && snapshot.cursor.y == original.cursor.y
      )
      #expect(snapshot.selection == original.selection)
      #expect(snapshot.searchMatches == original.searchMatches)
      #expect(snapshot.searchSelectedIndex == original.searchSelectedIndex)
      #expect(session.withState { $0.selectionText } == selectedText)
    }
    let replacement = PresentationFrame(
      columns: 4,
      rows: 1,
      cells: "next".map { .init(text: String($0), width: 1, style: 0) },
      wrapped: [false],
      styles: [.init()],
      cursorX: 3,
      cursorY: 0
    )
    try #require(session.installPresentation(replacement))
    let snapshot = session.snapshot()
    #expect(
      snapshot.columns == 4 && snapshot.rowCount == 1
        && snapshot.text == ["next"]
    )
    #expect(snapshot.selection == nil && snapshot.searchMatchCount == 0)
  }

  @Test(.enabled(if: hasMetal))
  func `detached blinking text does not start a timer`() async throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    defer { view.stopBlinking() }
    session.feed(Array("\u{1B}[5mblink".utf8))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 320,
      height: 200,
      mipmapped: false,
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    let texture = try #require(
      view.renderer.device.makeTexture(descriptor: descriptor)
    )
    func renderBlinkingText() throws {
      let command = try view.renderer.render(session.snapshot(), to: texture)
      command.waitUntilCompleted()
      try #require(command.status == .completed)
    }
    try renderBlinkingText()
    try #require(view.renderer.hasBlinkingText)
    #expect(view.window == nil)
    view.updateBlinkTimer()
    let deadline = ContinuousClock.now + .seconds(BlinkState.interval * 2 + 0.1)
    var stayedVisible = true
    while ContinuousClock.now < deadline {
      stayedVisible = stayedVisible && view.renderer.options.textBlinkVisible
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(stayedVisible)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `hidden and detached views suspend animated shader frames`(
    _ animated: Bool
  ) async throws {
    let view = try TerminalUIView(session: TerminalSession())
    if animated {
      try view.renderer.setPostProcessShader(
        """
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            return float4(sin(u.time), 0, 0, 1);
        }
        """
      )
    }
    let window = makeWindow()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    let container = UIView(frame: view.frame)
    window.addSubview(container)
    container.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    view.sceneDidActivate()
    #expect(view.isPaused == !animated)
    #expect(!view.enableSetNeedsDisplay)

    container.isHidden = true
    try await Task.sleep(for: .milliseconds(50))
    #expect(view.isPaused && !view.enableSetNeedsDisplay)
    container.isHidden = false
    try await Task.sleep(for: .milliseconds(50))
    #expect(view.isPaused == !animated)

    for surface in [view, container, window] {
      surface.alpha = 0
      try await Task.sleep(for: .milliseconds(50))
      #expect(view.isPaused && !view.enableSetNeedsDisplay)
      surface.alpha = 0.25
      try await Task.sleep(for: .milliseconds(50))
      #expect(view.isPaused == !animated)
    }

    let wrapper = UIView(frame: container.frame)
    window.addSubview(wrapper)
    wrapper.addSubview(container)
    wrapper.isHidden = true
    try await Task.sleep(for: .milliseconds(50))
    #expect(view.isPaused && !view.enableSetNeedsDisplay)
    wrapper.isHidden = false
    try await Task.sleep(for: .milliseconds(50))
    #expect(view.isPaused == !animated)

    view.removeFromSuperview()
    #expect(view.isPaused && !view.enableSetNeedsDisplay)

    window.addSubview(view)
    view.sceneDidActivate()
    #expect(view.isPaused == !animated)
    view.sceneDidEnterBackground()
    #expect(view.isPaused && !view.enableSetNeedsDisplay)
    view.sceneWillEnterForeground()
    #expect(view.isPaused == !animated)
  }

  @Test(.enabled(if: hasMetal))
  func `taps below a scrolled viewport do not move an invisible prompt cursor`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(
      Array(
        "row0\r\nrow1\r\nrow2\r\nrow3\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abc"
          .utf8
      )
    )
    session.scrollViewport(by: 1)
    view.draw(in: view)
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    let rect = view.geometry.rect(column: 2, row: 2)
    let tap = ReviewTapGesture()
    tap.point = CGPoint(x: rect.midX, y: rect.midY)
    _ = view.perform(NSSelectorFromString("handleTap:"), with: tap)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["unchanged", "append", "evict", "reset", "resize", "alternate"]
  )
  func `command output menu actions revalidate their captured command`(
    _ change: String
  ) throws {
    var configuration = SessionConfiguration()
    configuration.scrollbackLimitRows = 0
    let session = TerminalSession(
      columns: 10,
      rows: 3,
      configuration: configuration
    )
    let view = try TerminalUIView(session: session)
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C\u{7}"
    session.feed(Array((prompt + "out1").utf8))
    let rect = view.geometry.rect(column: 0, row: 1)
    let config = UIEditMenuConfiguration(
      identifier: nil,
      sourcePoint: CGPoint(x: rect.midX, y: rect.midY)
    )
    let menu = try #require(
      view.editMenuInteraction(
        view.editMenu,
        menuFor: config,
        suggestedActions: []
      )
    )
    let action = try #require(
      menu.children.compactMap { $0 as? UIAction }
        .first { $0.title == "Select Command Output" }
    )
    if change == "append" {
      session.feed(Array("\r\nout2".utf8))
    } else if change == "evict" {
      session.feed(
        Array(
          ("\r\n\u{1B}]133;D;0\u{7}" + prompt
            + "new\r\n\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ")
            .utf8
        )
      )
    } else if change == "reset" {
      session.reset()
      session.feed(Array((prompt + "other").utf8))
    } else if change == "resize" {
      session.resize(columns: 20, rows: 3)
    } else if change == "alternate" {
      session.feed(Array(("\u{1B}[?1049h" + prompt + "other").utf8))
    }
    UIControl().sendAction(action)
    let selected = session.withState { $0.selectionText }
    if change != "unchanged", change != "append" {
      #expect(selected == nil && !view.hasSelection)
    } else {
      #expect(
        TestFixture(selected)
          == TestFixture(change == "append" ? "out1\nout2" : "out1")
      )
      #expect(view.hasSelection)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `command output menus below a scrolled grid use its visible boundary`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let prompt = "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C\u{7}"
    session.feed(
      Array(
        (prompt + "out1\r\n\u{1B}]133;D;0\u{7}" + prompt
          + "out2\r\n\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ")
          .utf8
      )
    )
    session.scrollViewport(by: 1)
    view.draw(in: view)
    let rect = view.geometry.rect(column: 0, row: 2)
    let config = UIEditMenuConfiguration(
      identifier: nil,
      sourcePoint: CGPoint(x: rect.midX, y: rect.midY)
    )
    let menu = view.editMenuInteraction(
      view.editMenu,
      menuFor: config,
      suggestedActions: []
    )
    #expect(
      menu?.children
        .contains { ($0 as? UIAction)?.title == "Select Command Output" }
        == true
    )
  }

  @Test(.enabled(if: hasMetal))
  func
    `configured background opacity applies once to terminal cells and padding`()
    throws
  {
    let session = TerminalSession(columns: 2, rows: 1)
    let view = try TerminalUIView(
      session: session,
      configuration: Configuration.configured([("background-opacity", "0.5")])
    )
    session.feed(Array("\u{1B}[?25l ".utf8))
    let cw = Int(view.renderer.cellSize.width)
    let ch = Int(view.renderer.cellSize.height)
    let width = cw * 2 + 16
    let height = ch + 16
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: height,
      mipmapped: false,
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(
      view.renderer.device.makeTexture(descriptor: descriptor)
    )
    let command = try view.renderer.render(session.snapshot(), to: texture)
    command.waitUntilCompleted()
    try #require(
      command.status == .completed,
      Comment(rawValue: escapedTestText("\(String(describing: command.error))"))
    )
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &pixels,
      bytesPerRow: width * 4,
      from: MTLRegionMake2D(0, 0, width, height),
      mipmapLevel: 0
    )
    let x = Int(view.renderer.options.paddingX) + cw / 2
    let y = Int(view.renderer.options.paddingY) + ch / 2
    let cell = (y * width + x) * 4
    #expect(Array(pixels[cell ..< cell + 4]) == Array(pixels[0 ..< 4]))
    #expect(pixels[cell + 3] == 127)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (CGFloat(-20), CGFloat(1)), (0, 1), (0.5, 1), (201, 200), (1000, 200),
      (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1),
      (.nan, 13),
    ]
  )
  func `initial font overrides use the same bounds as zoom`(
    _ input: CGFloat,
    _ expected: CGFloat
  ) throws {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 10, rows: 2),
      fontSize: input
    )
    #expect(view.fontSize == expected)
    #expect(view.renderer.font.descriptor.size == expected)
    view.apply(Configuration.configured([("font-size", "20")]))
    #expect(
      view.fontSize == expected
        && view.renderer.font.descriptor.size == expected
    )
    view.setFontSize(input)
    #expect(
      view.fontSize == expected
        && view.renderer.font.descriptor.size == expected
    )
    #expect(
      view.renderer.cellSize.width.isFinite && view.renderer.cellSize.width > 0
    )
    #expect(
      view.renderer.cellSize.height.isFinite
        && view.renderer.cellSize.height > 0
    )
    view.setFontSize(nil)
    #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      (Double(-20), Double(1)), (0, 1), (0.5, 1), (201, 200),
      (.greatestFiniteMagnitude, 200), (.infinity, 200), (-.infinity, 1),
      (.nan, 13),
    ]
  )
  func `programmatic configuration sizes remain bounded`(
    _ input: Double,
    _ expected: Double
  ) throws {
    var configuration = Configuration()
    configuration.fontSize = input
    let view = try TerminalUIView(
      session: TerminalSession(columns: 10, rows: 2),
      configuration: configuration
    )
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
    view.apply(Configuration.configured([("font-size", "20")]))
    #expect(view.fontSize == 20 && view.renderer.font.descriptor.size == 20)
    view.apply(configuration)
    #expect(
      view.fontSize == CGFloat(expected)
        && view.renderer.font.descriptor.size == CGFloat(expected)
    )
  }

  @Test(.enabled(if: hasMetal))
  func `pinch zoom applies the first and final scale`() throws {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 10, rows: 3),
      configuration: Configuration.configured([("font-size", "20")]),
    )
    let pinch = ReviewPinchGesture()
    pinch.state = .began
    pinch.scale = 1.2
    _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
    #expect(view.fontSize == 24)
    pinch.state = .changed
    pinch.scale = 1.3
    _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
    #expect(view.fontSize == 26)
    pinch.state = .ended
    pinch.scale = 1.5
    _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
    #expect(view.fontSize == 30)
  }

  @Test(.enabled(if: hasMetal), arguments: [1, 3, 100, 200])
  func
    `zoom actions follow their direction throughout the configured font range`(
      _ size: Int
    ) throws
  {
    let view = try TerminalUIView(
      session: TerminalSession(columns: 10, rows: 3),
      configuration: Configuration.configured([("font-size", "\(size)")]),
    )
    #expect(view.perform(.increaseFontSize(1)))
    #expect(view.fontSize == CGFloat(min(size + 1, 200)))
    #expect(view.perform(.resetFontSize))
    #expect(view.perform(.decreaseFontSize(1)))
    #expect(view.fontSize == CGFloat(max(size - 1, 1)))
  }

  @Test(.enabled(if: hasMetal))
  func
    `reopening search restores the retained query and refocusing preserves navigation`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    session.feed(Array("needle0\r\nneedle1\r\nneedle2".utf8))
    view.showSearch(text: "needle")
    #expect(session.snapshot().searchMatchCount == 3)
    #expect(session.snapshot().searchSelectedIndex == 2)
    #expect(view.navigateSearch(next: true))
    #expect(session.snapshot().searchSelectedIndex == 1)
    view.showSearch(text: nil)
    #expect(session.snapshot().searchSelectedIndex == 1)
    view.hideSearch()
    #expect(session.snapshot().searchMatchCount == 0)
    #expect(TestFixture(view.searchBar.field.text) == TestFixture("needle"))
    session.feed(Array("\r\nneedle3".utf8))
    view.showSearch(text: nil)
    #expect(session.snapshot().searchMatchCount == 4)
    #expect(session.snapshot().searchSelectedIndex == 3)
    #expect(TestFixture(view.searchBar.count.text) == TestFixture("4/4"))
  }

  @Test(.enabled(if: hasMetal))
  func
    `configuration reloads preserve terminal colors until the configured palette changes`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    view.traitOverrides.userInterfaceStyle = .dark
    view.updateTraitsIfNeeded()
    #expect(view.traitCollection.userInterfaceStyle == .dark)
    view.applyColorScheme()
    session.feed(Array("\u{1B}]10;#123456\u{7}\u{1B}]4;1;#ABCDEF\u{7}".utf8))
    #expect(session.withState { $0.palette.foreground } == 0x123456)
    view.apply(Configuration.configured([("font-size", "18")]))
    #expect(session.withState { $0.palette.foreground } == 0x123456)
    #expect(session.withState { $0.palette.colors[1] } == 0xABCDEF)
    view.apply(
      Configuration.configured([
        ("font-size", "18"), ("foreground", "#654321"),
        ("palette", "1=#FEDCBA"),
      ])
    )
    #expect(session.withState { $0.palette.foreground } == 0x654321)
    #expect(session.withState { $0.palette.colors[1] } == 0xFEDCBA)
    session.feed(Array("\u{1B}]10;#123456\u{7}".utf8))
    view.apply(
      Configuration.configured([
        ("font-size", "20"), ("foreground", "#654321"),
        ("palette", "1=#FEDCBA"),
      ])
    )
    #expect(session.withState { $0.palette.foreground } == 0x123456)
  }

  @Test(.enabled(if: hasMetal))
  func
    `appearance changes report the scheme without resetting an identical palette`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    view.apply(Configuration.configured([("theme", "Swiftty Dark")]))
    view.traitOverrides.userInterfaceStyle = .dark
    view.updateTraitsIfNeeded()
    #expect(view.traitCollection.userInterfaceStyle == .dark)
    view.applyColorScheme()
    session.feed(Array("\u{1B}[?2031h\u{1B}]10;#123456\u{7}".utf8))
    let writes = Mutex<[[UInt8]]>([])
    session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
    view.traitOverrides.userInterfaceStyle = .light
    view.updateTraitsIfNeeded()
    #expect(view.traitCollection.userInterfaceStyle == .light)
    view.applyColorScheme()
    #expect(session.withState { $0.palette.foreground } == 0x123456)
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[?997;2n".utf8)])
    )
    let adaptive = Configuration.configured([
      ("theme", "light:Swiftty Light,dark:Swiftty Dark")
    ])
    view.apply(adaptive)
    session.feed(Array("\u{1B}]10;#123456\u{7}".utf8))
    writes.withLock { $0.removeAll() }
    view.traitOverrides.userInterfaceStyle = .dark
    view.updateTraitsIfNeeded()
    view.applyColorScheme()
    #expect(session.withState { $0.palette } == adaptive.palette(for: .dark))
    #expect(
      TestFixture(writes.withLock { $0 })
        == TestFixture([Array("\u{1B}[?997;1n".utf8)])
    )
  }

  @Test(.enabled(if: hasMetal))
  func `extreme cell sizes and padding remain safe during layout`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let configuration = Configuration.configured([
      ("adjust-cell-height", "1e308"), ("window-padding-x", "1e308"),
    ])
    let view = try TerminalUIView(
      session: session,
      configuration: configuration
    )
    view.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    let size = session.withState {
      ($0.columns, $0.rows, $0.cellPixelSize.height)
    }
    #expect(size.0 == 1 && size.1 == 1 && size.2 == Int.max)
  }

  @Test(.enabled(if: hasMetal))
  func `navigation actions report whether they can run`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    #expect(!view.perform(.scrollPageUp))
    #expect(!view.perform(.jumpToPrompt(-1)))
    #expect(!view.perform(.navigateSearch(next: true)))
    #expect(!view.perform(.searchSelection))
    #expect(!view.perform(.endSearch))
    session.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
    #expect(view.perform(.scrollPageUp))
    #expect(view.perform(.scrollToBottom))
    #expect(!view.perform(.scrollToBottom))
  }

  @Test(.enabled(if: hasMetal))
  func `search count follows program output`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(Array("foo".utf8))
    view.showSearch(text: "foo")
    #expect(TestFixture(view.searchBar.count.text) == TestFixture("1/1"))
    session.feed(Array(" foo".utf8))
    view.draw(in: view)
    #expect(TestFixture(view.searchBar.count.text) == TestFixture("1/2"))
    session.feed(Array("\u{1B}[2J".utf8))
    view.draw(in: view)
    #expect(TestFixture(view.searchBar.count.text) == TestFixture("0"))
  }

}

#endif
