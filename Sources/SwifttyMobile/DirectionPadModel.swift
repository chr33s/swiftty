import CoreGraphics
import Foundation
import SwifttyCore

// UIKit-independent geometry and state for the accessory's directional
// pad, its row layout and the virtual key repeat owner
// (spec.keyboard.md §2, §4 and §5).

// MARK: - Directions and intents

enum PadDirection: CaseIterable, Equatable, Sendable {
  case left, down, up, right

  var key: Key {
    switch self {
    case .left: .left
    case .down: .down
    case .up: .up
    case .right: .right
    }
  }

  /// Angle of the direction's axis in radians, y pointing down.
  var angle: Double {
    switch self {
    case .right: 0
    case .down: .pi / 2
    case .left: .pi
    case .up: -.pi / 2
    }
  }

  var isHorizontal: Bool { self == .left || self == .right }

  /// The nearest cardinal direction to a nonzero offset; exact diagonals
  /// resolve horizontally.
  static func nearest(dx: Double, dy: Double) -> PadDirection {
    if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
    return dy < 0 ? .up : .down
  }
}

/// What the pad asks of its terminal input owner.
enum PadIntent: Equatable, Sendable {
  /// Press `direction`, releasing any key the pad already holds.
  case activate(PadDirection)
  /// Release the held key; the touch continues.
  case pause
  /// The touch lifted.
  case end
  /// UIKit or the accessory cancelled the gesture.
  case cancel
}

// MARK: - Geometry

/// Distances in the pad's fixed, untransformed coordinate system. Product
/// defaults pending device validation; they scale with the resting key.
struct DirectionPadGeometry: Equatable, Sendable {
  static let restingKey: Double = 44
  static let activeArtwork: Double = 56
  /// Visual scale of the active artwork (56/44).
  static let activeScale = activeArtwork / restingKey

  var keySize: Double = Self.restingKey

  private var scale: Double { keySize / Self.restingKey }
  var minimumMovement: Double { 6 * scale }
  var activationRadius: Double { 12 * scale }
  var neutralRadius: Double { 9 * scale }
  /// Half the side of the captured-drag retention square (64 pt).
  var retentionHalfExtent: Double { 32 * scale }
  /// Half the side of the reentry square (60 pt).
  var reentryHalfExtent: Double { 30 * scale }
  /// Degrees beyond a sector boundary before the direction changes.
  var angularHysteresis: Double { 8 }
}

// MARK: - Gesture reducer

