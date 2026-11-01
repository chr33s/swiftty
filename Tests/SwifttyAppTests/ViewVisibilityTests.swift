import AppKit
import MetalKit
import SwiftMuxExport
import SwiftMuxProtocol
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Testing

@MainActor
@Suite(.serialized)
struct ViewVisibilityTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  init() { DisplayAccommodations.override = DisplayAccommodations() }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func hiddenFramesDoNotAdvanceEitherInteractionBaseline(_ mux: Bool) throws {
    _ = NSApplication.shared
    let session = TerminalSession(columns: 20, rows: 4)
    let direct = try TerminalView(
      configuration: Configuration(),
      session: session
    )
    let pane = try MuxPaneView(pane: .init(), configuration: Configuration())
    let view: MTKView = mux ? pane : direct
    let renderer = mux ? pane.renderer : direct.renderer
    let window = VisibilityWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = view
    let server = ServerInstanceID()
    let attachment = AttachmentID()
    func feed(_ text: String, revision: UInt64) throws {
      session.feed(Array(text.utf8))
      if mux {
        let frame = try FrameExporter.frame(
          from: session.withState { $0.captureOwnedScreen() },
          identity: .init(
            server: server,
            attachment: attachment,
            pane: pane.pane,
            revision: revision,
            layoutRevision: 1,
            geometryGeneration: 0,
            viewportRevision: 0
          )
        )
        pane.receive(
          try #require(MuxPaneView.importFrame(frame, limits: .init())),
          server: server
        )
      }
    }
    func draw() {
      if mux { pane.draw(in: pane) } else { direct.draw(in: direct) }
    }
    func text() -> String? {
      if mux { return pane.accessibilityValue() as? String }
      return direct.accessibilityValue() as? String
    }
    try feed("shown", revision: 1)
    draw()
    try #require(renderer.waitUntilIdle(timeout: .now() + 2))
    try #require(text()?.contains("shown") == true)
    let baseline = text()
    view.isHidden = true
    try feed("\r\nnew output", revision: 2)
    draw()
    #expect(text() == baseline)
    if mux { #expect(pane.presented?.frame.identity.revision == 1) }
    view.isHidden = false
    draw()
    try #require(renderer.waitUntilIdle(timeout: .now() + 2))
    #expect(text()?.contains("new output") == true)
    if mux { #expect(pane.presented?.frame.identity.revision == 2) }
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["view", "parent", "window", "reparent"]
  )
  func `transparent animated surfaces suspend and resume through restart`(
    _ target: String
  ) async throws {
    _ = NSApplication.shared
    let window = VisibilityWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    let view = try TerminalView(
      configuration: Configuration.parse("command=/bin/sleep 30")
    )
    defer {
      view.stop();
      window.close()
    }
    try view.renderer.setPostProcessShader(
      """
      float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
          return float4(sin(u.time), 0, 0, 1);
      }
      """
    )
    let outer = NSView(frame: window.contentLayoutRect)
    let parent = NSView(frame: outer.bounds)
    let replacement = NSView(frame: outer.bounds)
    window.contentView = outer
    outer.addSubview(parent)
    outer.addSubview(replacement)
    view.frame = parent.bounds
    parent.addSubview(view)
    view.draw(in: view)
    try #require(!view.isPaused && !view.enableSetNeedsDisplay)
    switch target {
    case "view": view.alphaValue = 0
    case "parent": parent.alphaValue = 0
    case "window": window.alphaValue = 0
    default:
      replacement.alphaValue = 0
      replacement.addSubview(parent)
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    view.session.feed(Array("pending".utf8))
    view.draw(in: view)
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    view.stop()
    try view.start()
    #expect(view.isPaused && view.enableSetNeedsDisplay)
    switch target {
    case "view": view.alphaValue = 0.25
    case "parent": parent.alphaValue = 0.25
    case "window": window.alphaValue = 0.25
    default: replacement.alphaValue = 0.25
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!view.isPaused && !view.enableSetNeedsDisplay)
  }

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func
    `opacity observations release removed surfaces while the parent remains alive`(
      _ pendingPulse: Bool
    ) async throws
  {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    let window = VisibilityWindow(
      contentRect: parent.bounds,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = parent
    defer { window.close() }
    weak var retained: TerminalView?
    do {
      let view = try TerminalView(configuration: Configuration())
      retained = view
      view.frame = parent.bounds
      parent.addSubview(view)
      if pendingPulse {
        view.alphaValue = 0
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.duration = 10
        view.layer?.add(opacity, forKey: "terminalPulse")
        view.needsDisplay = true
      } else {
        parent.alphaValue = 0
      }
      view.removeFromSuperview()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(retained == nil)
    parent.alphaValue = 0.25
    try await Task.sleep(for: .milliseconds(50))
    #expect(retained == nil)
  }

  @Test(.enabled(if: hasMetal), arguments: ["view", "parent"], [false, true])
  func `shader drawing resumes for output queued before an opacity pulse`(
    _ target: String,
    _ retainedAnimation: Bool
  ) async throws {
    _ = NSApplication.shared
    let window = VisibilityWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    let view = try TerminalView(configuration: Configuration())
    defer {
      view.stop();
      window.close()
    }
    let parent = NSView(frame: window.contentLayoutRect)
    parent.wantsLayer = true
    view.frame = parent.bounds
    let surface: NSView = target == "view" ? view : parent
    let layer = PresentationLayer()
    let presented = PresentationLayer()
    layer.renderedLayer = presented
    surface.layer = layer
    window.contentView = parent
    parent.addSubview(view)
    try view.renderer.setPostProcessShader(
      """
      float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
          return float4(sin(u.time), 0, 0, 1);
      }
      """
    )
    surface.alphaValue = 0
    presented.opacity = 0
    try await Task.sleep(for: .milliseconds(30))
    _ = view.session.snapshot()
    view.needsDisplay = false
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    opacity.duration = 10
    opacity.isRemovedOnCompletion = !retainedAnimation
    opacity.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
    layer.add(opacity, forKey: "terminalPulse")
    view.session.feed(Array("pending".utf8))
    try await Task.sleep(for: .milliseconds(30))
    let requestedWhileTransparent = view.needsDisplay
    #expect(!requestedWhileTransparent)
    #expect(view.isPaused)
    presented.opacity = 0.5
    let deadline = ContinuousClock.now + .milliseconds(300)
    while view.isPaused, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!view.isPaused && !view.enableSetNeedsDisplay)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["completed", "pausedAnimation", "pausedLayer"]
  )
  func `inactive retained opacity animations do not keep a redraw pending`(
    _ state: String
  ) async throws {
    _ = NSApplication.shared
    let window = VisibilityWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false,
    )
    window.isReleasedWhenClosed = false
    let view = try TerminalView(configuration: Configuration())
    defer {
      view.stop();
      window.close()
    }
    let parent = NSView(frame: window.contentLayoutRect)
    parent.wantsLayer = true
    let layer = PresentationLayer()
    let presented = PresentationLayer()
    layer.renderedLayer = presented
    parent.layer = layer
    window.contentView = parent
    view.frame = parent.bounds
    parent.addSubview(view)
    try view.renderer.setPostProcessShader(
      """
      float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
          return float4(sin(u.time), 0, 0, 1);
      }
      """
    )
    parent.alphaValue = 0
    presented.opacity = 0
    try await Task.sleep(for: .milliseconds(30))
    _ = view.session.snapshot()
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    opacity.duration = 0.1
    opacity.isRemovedOnCompletion = false
    opacity.beginTime =
      layer.convertTime(CACurrentMediaTime(), from: nil)
      - (state == "completed" ? 1 : 0)
    if state == "pausedAnimation" { opacity.speed = 0 }
    if state == "pausedLayer" { layer.speed = 0 }
    layer.add(opacity, forKey: "terminalPulse")
    view.session.feed(Array("pending".utf8))
    try await Task.sleep(for: .milliseconds(50))
    // An inactive animation must not leave a retry that can wake the shader later.
    presented.opacity = 0.5
    try await Task.sleep(for: .milliseconds(50))
    #expect(view.isPaused && view.enableSetNeedsDisplay)
  }
}

/// Supply visibility without ordering test windows onto the user's desktop.
/// Actual drawable presentation and callback counts are checked by the native probe.
@MainActor
private final class VisibilityWindow: NSWindow {
  override var isVisible: Bool { true }

  override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

/// Supplies presentation opacity independently of model alpha, without a compositor.
private final class PresentationLayer: CAMetalLayer, @unchecked Sendable {
  var renderedLayer: PresentationLayer?

  override func presentation() -> Self? { renderedLayer as? Self }
}
