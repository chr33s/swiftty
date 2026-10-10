#if canImport(UIKit)
import MetalKit
import QuartzCore
import SwifttyCore
@testable import SwifttyMobile
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct ViewDrawLifecycleTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  private func foregroundScene() async throws -> UIWindowScene {
    let deadline = ContinuousClock.now + .seconds(2)
    var scene: UIWindowScene?
    repeat {
      scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      if scene != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return try #require(scene)
  }

  @Test(.enabled(if: hasMetal))
  func `a single update after idle is presented and drawing stops again`()
    async throws
  {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    var configuration = Configuration()
    configuration.cursorStyleBlink = false
    let view = try TerminalUIView(
      session: TerminalSession(),
      configuration: configuration
    )
    view.frame = window.bounds
    view.session.feed(Array("\u{1B}[?25l".utf8))
    let delegate = DrawRecorder()
    delegate.onDraw = { [weak delegate] view in
      guard let delegate else { return }
      let update = delegate.awaitingUpdate
      #if targetEnvironment(simulator)
      // The simulator SDK lacks drawable presentation callbacks.
      if update {
        delegate.updatePresented = true
      } else {
        delegate.initialPresented = true
      }
      #else
      guard let drawable = view.currentDrawable else { return }
      drawable.addPresentedHandler { [weak delegate] drawable in
        guard drawable.presentedTime > 0 else { return }
        DispatchQueue.main.async {
          if update {
            delegate?.updatePresented = true
          } else {
            delegate?.initialPresented = true
          }
        }
      }
      #endif
    }
    view.delegate = delegate
    window.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    var deadline = ContinuousClock.now + .seconds(2)
    while !delegate.initialPresented, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(delegate.initialPresented)
    try await Task.sleep(for: .seconds(1))
    delegate.awaitingUpdate = true
    view.session.feed(Array("Z".utf8))
    deadline = ContinuousClock.now + .seconds(2)
    while !delegate.updatePresented, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(delegate.updatePresented)
    #expect(view.lastCursor?.x == 1)
    try await Task.sleep(for: .milliseconds(100))
    let before = delegate.draws
    try await Task.sleep(for: .milliseconds(200))
    #expect(delegate.draws == before)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      "view", "window", "size", "parent", "reparent", "viewAlpha",
      "parentAlpha", "windowAlpha",
    ],
    [false, true],
  )
  func `invisible surfaces defer output until visible`(
    _ transition: String,
    _ animated: Bool
  ) async throws {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    var configuration = Configuration()
    configuration.cursorStyleBlink = false
    let view = try TerminalUIView(
      session: TerminalSession(),
      configuration: configuration
    )
    if animated {
      try view.renderer.setPostProcessShader(
        """
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            return float4(sin(u.time), 0, 0, 1);
        }
        """
      )
    }
    view.frame = window.bounds
    let delegate = DrawRecorder()
    view.delegate = delegate
    let container = UIView(frame: window.bounds)
    window.addSubview(container)
    container.addSubview(view)
    let wrapper = UIView(frame: window.bounds)
    window.addSubview(wrapper)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    var deadline = ContinuousClock.now + .seconds(2)
    while delegate.presentations == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(delegate.presentations > 0)
    let frame = view.frame
    switch transition {
    case "view": view.isHidden = true
    case "window": window.isHidden = true
    case "parent": container.isHidden = true
    case "reparent":
      wrapper.addSubview(container);
      wrapper.isHidden = true
    case "viewAlpha": view.alpha = 0
    case "parentAlpha": container.alpha = 0
    case "windowAlpha": window.alpha = 0
    default:
      view.frame = .zero;
      view.layoutIfNeeded()
    }
    try await Task.sleep(for: .milliseconds(50))
    let before = delegate.draws
    let presentedBefore = delegate.presentations
    view.session.feed(Array("hidden update".utf8))
    try await Task.sleep(for: .milliseconds(100))
    #expect(delegate.draws == before)
    switch transition {
    case "view": view.isHidden = false
    case "window": window.makeKeyAndVisible()
    case "parent": container.isHidden = false
    case "reparent": wrapper.isHidden = false
    case "viewAlpha": view.alpha = 0.25
    case "parentAlpha": container.alpha = 0.25
    case "windowAlpha": window.alpha = 0.25
    default:
      view.frame = frame;
      view.layoutIfNeeded()
    }
    deadline = ContinuousClock.now + .seconds(2)
    while delegate.presentations == presentedBefore,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(delegate.draws > before)
    #expect(delegate.presentations > presentedBefore)
    #expect(view.lastCursor?.x == "hidden update".count)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: [
      "view", "layer", "group", "pulse", "pulseEarly", "pulseEarlyRetained",
    ],
    [false, true]
  )
  func `fading surfaces draw until transparent and resume during fade in`(
    _ animation: String,
    _ animated: Bool
  ) async throws {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    var configuration = Configuration()
    configuration.cursorStyleBlink = false
    let view = try TerminalUIView(
      session: TerminalSession(),
      configuration: configuration
    )
    if animated {
      try view.renderer.setPostProcessShader(
        """
        float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u) {
            return float4(sin(u.time), 0, 0, 1);
        }
        """
      )
    }
    view.frame = window.bounds
    let delegate = DrawRecorder()
    view.delegate = delegate
    let container = UIView(frame: window.bounds)
    window.addSubview(container)
    container.addSubview(view)
    window.makeKeyAndVisible()
    defer {
      view.removeFromSuperview();
      window.isHidden = true
    }
    var deadline = ContinuousClock.now + .seconds(2)
    while delegate.presentations == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(delegate.presentations > 0)

    deadline = ContinuousClock.now + .seconds(2)
    while container.layer.presentation() == nil, ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(container.layer.presentation()?.opacity == 1)
    var fading = delegate.presentations
    if animation == "view" {
      UIView.animate(withDuration: 0.6) { container.alpha = 0 }
    } else {
      let pulse = animation.hasPrefix("pulse")
      if pulse {
        container.alpha = 0
        try await Task.sleep(for: .milliseconds(100))
        fading = delegate.presentations
      }
      let opacity = CABasicAnimation(keyPath: "opacity")
      opacity.fromValue = pulse ? 0 : 1
      opacity.toValue = pulse ? 1 : 0
      opacity.duration = 0.6
      opacity.autoreverses = pulse
      opacity.isRemovedOnCompletion = animation != "pulseEarlyRetained"
      if animation == "group" {
        let group = CAAnimationGroup()
        group.animations = [opacity]
        group.duration = 0.6
        container.layer.add(group, forKey: "terminalFade")
      } else {
        container.layer.add(opacity, forKey: "terminalFade")
      }
      if !pulse { container.alpha = 0 }
    }
    if animation.hasPrefix("pulseEarly") {
      view.session.feed(Array("fading".utf8))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(container.alpha == 0)
    let opacity = try #require(container.layer.presentation()?.opacity)
    try #require(opacity > 0 && opacity < 1)
    if !animation.hasPrefix("pulseEarly") {
      fading = delegate.presentations
      view.session.feed(Array("fading".utf8))
    }
    deadline = ContinuousClock.now + .milliseconds(300)
    while delegate.presentations == fading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(delegate.presentations > fading)
    #expect(view.lastCursor?.x == 6)
    if animated {
      let animationFrames = delegate.presentations
      try await Task.sleep(for: .milliseconds(50))
      #expect(delegate.presentations > animationFrames)
    }

    deadline = ContinuousClock.now + .seconds(2)
    while (container.layer.presentation()?.opacity ?? 0) > 0,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require((container.layer.presentation()?.opacity ?? 0) == 0)
    try await Task.sleep(for: .milliseconds(100))
    let hidden = delegate.draws
    let presentedBefore = delegate.presentations
    view.session.feed(Array(" visible".utf8))
    try await Task.sleep(for: .milliseconds(100))
    #expect(delegate.draws == hidden)

    UIView.animate(withDuration: 0.6) { container.alpha = 1 }
    deadline = ContinuousClock.now + .milliseconds(300)
    while delegate.presentations == presentedBefore,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(delegate.presentations > presentedBefore)
    #expect(view.lastCursor?.x == 14)
  }

  @Test(.enabled(if: hasMetal))
  func `removed surfaces are released while their container remains alive`()
    async throws
  {
    let scene = try await foregroundScene()
    let window = UIWindow(windowScene: scene)
    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    window.addSubview(container)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    weak var retained: TerminalUIView?
    do {
      let view = try TerminalUIView(session: TerminalSession())
      view.frame = container.bounds
      retained = view
      container.addSubview(view)
      container.isHidden = true
      view.removeFromSuperview()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(retained == nil)
    container.isHidden = false
    try await Task.sleep(for: .milliseconds(50))
    #expect(retained == nil)
  }

  @MainActor
  private final class DrawRecorder: NSObject, MTKViewDelegate {
    var draws = 0
    var presentations = 0
    var onDraw: ((MTKView) -> Void)?
    var awaitingUpdate = false
    var initialPresented = false
    var updatePresented = false
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
      draws += 1
      #if targetEnvironment(simulator)
      presentations += 1
      #else
      view.currentDrawable?
        .addPresentedHandler { [weak self] drawable in
          guard drawable.presentedTime > 0 else { return }
          DispatchQueue.main.async {
            guard let self else { return }
            self.presentations += 1
          }
        }
      #endif
      onDraw?(view)
      (view as? TerminalUIView)?.draw(in: view)
    }
  }
}
#endif