/// One initiating touch's state; points are offsets from the pad's fixed
/// centre.
struct DirectionPadModel: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case idle
    /// Touched down; no direction yet admitted.
    case armed
    case active(PadDirection)
    /// Back at the centre after a direction.
    case neutral
    /// Beyond the retention envelope; waits for reentry.
    case outside
    /// Preempted by another input source until the touch ends.
    case suppressed
  }

  var geometry = DirectionPadGeometry()
  private(set) var phase = Phase.idle
  private var origin = CGPoint.zero

  init(geometry: DirectionPadGeometry = DirectionPadGeometry()) {
    self.geometry = geometry
  }

  var isTracking: Bool { phase != .idle }

  /// The artwork is enlarged only while a direction is held.
  var isExpanded: Bool { activeDirection != nil }

  var activeDirection: PadDirection? {
    if case let .active(direction) = phase { return direction }
    return nil
  }

  /// A neutral pressed tint while the touch is captured, without scaling.
  var isPressed: Bool {
    switch phase {
    case .armed, .active, .neutral, .outside: true
    case .idle, .suppressed: false
    }
  }

  /// Captures a touch that began inside the resting hit region.
  mutating func begin(at point: CGPoint) {
    origin = point
    phase = .armed
  }

  mutating func move(to point: CGPoint) -> PadIntent? {
    let dx = Double(point.x)
    let dy = Double(point.y)
    let radius = (dx * dx + dy * dy).squareRoot()
    let leftRetention =
      abs(dx) > geometry.retentionHalfExtent
      || abs(dy) > geometry.retentionHalfExtent
    switch phase {
    case .idle, .suppressed: return nil
    case .armed:
      if leftRetention {
        phase = .outside
        return nil
      }
      let moved = hypot(dx - Double(origin.x), dy - Double(origin.y))
      guard moved >= geometry.minimumMovement,
        radius >= geometry.activationRadius
      else { return nil }
      return activate(.nearest(dx: dx, dy: dy))
    case .neutral:
      if leftRetention {
        phase = .outside
        return nil
      }
      guard radius >= geometry.activationRadius else { return nil }
      return activate(.nearest(dx: dx, dy: dy))
    case let .active(direction):
      if leftRetention || radius <= geometry.neutralRadius {
        phase = leftRetention ? .outside : .neutral
        return .pause
      }
      // Between the neutral and activation radii the direction holds.
      guard radius >= geometry.activationRadius else { return nil }
      let next = sector(dx: dx, dy: dy, current: direction)
      return next == direction ? nil : activate(next)
    case .outside:
      guard
        abs(dx) <= geometry.reentryHalfExtent
          && abs(dy) <= geometry.reentryHalfExtent
      else { return nil }
      guard radius >= geometry.activationRadius else {
        phase = .neutral
        return nil
      }
      return activate(.nearest(dx: dx, dy: dy))
    }
  }

  /// The touch lifted.
  mutating func end() -> PadIntent? {
    let wasActive = isExpanded
    phase = .idle
    return wasActive ? .end : nil
  }

  /// UIKit cancellation, removal or another hard cancellation: Idle at
  /// once, without waiting for an end event.
  mutating func cancel() -> PadIntent? {
    let wasActive = isExpanded
    phase = .idle
    return wasActive ? .cancel : nil
  }

  /// Another input source took over; the touch is ignored until it ends.
  mutating func suppress() { if phase != .idle { phase = .suppressed } }

  /// Forgets the touch without reporting anything (the owner already
  /// stopped its key).
  mutating func reset() { phase = .idle }

  private mutating func activate(_ direction: PadDirection) -> PadIntent {
    phase = .active(direction)
    return .activate(direction)
  }

  /// Keeps `current` until the touch passes its sector boundary (45°) by
  /// more than the hysteresis margin; a distant sector wins at once.
  private func sector(
    dx: Double,
    dy: Double,
    current: PadDirection
  ) -> PadDirection {
    var delta = atan2(dy, dx) - current.angle
    while delta > .pi { delta -= 2 * .pi }
    while delta < -.pi { delta += 2 * .pi }
    let limit = (45 + geometry.angularHysteresis) * .pi / 180
    return abs(delta) <= limit ? current : .nearest(dx: dx, dy: dy)
  }
}

// MARK: - Accessory row layout

/// Controls on the accessory bar.
enum AccessoryItem: Hashable, Sendable {
  case key(AccessoryKey)
  case paste
  /// The Keys panel: Navigate, Symbols, F1–F12, Paste when collapsed,
  /// Hide Keyboard.
  case keys
  case symbols
  case function
  case pad
}

/// Frames for the accessory's controls at a given width. Every control
/// keeps a genuine square hit region; rows reflow rather than compress.
struct AccessoryRowLayout: Equatable, Sendable {
  static let gap: CGFloat = 4
  static let padGap: CGFloat = 8
  static let inset: CGFloat = 8

  static let core: [AccessoryItem] = [
    .key(.escape), .key(.tab), .key(.control), .key(.alt),
  ]
  /// Promoted on wide iPad layouts, collapsing from the end.
  static let promoted: [AccessoryItem] = [
    .key(.symbol("/")), .key(.symbol("|")), .key(.symbol("~")), .symbols,
    .function,
  ]

  var keySize: CGFloat
  var rows: [[AccessoryItem]]
  var frames: [AccessoryItem: CGRect]
  /// Total height, reserving the active pad's paint area.
  var height: CGFloat

