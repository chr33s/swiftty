import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

extension ViewLifecycleTests {
  @MainActor
  @Suite(.serialized)
  struct ScrollTests {
    nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

    @Test(.enabled(if: hasMetal))
    func `flings account for missed frames and changing refresh intervals`()
      throws
    {
      let session = TerminalSession(columns: 10, rows: 3)
      let view = try TerminalUIView(session: session)
      let window = ViewLifecycleTests().makeWindow()
      view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
      window.addSubview(view)
      window.makeKeyAndVisible()
      defer {
        view.stopMomentum();
        view.removeFromSuperview();
        window.isHidden = true
      }
      session.feed(
        Array((0 ..< 50).map { "row\($0)" }.joined(separator: "\r\n").utf8)
      )
      view.draw(in: view)
      let pan = ReviewScrollGesture()
      pan.speed = CGPoint(x: 0, y: view.geometry.lineHeight * 100)
      let link = ReviewMomentumDisplayLink()
      for start in [20.0, 50.0] {
        // A new gesture cancels the previous fling and resets its
        // fractional scroll, even after a long pause between them.
        pan.state = .began
        _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        pan.state = .ended
        _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
        try #require(view.momentum.isActive && view.momentumLink != nil)
        let initialOffset = session.snapshot().viewportOffset
        var expected = ScrollMomentum(velocity: 100)
        var distance: CGFloat = 0
        var target = start
        for interval in [1.0 / 60, 7.0 / 60, 1.0 / 120, 1.0 / 120] {
          target += interval
          link.displayTimestamp =
            target - (interval > 0.02 ? 1.0 / 60 : interval)
          link.nextTimestamp = target
          _ = view.perform(NSSelectorFromString("momentumFrame:"), with: link)
          distance += expected.step(interval)
          #expect(abs(view.momentum.velocity - expected.velocity) < 1e-9)
          #expect(
            session.snapshot().viewportOffset == initialOffset + Int(distance)
          )
        }
      }
    }

