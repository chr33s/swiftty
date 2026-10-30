import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

/// A touch at a fixed point in whichever view asks.
@MainActor
final class ReviewPadTouch: UITouch {
  var point = CGPoint.zero
  override func location(in view: UIView?) -> CGPoint { point }
}

/// Included by test-ios-simulator.sh, where UIKit has an application host.
extension ViewLifecycleTests {
  /// Drives the pad's UIControl tracking with offsets from its centre.
  @MainActor
  struct PadDriver {
    let pad: TerminalDirectionPad
    let touch = ReviewPadTouch()

    private func place(_ offset: CGPoint) {
      touch.point = CGPoint(
        x: pad.bounds.midX + offset.x,
        y: pad.bounds.midY + offset.y
      )
    }

    @discardableResult
    func begin(_ x: CGFloat = 0, _ y: CGFloat = 0) -> Bool {
      place(CGPoint(x: x, y: y))
      return pad.beginTracking(touch, with: nil)
    }

    @discardableResult
    func move(_ x: CGFloat, _ y: CGFloat) -> Bool {
      place(CGPoint(x: x, y: y))
      return pad.continueTracking(touch, with: nil)
    }

    func end() { pad.endTracking(touch, with: nil) }
  }

  private func makeBar(width: CGFloat = 393) -> (TerminalAccessoryBar, UIWindow)
  {
    let bar = TerminalAccessoryBar()
    // The keyboard host sizes the bar; here its frame does.
    bar.translatesAutoresizingMaskIntoConstraints = true
    let window = makeWindow()
    window.addSubview(bar)
    bar.frame = CGRect(x: 0, y: 0, width: width, height: 56)
    bar.layoutIfNeeded()
    return (bar, window)
  }

  private func button(_ label: String, in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.accessibilityLabel == label {
      return button
    }
    return view.subviews.lazy.compactMap { self.button(label, in: $0) }.first
  }

  // MARK: Geometry and presentation

  @Test
  func `the pad rests at key size and only its artwork expands`() throws {
    let (bar, _) = makeBar()
    defer { bar.removeFromSuperview() }
    let pad = bar.directionPad
    let layout = try #require(bar.layout)
    #expect(layout.height == 56)
    #expect(pad.frame.size == CGSize(width: 44, height: 44))
    let visible = bar.subviews.compactMap { $0 as? UIButton }
      .filter { !$0.isHidden }
    #expect(visible.count == 6)
    for button in visible {
      #expect(button.frame.size == CGSize(width: 44, height: 44))
    }
    var intents: [PadIntent] = []
    pad.onIntent = {
      intents.append($0)
      return true
    }
    let frames = visible.map(\.frame)
    let padFrame = pad.frame
    let driver = PadDriver(pad: pad)
    #expect(driver.begin())
    #expect(pad.artworkScale == 1)
    driver.move(3, 1)
    #expect(pad.artworkScale == 1 && intents.isEmpty)
    driver.move(20, 0)
    #expect(intents == [.activate(.right)])
    #expect(abs(pad.artworkScale * 44 - 56) < 0.01)
    // Holding still keeps it enlarged.
    driver.move(20, 0)
    #expect(abs(pad.artworkScale * 44 - 56) < 0.01)
    #expect(pad.transform == .identity && pad.frame == padFrame)
    #expect(visible.map(\.frame) == frames)
    #expect(bar.layout?.height == 56)
    driver.end()
    #expect(intents == [.activate(.right), .end])
    #expect(pad.artworkScale == 1)
  }

  @Test
  func `expanded artwork cannot take a touch meant for a neighbour`() throws {
    let (bar, _) = makeBar()
    defer { bar.removeFromSuperview() }
    let pad = bar.directionPad
    pad.onIntent = { _ in true }
    let keys = try #require(button("More keys", in: bar))
    let driver = PadDriver(pad: pad)
    driver.begin()
    driver.move(-20, 0)
    try #require(pad.artworkScale > 1)
    // Inside the enlarged artwork, outside the resting hit region.
    let edge = CGPoint(x: pad.frame.minX - 4, y: pad.frame.midY)
    let hit = bar.hitTest(edge, with: nil)
    #expect(hit.map { !$0.isDescendant(of: pad) } ?? true)
    let neighbour = CGPoint(x: keys.frame.maxX - 2, y: keys.frame.midY)
    #expect(bar.hitTest(neighbour, with: nil)?.isDescendant(of: keys) == true)
    driver.end()
  }

