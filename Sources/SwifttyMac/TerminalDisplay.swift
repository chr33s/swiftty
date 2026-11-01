import AppKit
import MetalKit
import SwifttyCore

/// The native surfaces share display admission, visibility, retry and blink
/// scheduling. Snapshot acquisition and accepted-frame bookkeeping stay with
/// the direct or mux adapter. This object owns neither a session nor a PTY.
@MainActor
package final class TerminalDisplay {
  private weak var view: MTKView?
  private let renderer: MetalRenderer
  private let suspendsWhenOccluded: Bool
  package enum SubmissionPolicy { case waitForGPU, availableGPUOnly }
  private let submissionPolicy: SubmissionPolicy
  private var blinkTimer: Timer?
  private var blinkOn = true
  private var cursorBlinks = false
  package var isStopped = false
  private var submittedFrame: UInt64 = 0
  private var retryScheduled = false
  private var retryFrame: UInt64?
  private var visibilityObservers: [NSKeyValueObservation] = []

  /// Direct embedders suspend on occlusion. Native mux preserves its existing
  /// ability to admit an attached window's frame while another window covers it.
  package init(
    view: MTKView,
    renderer: MetalRenderer,
    suspendsWhenOccluded: Bool = true,
    submissionPolicy: SubmissionPolicy = .waitForGPU
  ) {
    self.view = view
    self.renderer = renderer
    self.suspendsWhenOccluded = suspendsWhenOccluded
    self.submissionPolicy = submissionPolicy
  }

  isolated deinit { blinkTimer?.invalidate() }

  package static func makeRenderer(
    configuration: Configuration
  ) throws -> MetalRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw RendererError.setup("no Metal device")
    }
    return try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: configuration.fontDescriptor(scale: 2)
    )
  }

  package static func prepare(_ view: MTKView) {
    (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    view.autoResizeDrawable = true
  }

  package func apply(configuration: Configuration, scale: CGFloat) {
    view?.layer?.isOpaque = configuration.backgroundOpacity >= 1
    renderer.options = Self.merge(
      configured: configuration.renderOptions(scale: scale),
      current: renderer.options
    )
  }

  package static func merge(
    configured: RenderOptions,
    current: RenderOptions
  ) -> RenderOptions {
    var options = configured
    options.preedit = current.preedit
    options.preeditSelection = current.preeditSelection
    options.hoveredLink = current.hoveredLink
    options.underlinedSpan = current.underlinedSpan
    options.textBlinkVisible = current.textBlinkVisible
    options.cursorVisible = current.cursorVisible
    options.isFocused = current.isFocused
    return options
  }

  package func loadShader(_ path: String?) {
    do {
      try renderer.setPostProcessShader(
        path.map { try String(contentsOfFile: $0, encoding: .utf8) }
      )
    } catch {
      FileHandle.standardError.write(
        Data("swiftty: custom-shader: \(error)\n".utf8)
      )
      try? renderer.setPostProcessShader(nil)
    }
  }

  /// Called by the view's needsDisplay setter to avoid scheduling hidden work.
  package func shouldInvalidate() -> Bool {
    switch surfaceVisibility {
    case .hidden: return false
    case .awaitingOpacity:
      retryDraw(frame: submittedFrame)
      return false
    case .visible: return true
    }
  }

  /// Only success may advance the adapter's interaction baseline. Refused
  /// submissions retain no queue here; the adapter provides its newest frame.
  package func submit(
    _ snapshot: RenderSnapshot,
    focused: Bool,
    cursorBlink: Bool?
  ) -> MetalRenderer.SubmitResult {
    guard let view else { return .noDrawable }
    cursorBlinks = cursorBlink ?? snapshot.cursor.isBlinking
    renderer.options.isFocused = focused
    renderer.options.cursorVisible = blinkOn || !cursorBlinks || !focused
    renderer.options.textBlinkVisible = blinkOn
    var result = MetalRenderer.SubmitResult.noDrawable
    if isSurfaceVisible {
      submittedFrame &+= 1
      let frame = submittedFrame
      let onPresented: @Sendable (any MTLDrawable) -> Void = {
        [weak self] drawable in
        guard drawable.presentedTime == 0 else { return }
        DispatchQueue.main.async { self?.retryDraw(frame: frame) }
      }
      switch submissionPolicy {
      case .waitForGPU:
        if let drawable = view.currentDrawable,
          view.currentRenderPassDescriptor != nil
        {
          drawable.addPresentedHandler(onPresented)
          result =
            renderer.draw(snapshot, in: view)
            ? .submitted : .resourceUnavailable
        }
      case .availableGPUOnly:
        // Acquiring a drawable can itself wait. The renderer checks capacity
        // first, and only then installs the presentation callback.
        result = renderer.tryDraw(snapshot, in: view, onPresented: onPresented)
      }
    }
    if result != .submitted { retryDraw(frame: submittedFrame) }
    updateFrameDriving()
    return result
  }

  package var isSurfaceVisible: Bool { surfaceVisibility == .visible }

  package enum SurfaceVisibility { case hidden, awaitingOpacity, visible }

  package var surfaceVisibility: SurfaceVisibility {
    guard let view else { return .hidden }
    guard let window = view.window, window.isVisible,
      (!suspendsWhenOccluded || window.occlusionState.contains(.visible)),
      window.alphaValue > 0, !view.isHiddenOrHasHiddenAncestor,
      view.bounds.width > 0, view.bounds.height > 0
    else { return .hidden }
    var awaitingOpacity = false
    var ancestor: NSView? = view
    while let view = ancestor {
      if view.alphaValue <= 0 {
        guard let layer = view.layer, hasOpacityAnimation(layer) else {
          return .hidden
        }
        if (layer.presentation()?.opacity ?? 0) <= 0 {
          guard hasOpacityAnimation(layer, awaitingPresentation: true) else {
            return .hidden
          }
          awaitingOpacity = true
        }
      }
      ancestor = view.superview
    }
    return awaitingOpacity ? .awaitingOpacity : .visible
  }

  private func hasOpacityAnimation(
    _ layer: CALayer,
    awaitingPresentation: Bool = false
  ) -> Bool {
    layer.animationKeys()?
      .contains { key in
        guard let animation = layer.animation(forKey: key) else { return false }
        if awaitingPresentation {
          var speed = animation.speed
          var ancestor: CALayer? = layer
          while let current = ancestor {
            speed *= current.speed
            ancestor = current.superlayer
          }
          guard speed != 0 else { return false }
          // Retained animations still run; stop polling only after their active time ends.
          // Core Animation resolves a zero begin time when it commits the animation.
          if !animation.isRemovedOnCompletion, animation.beginTime != 0 {
            let time =
              (layer.convertTime(CACurrentMediaTime(), from: nil)
                - animation.beginTime) * Double(animation.speed)
              + animation.timeOffset
            let cycles =
              animation.repeatCount > 0 ? Double(animation.repeatCount) : 1
            let duration =
              animation.repeatDuration > 0
              ? animation.repeatDuration
              : animation.duration * (animation.autoreverses ? 2 : 1) * cycles
            if speed > 0 ? time >= duration : time <= 0 { return false }
          }
        }
        return Self.animatesOpacity(animation)
      } ?? false
  }

  private static func animatesOpacity(_ animation: CAAnimation) -> Bool {
    if let property = animation as? CAPropertyAnimation {
      return property.keyPath == "opacity"
    }
    return (animation as? CAAnimationGroup)?.animations?
      .contains(where: animatesOpacity) ?? false
  }

  package func observeVisibility() {
    guard let view else { return }
    visibilityObservers.removeAll()
    // Opacity composites the existing frame; redraw only when transparency ends.
    let refresh: @Sendable (Bool) -> Void = { [weak self] becameVisible in
      DispatchQueue.main.async {
        guard let self else { return }
        self.updateFrameDriving()
        if becameVisible, self.isSurfaceVisible {
          self.view?.needsDisplay = true
        }
      }
    }
    var ancestor: NSView? = view
    while let view = ancestor {
      visibilityObservers.append(
        view.observe(\.alphaValue, options: [.old, .new]) { _, change in
          refresh(change.oldValue == 0 && (change.newValue ?? 0) > 0)
        }
      )
      ancestor = view.superview
    }
    if let window = view.window {
      visibilityObservers.append(
        window.observe(\.alphaValue, options: [.old, .new]) { _, change in
          refresh(change.oldValue == 0 && (change.newValue ?? 0) > 0)
        }
      )
    }
  }

  package func updateFrameDriving() {
    guard let view else { return }
    let rate = view.window?.screen?.maximumFramesPerSecond ?? 60
    if view.preferredFramesPerSecond != rate {
      view.preferredFramesPerSecond = rate
    }
    // A shader that animates needs frames without new output.
    let animating = renderer.isAnimating && !isStopped && isSurfaceVisible
    if animating == view.isPaused {
      view.isPaused = !animating
      view.enableSetNeedsDisplay = !animating
    }
    updateBlinkTimer()
  }

  private func retryDraw(frame: UInt64) {
    guard let view else { return }
    guard !isStopped, !renderer.isAnimating || view.isPaused,
      submittedFrame == frame, surfaceVisibility != .hidden
    else { return }
    retryFrame = frame
    guard !retryScheduled else { return }
    retryScheduled = true
    let delay = 1 / Double(max(1, view.preferredFramesPerSecond))
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, let view = self.view else { return }
      retryScheduled = false
      guard let frame = retryFrame else { return }
      retryFrame = nil
      guard !isStopped, !renderer.isAnimating || view.isPaused,
        submittedFrame == frame, surfaceVisibility != .hidden
      else { return }
      if isSurfaceVisible {
        updateFrameDriving()
        view.needsDisplay = true
      } else {
        retryDraw(frame: frame)
      }
    }
  }

  private func updateBlinkTimer() {
    let needed =
      !isStopped && isSurfaceVisible
      && ((cursorBlinks && renderer.options.isFocused)
        || renderer.hasBlinkingText)
    if needed, blinkTimer == nil {
      blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) {
        [weak self] timer in
        guard let self else {
          timer.invalidate();
          return
        }
        let identity = ObjectIdentifier(timer)
        MainActor.assumeIsolated {
          guard self.blinkTimer.map(ObjectIdentifier.init) == identity else {
            return
          }
          guard self.isSurfaceVisible else {
            self.updateFrameDriving();
            return
          }
          self.blinkOn.toggle()
          self.view?.needsDisplay = true
        }
      }
    } else if !needed, let timer = blinkTimer {
      timer.invalidate()
      blinkTimer = nil
      if !blinkOn {
        blinkOn = true
        view?.needsDisplay = true
      }
    }
  }

  /// Input shows the cursor at once and restarts its blink.
  package func resetBlink() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    if !blinkOn {
      blinkOn = true
      view?.needsDisplay = true
    }
  }

}
