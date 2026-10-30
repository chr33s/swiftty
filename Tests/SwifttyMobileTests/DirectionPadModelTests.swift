import CoreGraphics
import SwifttyCore
@testable import SwifttyMobile
import Testing

/// A manual clock for repeat scheduling.
@MainActor
final class ManualRepeatScheduler: KeyRepeatScheduling {
  final class Item: KeyRepeatCancellable {
    let deadline: Duration
    let action: @MainActor () -> Void
    var isCancelled = false
    init(deadline: Duration, action: @escaping @MainActor () -> Void) {
      self.deadline = deadline
      self.action = action
    }
    func cancel() { isCancelled = true }
  }

  private(set) var now = Duration.zero
  private(set) var items: [Item] = []

  var pending: [Item] { items.filter { !$0.isCancelled } }

  func schedule(
    after delay: Duration,
    _ action: @escaping @MainActor () -> Void
  ) -> any KeyRepeatCancellable {
    let item = Item(deadline: now + delay, action: action)
    items.append(item)
    return item
  }

  /// Runs every callback due within `duration`, each at its deadline.
  func advance(by duration: Duration) {
    let end = now + duration
    while let next = pending.filter({ $0.deadline <= end })
      .min(by: { $0.deadline < $1.deadline })
    {
      items.removeAll { $0 === next }
      now = next.deadline
      next.action()
    }
    now = end
  }

  /// A late scheduler: callbacks due within `duration` run once, at its
  /// end.
  func advanceLate(by duration: Duration) {
    now += duration
    let due = pending.filter { $0.deadline <= now }
    items.removeAll { item in due.contains { $0 === item } }
    for item in due { item.action() }
  }
}