  @Test(arguments: ["cancel", "detach", "geometry", "disable"])
  func `cancellation stops once and restores the resting pad at once`(
    _ operation: String
  ) throws {
    let (bar, _) = makeBar()
    defer { bar.removeFromSuperview() }
    let pad = bar.directionPad
    var intents: [PadIntent] = []
    pad.onIntent = {
      intents.append($0)
      return true
    }
    let driver = PadDriver(pad: pad)
    driver.begin()
    driver.move(0, 20)
    try #require(intents == [.activate(.down)])
    switch operation {
    case "cancel":
      pad.cancelTracking(with: nil)
      pad.cancelTracking(with: nil)
    case "detach": bar.removeFromSuperview()
    case "geometry":
      bar.frame.size.width = 320
      bar.layoutIfNeeded()
    default: pad.isEnabled = false
    }
    // Disabling suppresses the touch; the owner stops its own key.
    let expected: [PadIntent] =
      operation == "disable" ? [.activate(.down)] : [.activate(.down), .cancel]
    #expect(intents == expected)
    #expect(pad.artworkScale == 1 && !pad.model.isExpanded)
    // No end event is needed; later moves of the old touch do nothing.
    driver.move(0, -20)
    driver.move(20, 0)
    driver.end()
    #expect(intents == expected)
    pad.isEnabled = true
    if operation != "detach" {
      #expect(driver.begin())
      driver.move(20, 0)
      #expect(intents.last == .activate(.right))
      driver.end()
    }
  }

  @Test
  func `a refused activation suppresses the touch until it lifts`() {
    let (bar, _) = makeBar()
    defer { bar.removeFromSuperview() }
    let pad = bar.directionPad
    var intents: [PadIntent] = []
    pad.onIntent = {
      intents.append($0)
      return false
    }
    let driver = PadDriver(pad: pad)
    driver.begin()
    driver.move(20, 0)
    #expect(intents == [.activate(.right)])
    #expect(pad.model.phase == .suppressed && pad.artworkScale == 1)
    driver.move(0, 0)
    driver.move(0, 20)
    driver.end()
    #expect(intents == [.activate(.right)])
  }