    @Test(
      .enabled(if: hasMetal),
      arguments: [
        "text", "hardware", "accessory", "selection", "composition", "viewport",
        "search", "searchNavigation", "prompt", "selectAll", "accessibility",
        "clear", "reset",
      ]
    )
    func `explicit interactions stop an existing fling`(
      _ interaction: String
    ) async throws {
      let session = TerminalSession(columns: 10, rows: 3)
      let view = try TerminalUIView(session: session)
      defer {
        view.stopMomentum();
        view.releaseHardwareKeys()
      }
      let prefix = interaction == "prompt" ? "\u{1B}]133;A\u{7}" : ""
      session.feed(
        Array(
          (0 ..< 50).map { "\(prefix)row\($0)" }.joined(separator: "\r\n").utf8
        )
      )
      if interaction == "searchNavigation" { view.search("row") }
      session.scrollViewport(by: 20)
      view.draw(in: view)
      let pan = ReviewScrollGesture()
      pan.state = .ended
      pan.speed = CGPoint(x: 0, y: view.geometry.lineHeight * 30)
      _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
      try #require(view.momentum.isActive && view.momentumLink != nil)
      switch interaction {
      case "text": view.insertText("x")
      case "hardware":
        try #require(
          view.keyDown(
            usage: 82,
            modifiers: [],
            base: "\u{F700}",
            characters: "\u{F700}"
          )
        )
      case "accessory": view.accessoryKey(.up)
      case "composition":
        view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
      case "viewport": try #require(view.perform(.scrollToBottom))
      case "search": view.search("row1")
      case "searchNavigation": try #require(view.navigateSearch(next: true))
      case "prompt": try #require(view.perform(.jumpToPrompt(-1)))
      case "selectAll": view.selectAll(nil)
      case "accessibility": try #require(view.accessibilityScroll(.next))
      case "clear": try #require(view.perform(.clearScreen))
      case "reset": try #require(view.perform(.reset))
      default:
        let rect = view.geometry.rect(column: 1, row: 0)
        view.beginSelection(
          at: CGPoint(x: rect.midX, y: rect.midY),
          unit: .word,
          rectangle: false
        )
      }
      #expect(
        !view.momentum.isActive && !view.horizontalMomentum.isActive
          && view.momentumLink == nil
      )
      let expectedOffset =
        switch interaction {
        case "selection", "composition", "selectAll": 20
        case "search": 28
        case "searchNavigation": 1
        case "prompt": 21
        case "accessibility": 18
        default: 0
        }
      #expect(session.snapshot().viewportOffset == expectedOffset)
      try await Task.sleep(for: .milliseconds(150))
      #expect(session.snapshot().viewportOffset == expectedOffset)
    }

    @Test(
      .enabled(if: hasMetal),
      arguments: ["increase", "decrease", "reset", "pinch"]
    )
    func `zoom stops wheel momentum before changing geometry`(
      _ interaction: String
    ) async throws {
      let session = TerminalSession(columns: 10, rows: 3)
      let view = try TerminalUIView(
        session: session,
        configuration: Configuration.parse("font-size=20")
      )
      defer { view.stopMomentum() }
      session.feed(Array("\u{1B}[?1002h\u{1B}[?1006h".utf8))
      view.draw(in: view)
      let writes = Mutex<[[UInt8]]>([])
      session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
      let pan = ReviewScrollGesture()
      pan.state = .ended
      pan.speed = CGPoint(
        x: view.geometry.cellSize.width / view.geometry.scale * 30,
        y: view.geometry.lineHeight * 30,
      )
      _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
      try #require(
        view.momentum.isActive && view.horizontalMomentum.isActive
          && view.momentumLink != nil
      )
      switch interaction {
      case "increase": try #require(view.perform(.increaseFontSize(1)))
      case "decrease": try #require(view.perform(.decreaseFontSize(1)))
      case "reset": try #require(view.perform(.resetFontSize))
      default:
        let pinch = ReviewPinchGesture()
        pinch.state = .began
        pinch.scale = 1  // Even before the fingers change the scale.
        _ = view.perform(NSSelectorFromString("handlePinch:"), with: pinch)
      }
      #expect(
        !view.momentum.isActive && !view.horizontalMomentum.isActive
          && view.momentumLink == nil
      )
      try await Task.sleep(for: .milliseconds(150))
      #expect(writes.withLock { $0.isEmpty })
    }

    @Test(.enabled(if: hasMetal), arguments: ["tap", "secondary", "drag"])
    func `pointer presses stop wheel momentum on both axes`(
      _ interaction: String
    ) async throws {
      let session = TerminalSession(columns: 10, rows: 3)
      let view = try TerminalUIView(session: session)
      defer { view.stopMomentum() }
      session.feed(Array("\u{1B}[?1002h\u{1B}[?1006h".utf8))
      view.draw(in: view)
      let writes = Mutex<[[UInt8]]>([])
      session.onWrite = { bytes in writes.withLock { $0.append(bytes) } }
      let pan = ReviewScrollGesture()
      pan.state = .ended
      pan.speed = CGPoint(
        x: view.geometry.cellSize.width / view.geometry.scale * 30,
        y: view.geometry.lineHeight * 30,
      )
      _ = view.perform(NSSelectorFromString("handleScroll:"), with: pan)
      try #require(
        view.momentum.isActive && view.horizontalMomentum.isActive
          && view.momentumLink != nil
      )
      let rect = view.geometry.rect(column: 1, row: 1)
      pan.point = CGPoint(x: rect.midX, y: rect.midY)
      let tap = MomentumTapGesture()
      tap.point = pan.point
      switch interaction {
      case "tap":
        _ = view.perform(NSSelectorFromString("handleTap:"), with: tap)
      case "secondary":
        _ = view.perform(
          NSSelectorFromString("handleSecondaryClick:"),
          with: tap
        )
      default:
        pan.state = .began
        _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
      }
      #expect(
        !view.momentum.isActive && !view.horizontalMomentum.isActive
          && view.momentumLink == nil
      )
      try await Task.sleep(for: .milliseconds(150))
      if interaction == "drag" {
        pan.state = .ended
        _ = view.perform(NSSelectorFromString("handlePointerDrag:"), with: pan)
      }
      _ = session.snapshot()
      let button = interaction == "secondary" ? 2 : 0
      let expected = ["\u{1B}[<\(button);2;2M", "\u{1B}[<\(button);2;2m"]
      #expect(
        TestFixture(
          writes.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
        ) == TestFixture(expected)
      )
    }
  }
}

@MainActor
private final class MomentumTapGesture: UITapGestureRecognizer {
  var point = CGPoint.zero

  override func location(in view: UIView?) -> CGPoint { point }
}

private final class ReviewMomentumDisplayLink: CADisplayLink {
  var displayTimestamp: CFTimeInterval = 0
  var nextTimestamp: CFTimeInterval = 0

  override var timestamp: CFTimeInterval { displayTimestamp }

  override var targetTimestamp: CFTimeInterval { nextTimestamp }
}

@MainActor
final class ReviewScrollGesture: UIPanGestureRecognizer {
  private var simulatedState: UIGestureRecognizer.State = .possible
  var distance = CGPoint.zero
  var point = CGPoint.zero
  var speed = CGPoint.zero
  var flags: UIKeyModifierFlags = []
  override var modifierFlags: UIKeyModifierFlags { flags }

  override var state: UIGestureRecognizer.State {
    get { simulatedState }
    set { simulatedState = newValue }
  }

  override func translation(in view: UIView?) -> CGPoint { distance }

  override func setTranslation(_ translation: CGPoint, in view: UIView?) {
    distance = translation
  }

  override func location(in view: UIView?) -> CGPoint { point }

  override func velocity(in view: UIView?) -> CGPoint { speed }
}
#endif