  var showsPaste: Bool { frames[.paste] != nil }
  var items: [AccessoryItem] { rows.flatMap(\.self) }

  /// Vertical room the active pad artwork extends beyond its slot.
  static func expansion(keySize: CGFloat) -> CGFloat {
    (keySize * CGFloat(DirectionPadGeometry.activeScale) - keySize) / 2
  }

  static func padGap(keySize: CGFloat) -> CGFloat {
    max(padGap, expansion(keySize: keySize) + gap / 2)
  }

  /// Width of one row of `count` controls ending with the pad.
  static func requiredWidth(count: Int, keySize: CGFloat = 44) -> CGFloat {
    guard count > 0 else { return 2 * inset }
    return CGFloat(count) * keySize + CGFloat(max(0, count - 2)) * gap
      + (count > 1 ? padGap(keySize: keySize) : 0) + 2 * inset
  }

  /// - Parameters:
  ///   - width: Width available inside the safe area.
  ///   - keySize: Shared key height and compact width.
  ///   - promotesKeys: Whether wide layouts promote iPad keys.
  init(width: CGFloat, keySize: CGFloat = 44, promotesKeys: Bool = false) {
    self.keySize = keySize
    let trailing: [AccessoryItem] = [.paste, .keys, .pad]
    var candidates: [[AccessoryItem]] = []
    if promotesKeys {
      for count in stride(from: Self.promoted.count, to: 0, by: -1) {
        candidates.append(Self.core + Self.promoted.prefix(count) + trailing)
      }
    }
    candidates.append(Self.core + trailing)
    candidates.append(Self.core + [.keys, .pad])
    if let row = candidates.first(where: {
      Self.requiredWidth(count: $0.count, keySize: keySize) <= width
    }) {
      rows = [row]
    } else {
      rows = Self.wrap(Self.core + [.keys, .pad], width: width, size: keySize)
    }
    let margin = Self.expansion(keySize: keySize)
    let rowGap = max(Self.gap, margin + Self.gap / 2)
    height =
      (CGFloat(rows.count) * keySize + CGFloat(rows.count - 1) * rowGap + 2
      * margin)
      .rounded(.up)
    frames = [:]
    for (index, row) in rows.enumerated() {
      let y = margin + CGFloat(index) * (keySize + rowGap)
      frames.merge(
        Self.frames(row, width: width, y: y, size: keySize),
        uniquingKeysWith: { $1 }
      )
    }
  }

  /// Leading controls flow from the leading inset; Paste, Keys and the pad
  /// align to the trailing inset.
  private static func frames(
    _ row: [AccessoryItem],
    width: CGFloat,
    y: CGFloat,
    size: CGFloat
  ) -> [AccessoryItem: CGRect] {
    var frames: [AccessoryItem: CGRect] = [:]
    let trailingItems: Set<AccessoryItem> = [.paste, .keys, .pad]
    var x = inset
    for item in row where !trailingItems.contains(item) {
      frames[item] = CGRect(x: x, y: y, width: size, height: size)
      x += size + gap
    }
    var right = width - inset
    for item in row.reversed() where trailingItems.contains(item) {
      right -= size
      frames[item] = CGRect(x: right, y: y, width: size, height: size)
      right -= item == .pad ? padGap(keySize: size) : gap
    }
    return frames
  }

  /// Greedy rows for widths below the compact single row; the pad keeps
  /// its wider leading gap in whichever row it lands.
  private static func wrap(
    _ items: [AccessoryItem],
    width: CGFloat,
    size: CGFloat
  ) -> [[AccessoryItem]] {
    var rows: [[AccessoryItem]] = [[]]
    var used = 2 * inset
    for item in items {
      let spacing =
        rows[rows.count - 1].isEmpty
        ? 0 : item == .pad ? padGap(keySize: size) : gap
      if !rows[rows.count - 1].isEmpty, used + spacing + size > width {
        rows.append([item])
        used = 2 * inset + size
      } else {
        rows[rows.count - 1].append(item)
        used += spacing + size
      }
    }
    return rows
  }
}