  @Test
  func `accessibility exposes one control with discrete arrow actions`() throws
  {
    let (bar, _) = makeBar()
    defer { bar.removeFromSuperview() }
    let pad = bar.directionPad
    var discrete: [Key] = []
    bar.onDiscreteKey = { discrete.append($0) }
    pad.onIntent = { _ in
      Issue.record("accessibility must not drag")
      return false
    }
    #expect(pad.isAccessibilityElement)
    #expect(pad.accessibilityLabel == "Arrow keys")
    #expect(pad.accessibilityTraits.contains(.button))
    let actions = try #require(pad.accessibilityCustomActions)
    #expect(
      actions.map(\.name) == [
        "Move left", "Move down", "Move up", "Move right",
      ]
    )
    for action in actions { _ = action.actionHandler?(action) }
    #expect(discrete == [.left, .down, .up, .right])
    #expect(pad.artworkScale == 1)
    // The artwork is decorative, not a second element.
    #expect(pad.subviews.allSatisfy { !$0.isAccessibilityElement })
    pad.isEnabled = false
    #expect(pad.accessibilityTraits.contains(.notEnabled))
  }

  @Test
  func
    `the keys panel offers navigate symbols function keys and hide keyboard`()
  {
    let (bar, _) = makeBar(width: 320)
    defer { bar.removeFromSuperview() }
    #expect(bar.layout?.showsPaste == false)
    let titles = bar.keysMenu(includingPaste: true).children.map(\.title)
    #expect(
      titles == [
        "Navigate", "Symbols", "Function Keys", "Paste", "Hide Keyboard",
      ]
    )
    let navigate = bar.navigateMenuContent().children.map(\.title)
    #expect(navigate.prefix(4) == ["Left", "Down", "Up", "Right"])
  }

  // MARK: Terminal input

  @MainActor
  private final class Harness {
    let view: TerminalUIView
    let session: TerminalSession
    let window: UIWindow
    let scheduler: ManualRepeatScheduler
    let writes: Mutex<[[UInt8]]>
    var pad: TerminalDirectionPad { view.accessoryBar.directionPad }

    init(
      view: TerminalUIView,
      session: TerminalSession,
      window: UIWindow,
      scheduler: ManualRepeatScheduler,
      writes: consuming Mutex<[[UInt8]]>
    ) {
      self.view = view
      self.session = session
      self.window = window
      self.scheduler = scheduler
      self.writes = writes
    }

    func sent() -> [[UInt8]] {
      _ = session.snapshot()
      return writes.withLock { $0 }
    }

    func tearDown() {
      view.releaseHardwareKeys()
      view.removeFromSuperview()
      window.isHidden = true
    }
  }

  private func makeHarness(kitty: Bool = false) throws -> Harness {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
    controller.view.addSubview(view)
    window.makeKeyAndVisible()
    view.sceneDidActivate()
    try #require(view.becomeFirstResponder())
    let scheduler = ManualRepeatScheduler()
    view.virtualKeys.scheduler = scheduler
    if kitty { session.feed(Array("\u{1B}[=10u".utf8)) }
    _ = session.snapshot()
    let harness = Harness(
      view: view,
      session: session,
      window: window,
      scheduler: scheduler,
      writes: Mutex([])
    )
    session.onWrite = { [weak harness] bytes in
      harness?.writes.withLock { $0.append(bytes) }
    }
    return harness
  }

  private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

  @Test(.enabled(if: hasMetal))
  func `a slide presses once repeats on schedule and captures its chord`()
    throws
  {
    let h = try makeHarness()
    defer { h.tearDown() }
    h.view.sticky.tap(.control)
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(4, 0)
    #expect(h.sent().isEmpty && h.view.sticky.active == .control)
    driver.move(-20, 0)
    let ctrlLeft = bytes("\u{1B}[1;5D")
    #expect(h.sent() == [ctrlLeft])
    // The one-shot modifier is spent, but the run keeps its chord.
    #expect(h.view.sticky.active.isEmpty)
    driver.move(-22, 3)
    h.scheduler.advance(by: .milliseconds(349))
    #expect(h.sent().count == 1)
    h.scheduler.advance(by: .milliseconds(1))
    h.scheduler.advance(by: .seconds(1))
    #expect(h.sent().count == 14 && h.sent().allSatisfy { $0 == ctrlLeft })
    // A direction change is a new key without the spent modifier.
    driver.move(0, -20)
    #expect(h.sent().last == bytes("\u{1B}[A"))
    driver.end()
    h.scheduler.advance(by: .seconds(1))
    #expect(h.sent().count == 15)
  }

  @Test(.enabled(if: hasMetal))
  func `a locked modifier carries into each new direction`() throws {
    let h = try makeHarness()
    defer { h.tearDown() }
    h.view.sticky.tap(.control)
    h.view.sticky.tap(.control)
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(20, 0)
    driver.move(0, 20)
    driver.move(0, 5)  // neutral
    driver.move(-20, 0)
    driver.end()
    #expect(
      h.sent() == [
        bytes("\u{1B}[1;5C"), bytes("\u{1B}[1;5B"), bytes("\u{1B}[1;5D"),
      ]
    )
    #expect(h.view.sticky.state(of: .control) == .locked)
  }

  @Test(.enabled(if: hasMetal))
  func `releases precede the next press under kitty event reporting`() throws {
    let h = try makeHarness(kitty: true)
    defer { h.tearDown() }
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(20, 0)
    driver.move(-20, 0)
    driver.move(-5, 0)
    driver.end()
    let sent = h.sent()
    #expect(sent.count == 4)
    #expect(sent[1] == bytes("\u{1B}[1;1:3C"))
    #expect(sent[3] == bytes("\u{1B}[1;1:3D"))
  }

  @Test(.enabled(if: hasMetal))
  func `a physical key preempts the pad and refuses overlapping virtual keys`()
    throws
  {
    let h = try makeHarness(kitty: true)
    defer { h.tearDown() }
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(-20, 0)
    #expect(
      h.view.keyDown(
        usage: KeyTranslator.Usage.up,
        modifiers: [],
        base: "",
        characters: ""
      )
    )
    var sent = h.sent()
    #expect(sent.count == 3)
    #expect(sent[1] == bytes("\u{1B}[1;1:3D"))
    #expect(sent[2].last == UInt8(ascii: "A"))
    // The preempted touch cannot reacquire input by moving again.
    driver.move(0, 20)
    driver.move(20, 0)
    driver.end()
    #expect(h.sent().count == 3)
    // While the physical key is held, no virtual key path may press.
    h.view.sticky.tap(.alt)
    let second = PadDriver(pad: h.pad)
    second.begin()
    second.move(20, 0)
    second.end()
    h.view.discreteKey(.left)
    h.view.accessoryKey(.escape)
    if let action = h.pad.accessibilityCustomActions?.first {
      _ = action.actionHandler?(action)
    }
    sent = h.sent()
    #expect(sent.count == 3)
    #expect(h.view.sticky.active == .alt)
    // The hardware repeat and release record are untouched.
    #expect(h.view.keyRepeat != nil)
    #expect(h.view.heldKeys[KeyTranslator.Usage.up] != nil)
  }

  @Test(.enabled(if: hasMetal))
  func `composition disables the pad and cancels a run`() throws {
    let h = try makeHarness(kitty: true)
    defer { h.tearDown() }
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(20, 0)
    h.view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
    #expect(h.sent() == [bytes("\u{1B}[C"), bytes("\u{1B}[1;1:3C")])
    #expect(!h.pad.isEnabled && h.pad.artworkScale == 1)
    driver.move(0, 20)
    driver.end()
    h.view.sticky.tap(.control)
    #expect(!PadDriver(pad: h.pad).begin())
    h.view.discreteKey(.down)
    #expect(h.sent().count == 2)
    #expect(h.view.sticky.active == .control)
    #expect(h.view.markedText == "中")
    h.view.unmarkText()
    #expect(h.pad.isEnabled)
  }

  @Test(
    .enabled(if: hasMetal),
    arguments: ["focus", "background", "capability"]
  )
  func `lifecycle loss ends a run without later events`(
    _ transition: String
  ) throws {
    let h = try makeHarness(kitty: true)
    defer { h.tearDown() }
    let driver = PadDriver(pad: h.pad)
    driver.begin()
    driver.move(0, -20)
    try #require(h.sent().count == 1)
    switch transition {
    case "focus": _ = h.view.resignFirstResponder()
    case "background": h.view.sceneDidEnterBackground()
    default: h.view.capabilities.textInput = false
    }
    // No release once the destination's authority has ended.
    let expected = transition == "capability" ? 1 : 2
    #expect(h.sent().count == expected)
    #expect(h.pad.model.phase == .idle && h.pad.artworkScale == 1)
    driver.move(0, 20)
    driver.end()
    h.scheduler.advance(by: .seconds(2))
    #expect(h.sent().count == expected)
  }

  @Test(.enabled(if: hasMetal))
  func `discrete arrows press once without repeat or expansion`() throws {
    let h = try makeHarness()
    defer { h.tearDown() }
    h.view.sticky.tap(.alt)
    let actions = try #require(h.pad.accessibilityCustomActions)
    _ = actions[0].actionHandler?(actions[0])
    #expect(h.sent() == [bytes("\u{1B}[1;3D")])
    #expect(h.scheduler.pending.isEmpty && h.pad.artworkScale == 1)
    #expect(h.view.sticky.active.isEmpty)
    h.view.discreteKey(.function(1))
    #expect(h.sent().last == bytes("\u{1B}OP"))
  }
}