struct DirectionPadModelTests {
  private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
  }

  /// A point at `radius` and `degrees` (y down) from the centre.
  private func polar(_ radius: Double, _ degrees: Double) -> CGPoint {
    let angle = degrees * .pi / 180
    return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
  }

  @Test
  func `touch down and a stationary hold send nothing and do not expand`() {
    var model = DirectionPadModel()
    model.begin(at: point(2, 1))
    #expect(model.phase == .armed && model.isPressed && !model.isExpanded)
    for p in [point(2, 1), point(3, 2), point(5, 4)] {
      #expect(model.move(to: p) == nil)
    }
    #expect(!model.isExpanded)
    #expect(model.end() == nil)
    #expect(model.phase == .idle && !model.isPressed)
  }

  @Test
  func `activation needs both the movement and the radius threshold`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    // Moved 8 pt, but only 8 pt from the centre.
    #expect(model.move(to: point(8, 0)) == nil)
    model = DirectionPadModel()
    model.begin(at: point(10, 0))
    // 13 pt from the centre, but moved only 3 pt.
    #expect(model.move(to: point(13, 0)) == nil)
    #expect(model.move(to: point(16, 0)) == .activate(.right))
    #expect(model.isExpanded)
    // Further movement in the sector adds nothing.
    for p in [point(17, 1), point(20, -3), point(20, -3)] {
      #expect(model.move(to: p) == nil)
    }
    #expect(model.activeDirection == .right)
  }

  @Test(arguments: [
    (CGPoint(x: 10, y: 10), PadDirection.right),
    (CGPoint(x: -10, y: -10), .left), (CGPoint(x: 0, y: -14), .up),
    (CGPoint(x: 1, y: 14), .down),
  ])
  func `the nearest cardinal wins and exact diagonals are horizontal`(
    _ target: CGPoint,
    _ expected: PadDirection
  ) {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: target) == .activate(expected))
  }

  @Test
  func `angular jitter inside the hysteresis margin keeps the sector`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: polar(20, 0)) == .activate(.right))
    for degrees in [30.0, 46, 50, 52.9, -52.9, -46] {
      #expect(model.move(to: polar(20, degrees)) == nil, "\(degrees)°")
    }
    #expect(model.move(to: polar(20, 53.5)) == .activate(.down))
    // Back across the boundary still needs the margin.
    #expect(model.move(to: polar(20, 40)) == nil)
    #expect(model.move(to: polar(20, 36.5)) == .activate(.right))
  }

  @Test
  func `a jump to a distant sector selects it immediately`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: point(20, 0)) == .activate(.right))
    #expect(model.move(to: point(-20, 0)) == .activate(.left))
    #expect(model.move(to: point(0, -20)) == .activate(.up))
  }

  @Test
  func `the centre pauses and the neutral band holds its classification`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: point(20, 0)) == .activate(.right))
    // 9–12 pt preserves the active direction.
    #expect(model.move(to: point(10, 0)) == nil)
    #expect(model.activeDirection == .right)
    #expect(model.move(to: point(9, 0)) == .pause)
    #expect(model.phase == .neutral && !model.isExpanded && model.isPressed)
    // Neutral does not reactivate below the activation radius.
    #expect(model.move(to: point(11.9, 0)) == nil)
    #expect(model.move(to: point(0, 12)) == .activate(.down))
  }

  @Test
  func `leaving the retention envelope pauses until the reentry envelope`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: point(20, 0)) == .activate(.right))
    #expect(model.move(to: point(32, 0)) == nil)
    #expect(model.move(to: point(32.5, 0)) == .pause)
    #expect(model.phase == .outside && !model.isExpanded)
    // Between the envelopes nothing resumes, whatever the artwork's size.
    #expect(model.move(to: point(31, 31)) == nil)
    #expect(model.move(to: point(30.5, 0)) == nil)
    #expect(model.move(to: point(30, 0)) == .activate(.right))
    // Reentry near the centre waits in neutral.
    #expect(model.move(to: point(0, 40)) == .pause)
    #expect(model.move(to: point(0, 5)) == nil)
    #expect(model.phase == .neutral)
  }

  @Test
  func `armed touches drifting outside need reentry before activating`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    #expect(model.move(to: point(40, 0)) == nil)
    #expect(model.phase == .outside)
    #expect(model.move(to: point(20, 0)) == .activate(.right))
  }

  @Test
  func `lift and cancellation report a held direction once`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    _ = model.move(to: point(20, 0))
    #expect(model.end() == .end)
    #expect(model.end() == nil)
    model.begin(at: .zero)
    _ = model.move(to: point(0, 20))
    #expect(model.cancel() == .cancel)
    #expect(model.cancel() == nil)
    #expect(model.phase == .idle)
    model.begin(at: .zero)
    #expect(model.cancel() == nil)
  }

  @Test
  func `a suppressed touch is ignored until it ends`() {
    var model = DirectionPadModel()
    model.begin(at: .zero)
    _ = model.move(to: point(20, 0))
    model.suppress()
    #expect(!model.isExpanded && !model.isPressed)
    #expect(model.move(to: point(-20, 0)) == nil)
    #expect(model.move(to: point(0, 0)) == nil)
    #expect(model.move(to: point(0, 20)) == nil)
    #expect(model.end() == nil)
    model.begin(at: .zero)
    #expect(model.move(to: point(0, 20)) == .activate(.down))
  }

  @Test
  func `distance thresholds scale with the resting key`() {
    var model = DirectionPadModel(geometry: DirectionPadGeometry(keySize: 66))
    #expect(model.geometry.activationRadius == 18)
    #expect(model.geometry.retentionHalfExtent == 48)
    model.begin(at: .zero)
    #expect(model.move(to: point(17, 0)) == nil)
    #expect(model.move(to: point(18, 0)) == .activate(.right))
    #expect(model.move(to: point(13.5, 0)) == .pause)
  }

  @Test
  func `active artwork is 56 points`() {
    #expect(
      abs(DirectionPadGeometry.activeScale * 44 - 56) < 1e-9
        && abs(DirectionPadGeometry.activeScale - 1.273) < 0.001
    )
  }
}