// MARK: - Virtual key repeat

@MainActor
protocol KeyRepeatCancellable: AnyObject { func cancel() }

/// Schedules repeat callbacks; tests inject a manual clock.
@MainActor
protocol KeyRepeatScheduling: AnyObject {
  func schedule(
    after delay: Duration,
    _ action: @escaping @MainActor () -> Void
  ) -> any KeyRepeatCancellable
}

/// An owned main-actor task on the monotonic clock. Its callbacks run
/// while touches are tracked, unlike default-mode timers.
@MainActor
final class TaskKeyRepeatScheduler: KeyRepeatScheduling {
  private final class Pending: KeyRepeatCancellable {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
  }

  func schedule(
    after delay: Duration,
    _ action: @escaping @MainActor () -> Void
  ) -> any KeyRepeatCancellable {
    let pending = Pending()
    pending.task = Task { @MainActor in
      try? await Task.sleep(for: delay, clock: .continuous)
      guard !Task.isCancelled else { return }
      action()
    }
    return pending
  }
}

/// The one virtual key held for a terminal input context: a press, its
/// repeats and its release all carry the modifiers captured at the press.
/// Separate from hardware held-key records.
@MainActor
final class VirtualKeyOwner {
  enum Source: Equatable, Sendable { case pad, discrete }

  struct Held: Equatable, Sendable {
    var press: KeyEvent
    var source: Source
    var generation: UInt64
  }

  static let initialDelay = Duration.milliseconds(350)
  static let repeatInterval = Duration.seconds(1) / 12

  private(set) var held: Held?
  private var generation: UInt64 = 0
  private var pending: (any KeyRepeatCancellable)?
  var scheduler: any KeyRepeatScheduling
  /// Delivers to the original destination.
  var send: (KeyEvent) -> Void = { _ in }
  /// Whether the original destination still admits input; checked before
  /// every repeat and release.
  var isAuthorized: () -> Bool = { true }

  init(scheduler: any KeyRepeatScheduling = TaskKeyRepeatScheduler()) {
    self.scheduler = scheduler
  }

  /// Releases any held key, then presses `event`. Returns the new run's
  /// generation, or nil when the press callback ended it reentrantly.
  @discardableResult
  func press(_ event: KeyEvent, source: Source, repeats: Bool) -> UInt64? {
    stop()
    generation &+= 1
    let current = generation
    var press = event
    press.action = .press
    held = Held(press: press, source: source, generation: current)
    send(press)
    // The delivery may cancel the run; that must not be undone here.
    guard held?.generation == current else { return nil }
    if repeats { schedule(current, after: Self.initialDelay) }
    return current
  }

  /// Releases the run `generation` if it is still current; stale
  /// releases leave a newer owner alone.
  @discardableResult
  func release(_ generation: UInt64) -> Bool {
    guard held?.generation == generation else { return false }
    stop()
    return true
  }

  /// Stops the current run, releasing its key through the original
  /// destination while that destination is still authorized.
  func stop() {
    pending?.cancel()
    pending = nil
    guard let held else { return }
    self.held = nil
    generation &+= 1
    guard isAuthorized() else { return }
    var release = held.press
    release.action = .release
    send(release)
  }

  /// Discards the run without sending anything.
  func discard() {
    pending?.cancel()
    pending = nil
    held = nil
    generation &+= 1
  }

  private func schedule(_ run: UInt64, after delay: Duration) {
    pending = scheduler.schedule(after: delay) { [weak self] in self?.fire(run)
    }
  }

  /// A late callback sends one repeat and schedules the next from now,
  /// never replaying missed repeats.
  private func fire(_ run: UInt64) {
    guard let held, held.generation == run else { return }
    pending = nil
    guard isAuthorized() else {
      discard()
      return
    }
    var event = held.press
    event.action = .repeat
    send(event)
    guard self.held?.generation == run else { return }
    schedule(run, after: Self.repeatInterval)
  }
}