struct AccessoryRowLayoutTests {
  @Test
  func `row widths match the specification`() {
    #expect(AccessoryRowLayout.requiredWidth(count: 7) == 352)
    #expect(AccessoryRowLayout.requiredWidth(count: 6) == 304)
  }

  private func check(_ layout: AccessoryRowLayout, width: CGFloat) {
    let frames = Array(layout.frames.values)
    for frame in frames {
      #expect(frame.width == layout.keySize && frame.height == layout.keySize)
      #expect(frame.minX >= AccessoryRowLayout.inset - 0.001)
      #expect(frame.maxX <= width - AccessoryRowLayout.inset + 0.001)
    }
    for (i, a) in frames.enumerated() {
      for b in frames[(i + 1)...] { #expect(!a.intersects(b)) }
    }
    // The pad's row reserves its expansion on every side.
    guard let pad = layout.frames[.pad] else {
      Issue.record("no pad")
      return
    }
    let expansion = AccessoryRowLayout.expansion(keySize: layout.keySize)
    #expect(pad.minY - expansion >= -0.001)
    #expect(pad.maxY + expansion <= layout.height + 0.001)
    for (item, frame) in layout.frames where item != .pad {
      #expect(!frame.intersects(pad.insetBy(dx: -expansion, dy: -expansion)))
    }
  }

  @Test(arguments: [352.0, 393, 440])
  func `the full phone row fits from 352 points`(_ width: Double) throws {
    let layout = AccessoryRowLayout(width: width)
    #expect(
      layout.items == [
        .key(.escape), .key(.tab), .key(.control), .key(.alt), .paste, .keys,
        .pad,
      ]
    )
    #expect(layout.height == 56)
    check(layout, width: width)
    let pad = try #require(layout.frames[.pad])
    let keys = try #require(layout.frames[.keys])
    #expect(pad.minX - keys.maxX == 8)
    #expect(Double(pad.maxX) == width - 8)
  }

  @Test(arguments: [304.0, 320, 351])
  func `paste moves into keys below 352 points`(_ width: Double) {
    let layout = AccessoryRowLayout(width: width)
    #expect(!layout.showsPaste)
    #expect(layout.rows.count == 1 && layout.items.count == 6)
    check(layout, width: width)
  }

  @Test
  func `narrower widths reflow rather than compress`() {
    let layout = AccessoryRowLayout(width: 250)
    #expect(layout.rows.count == 2)
    #expect(layout.height > 56)
    check(layout, width: 250)
  }

  @Test
  func `wide ipad layouts promote keys and converge on the phone row`() {
    let wide = AccessoryRowLayout(width: 1000, promotesKeys: true)
    #expect(wide.items.count == 12)
    #expect(wide.frames[.function] != nil && wide.frames[.symbols] != nil)
    check(wide, width: 1000)
    let medium = AccessoryRowLayout(
      width: AccessoryRowLayout.requiredWidth(count: 9),
      promotesKeys: true
    )
    #expect(medium.frames[.key(.symbol("|"))] != nil)
    #expect(medium.frames[.key(.symbol("~"))] == nil)
    let narrow = AccessoryRowLayout(width: 360, promotesKeys: true)
    #expect(narrow.items == AccessoryRowLayout(width: 360).items)
  }

  @Test
  func `larger text grows keys and the reserved paint height`() {
    let layout = AccessoryRowLayout(width: 1000, keySize: 66)
    #expect(layout.frames.values.allSatisfy { $0.size.width == 66 })
    #expect(layout.height == (66 * 56 / 44).rounded(.up))
    check(layout, width: 1000)
    let reflowed = AccessoryRowLayout(width: 393, keySize: 66)
    #expect(reflowed.rows.count == 2)
    check(reflowed, width: 393)
  }
}

@MainActor
struct VirtualKeyOwnerTests {
  private func makeOwner() -> (
    VirtualKeyOwner, ManualRepeatScheduler, () -> [KeyEvent]
  ) {
    let scheduler = ManualRepeatScheduler()
    let owner = VirtualKeyOwner(scheduler: scheduler)
    var sent: [KeyEvent] = []
    owner.send = { sent.append($0) }
    return (owner, scheduler, { sent })
  }

  @Test
  func `repeats start after 350 ms at 12 per second`() throws {
    let (owner, scheduler, sent) = makeOwner()
    let left = KeyEvent(.left, modifiers: .control)
    try #require(owner.press(left, source: .pad, repeats: true) != nil)
    #expect(sent() == [left])
    scheduler.advance(by: .milliseconds(349))
    #expect(sent().count == 1)
    scheduler.advance(by: .milliseconds(1))
    var repeated = left
    repeated.action = .repeat
    #expect(sent() == [left, repeated])
    scheduler.advance(by: .seconds(1))
    #expect(sent().count == 14)
    #expect(sent().dropFirst().allSatisfy { $0 == repeated })
  }

  @Test
  func `a late callback sends at most one repeat`() throws {
    let (owner, scheduler, sent) = makeOwner()
    try #require(owner.press(KeyEvent(.up), source: .pad, repeats: true) != nil)
    scheduler.advanceLate(by: .seconds(3))
    #expect(sent().count == 2)
    #expect(scheduler.pending.count == 1)
  }

  @Test
  func `releases carry the captured chord and stop repeating`() throws {
    let (owner, scheduler, sent) = makeOwner()
    let press = KeyEvent(.right, modifiers: [.control, .alt])
    let run = try #require(owner.press(press, source: .pad, repeats: true))
    scheduler.advance(by: .milliseconds(400))
    #expect(owner.release(run))
    var release = press
    release.action = .release
    #expect(sent().last == release)
    #expect(scheduler.pending.isEmpty)
    let count = sent().count
    scheduler.advance(by: .seconds(1))
    #expect(sent().count == count)
    #expect(!owner.release(run))
  }

  @Test
  func `a new press releases the old key first and restarts the delay`() throws
  {
    let (owner, scheduler, sent) = makeOwner()
    let old = try #require(
      owner.press(KeyEvent(.right), source: .pad, repeats: true)
    )
    scheduler.advance(by: .milliseconds(500))
    let new = try #require(
      owner.press(KeyEvent(.down), source: .pad, repeats: true)
    )
    let tail = sent().suffix(2).map(\.action)
    #expect(tail == [.release, .press])
    #expect(sent().suffix(2).map(\.key) == [.right, .down])
    // A stale release from the earlier run leaves the newer owner alone.
    #expect(!owner.release(old))
    #expect(owner.held?.generation == new)
    let count = sent().count
    scheduler.advance(by: .milliseconds(349))
    #expect(sent().count == count)
    scheduler.advance(by: .milliseconds(1))
    #expect(sent().count == count + 1 && sent().last?.key == .down)
  }

  @Test
  func `cancellation inside the press callback prevents later repeats`() {
    let scheduler = ManualRepeatScheduler()
    let owner = VirtualKeyOwner(scheduler: scheduler)
    var sent: [KeyEvent] = []
    owner.send = { event in
      sent.append(event)
      if event.action == .press { owner.stop() }
    }
    #expect(owner.press(KeyEvent(.up), source: .pad, repeats: true) == nil)
    #expect(scheduler.pending.isEmpty && owner.held == nil)
    scheduler.advance(by: .seconds(2))
    #expect(sent.map(\.action) == [.press, .release])
  }

  @Test
  func `ended authority discards the run without sending`() throws {
    let (owner, scheduler, sent) = makeOwner()
    var authorized = true
    owner.isAuthorized = { authorized }
    try #require(
      owner.press(KeyEvent(.left), source: .pad, repeats: true) != nil
    )
    authorized = false
    scheduler.advance(by: .seconds(1))
    #expect(sent().count == 1 && owner.held == nil)
    authorized = true
    owner.stop()
    #expect(sent().count == 1)
  }
}
