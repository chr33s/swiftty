import CoreGraphics
import Foundation
import SwifttyCore

// UIKit-independent key translation, sticky modifiers, scrolling, and
// selection.

// MARK: - Hardware keys

/// Translates hardware key presses (USB HID usages, as `UIKey.keyCode`
/// reports them) into terminal key events.
public enum KeyTranslator {
  /// USB HID keyboard usages (`UIKeyboardHIDUsage` raw values).
  public enum Usage {
    public static let returnOrEnter = 0x28
    public static let escape = 0x29
    public static let backspace = 0x2A
    public static let tab = 0x2B
    public static let f1 = 0x3A  // ... F12 = 0x45
    public static let insert = 0x49
    public static let home = 0x4A
    public static let pageUp = 0x4B
    public static let deleteForward = 0x4C
    public static let end = 0x4D
    public static let pageDown = 0x4E
    public static let right = 0x4F
    public static let left = 0x50
    public static let down = 0x51
    public static let up = 0x52
    public static let keypadSlash = 0x54  // * - + follow
    public static let keypadEnter = 0x58
    public static let keypad1 = 0x59  // ... 9, 0, period follow
    public static let keypadEqual = 0x67
    public static let keypadComma = 0x85
    public static let leftControl = 0xE0  // ... right GUI = 0xE7
  }

  static let specialKeys: [Int: Key] = {
    var keys: [Int: Key] = [
      Usage.returnOrEnter: .enter, Usage.keypadEnter: .keypad(.enter),
      Usage.tab: .tab, Usage.backspace: .backspace, Usage.escape: .escape,
      Usage.left: .left, Usage.right: .right, Usage.down: .down, Usage.up: .up,
      Usage.home: .home, Usage.end: .end, Usage.pageUp: .pageUp,
      Usage.pageDown: .pageDown, Usage.deleteForward: .delete,
      Usage.insert: .insert,
    ]
    for n in 1 ... 12 { keys[Usage.f1 + n - 1] = .function(n) }
    let operators: [KeypadKey] = [.divide, .multiply, .subtract, .add]
    for (i, k) in operators.enumerated() {
      keys[Usage.keypadSlash + i] = .keypad(k)
    }
    let digits: [KeypadKey] = [
      .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero,
      .decimal,
    ]
    for (i, k) in digits.enumerated() { keys[Usage.keypad1 + i] = .keypad(k) }
    keys[Usage.keypadEqual] = .keypad(.equal)
    keys[Usage.keypadComma] = .keypad(.separator)
    return keys
  }()

  /// Whether `usage` is a modifier key on its own (Ctrl, Shift, Alt, Cmd).
  public static func isModifier(_ usage: Int) -> Bool {
    (Usage.leftControl ... Usage.leftControl + 7).contains(usage)
  }

  /// - Parameters:
  ///   - usage: USB HID key usage.
  ///   - modifiers: Held modifiers.
  ///   - charactersIgnoringModifiers: Layout's base characters.
  ///   - characters: Typed characters, including modifiers.
  ///   - action: Press, repeat, or release.
  ///   - keyboardFlags: Kitty enhancement flags.
  /// - Returns: An encoded key event, or nil for text-system input.
  public static func keyEvent(
    usage: Int,
    modifiers: KeyModifiers,
    charactersIgnoringModifiers: String,
    characters: String = "",
    action: KeyEvent.Action = .press,
    keyboardFlags: UInt8 = 0,
  ) -> KeyEvent? {
    // Unbound Command combinations can reach kitty applications.
    let kittyActive = InputEncoder.isKittyKeyboardActive(keyboardFlags)
    guard kittyActive || !modifiers.contains(.command) else { return nil }
    if let key = specialKeys[usage] {
      return KeyEvent(key, modifiers: modifiers, action: action)
    }
    guard
      modifiers.contains(.control)
        || (kittyActive && modifiers.contains(.command))
    else { return nil }
    return identity(
      usage: usage,
      modifiers: kittyActive ? modifiers : modifiers.subtracting(.shift),
      base: charactersIgnoringModifiers,
      characters: characters,
      action: action,
    )
  }

  /// The key identity of any press, for key bindings and for reporting
  /// its release (releases are only encoded under the kitty protocol's
  /// event-types flag); nil for modifier keys alone.
  public static func identity(
    usage: Int,
    modifiers: KeyModifiers,
    base: String,
    characters: String = "",
    action: KeyEvent.Action = .press,
  ) -> KeyEvent? {
    guard !isModifier(usage) else { return nil }
    if let key = specialKeys[usage] {
      return KeyEvent(key, modifiers: modifiers, action: action)
    }
    guard let scalar = base.unicodeScalars.first else { return nil }
    let key = lowercased(scalar)
    var shifted: Unicode.Scalar?
    if modifiers.contains(.shift) {
      if let typed = characters.unicodeScalars.first, typed.value >= 0x20,
        typed != key
      {
        shifted = typed
      } else if ("a" ... "z").contains(key) {
        shifted = Unicode.Scalar(key.value - 0x20)
      }
    }
    return KeyEvent(
      .character(key),
      modifiers: modifiers,
      action: action,
      text: characters.isEmpty ? nil : characters,
      shiftedKey: shifted,
      baseLayoutKey: usLayoutKey(usage: usage),
    )
  }

  public static func releaseEvent(
    usage: Int,
    modifiers: KeyModifiers,
    charactersIgnoringModifiers: String
  ) -> KeyEvent? {
    identity(
      usage: usage,
      modifiers: modifiers,
      base: charactersIgnoringModifiers,
      action: .release
    )
  }

  /// Input for committed text (software keyboard, hardware text keys,
  /// accessory symbols) with `modifiers` held, such as a sticky Ctrl.
  public static func inputs(
    forText text: String,
    modifiers: KeyModifiers
  ) -> [TerminalInput] {
    if modifiers.isEmpty {
      // The software keyboard's return key inserts a newline.
      switch text {
      case "\n", "\r": return [.key(KeyEvent(.enter))]
      case "\t": return [.key(KeyEvent(.tab))]
      case "": return []
      default: return [.text(text)]
      }
    }
    return text.unicodeScalars.map { scalar in
      switch scalar {
      case "\n", "\r": .key(KeyEvent(.enter, modifiers: modifiers))
      case "\t": .key(KeyEvent(.tab, modifiers: modifiers))
      // Ctrl-C and Ctrl-Shift-C mean the same to a terminal.
      case _ where modifiers.contains(.control):
        .key(KeyEvent(.character(lowercased(scalar)), modifiers: modifiers))
      default:
        .key(
          KeyEvent(
            .character(scalar),
            modifiers: modifiers,
            text: String(scalar)
          )
        )
      }
    }
  }

  private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    ("A" ... "Z").contains(scalar)
      ? Unicode.Scalar(scalar.value + 0x20)! : scalar
  }
}

/// Associates a text-system commit with the hardware press that produced it.
/// Composition invalidates the association before any text is committed.
struct HardwareTextInput {
  private var pending: (usage: Int, event: KeyEvent)?

  mutating func begin(usage: Int, event: KeyEvent) { pending = (usage, event) }

  mutating func cancel(usage: Int? = nil) {
    if usage == nil || pending?.usage == usage { pending = nil }
  }

  mutating func commit(
    _ text: String,
    keyboardFlags: UInt8
  ) -> (usage: Int, event: KeyEvent)? {
    guard var pending, !text.isEmpty, pending.event.text == text else {
      self.pending = nil
      return nil
    }
    let committed = pending
    // Every matching commit consumes the initial press, including text
    // sent before an application enables kitty keyboard reporting.
    pending.event.action = .repeat
    self.pending = pending
    guard InputEncoder.isKittyKeyboardActive(keyboardFlags) else { return nil }
    return committed
  }
}

// MARK: - Sticky modifiers

/// Ctrl and Alt toggles on the accessory bar: one tap applies the modifier
/// to the next key, a second tap locks it, a third releases it.
public struct StickyModifiers: Equatable, Sendable {
  public enum State: Equatable, Sendable { case off, latched, locked }

  public private(set) var control = State.off
  public private(set) var alt = State.off

  public init() {}

  public func state(of modifier: KeyModifiers) -> State {
    modifier == .control ? control : modifier == .alt ? alt : .off
  }

  public mutating func tap(_ modifier: KeyModifiers) {
    func next(_ s: State) -> State {
      switch s {
      case .off: .latched
      case .latched: .locked
      case .locked: .off
      }
    }
    if modifier == .control {
      control = next(control)
    } else if modifier == .alt {
      alt = next(alt)
    }
  }

  /// Modifiers currently applied to keys.
  public var active: KeyModifiers {
    var mods: KeyModifiers = []
    if control != .off { mods.insert(.control) }
    if alt != .off { mods.insert(.alt) }
    return mods
  }

  /// Returns the active modifiers for one key and releases latched ones.
  public mutating func consume() -> KeyModifiers {
    let mods = active
    if control == .latched { control = .off }
    if alt == .latched { alt = .off }
    return mods
  }

  public mutating func reset() { self = StickyModifiers() }
}

public enum AccessoryKey: Hashable, Sendable {
  case escape, control, alt, tab
  case left, down, up, right
  case symbol(String)

  public static let standard: [AccessoryKey] =
    [.escape, .control, .alt, .tab, .left, .down, .up, .right]
    + [
      "|", "~", "/", "-", "_", "\\", "`", "*", "&", "$", "<", ">", "{", "}",
      "[", "]",
    ]
    .map(AccessoryKey.symbol)

  public var title: String {
    switch self {
    case .escape: "esc"
    case .control: "ctrl"
    case .alt: "alt"
    case .tab: "tab"
    case .left: "←"
    case .down: "↓"
    case .up: "↑"
    case .right: "→"
    case let .symbol(s): s
    }
  }

  /// SF Symbol drawn instead of `title`, for keys with a standard glyph.
  public var symbolName: String? {
    switch self {
    case .escape: "escape"
    case .control: "control"
    case .alt: "option"
    case .tab: "arrow.right.to.line"
    default: nil
    }
  }

  public var accessibilityName: String {
    switch self {
    case .escape: "Escape"
    case .control: "Control"
    case .alt: "Alt"
    case .tab: "Tab"
    default: title
    }
  }

  /// The sticky modifier this key toggles.
  public var modifier: KeyModifiers? {
    switch self {
    case .control: .control
    case .alt: .alt
    default: nil
    }
  }

  /// Input for a tap with `modifiers` applied; empty for modifier toggles.
  public func inputs(modifiers: KeyModifiers) -> [TerminalInput] {
    let key: Key
    switch self {
    case .control, .alt: return []
    case let .symbol(s):
      return KeyTranslator.inputs(forText: s, modifiers: modifiers)
    case .escape: key = .escape
    case .tab: key = .tab
    case .left: key = .left
    case .down: key = .down
    case .up: key = .up
    case .right: key = .right
    }
    return [.key(KeyEvent(key, modifiers: modifiers))]
  }
}

// MARK: - Scrolling

/// Shared with the macOS frontend; retained here for source compatibility.
public typealias ScrollAccumulator = SwifttyCore.ScrollAccumulator

/// Exponentially decaying fling, matching `UIScrollView`'s normal
/// deceleration rate.
public struct ScrollMomentum: Sendable {
  /// Velocity retained per millisecond.
  public static let decelerationRate: CGFloat = 0.998
  /// Below this speed (lines per second) the fling stops.
  public static let minimumVelocity: CGFloat = 2

  /// Lines per second; positive scrolls back into history.
  public private(set) var velocity: CGFloat = 0

  /// Nonfinite velocities and speeds below the minimum start at rest.
  public init(velocity: CGFloat = 0) {
    self.velocity =
      velocity.isFinite && abs(velocity) >= Self.minimumVelocity ? velocity : 0
  }

  public var isActive: Bool { velocity != 0 }

  /// Advances by `dt` seconds and returns the distance travelled, in lines.
  /// Invalid or nonpositive intervals leave velocity unchanged.
  public mutating func step(_ dt: CFTimeInterval) -> CGFloat {
    guard isActive, dt.isFinite, dt > 0 else { return 0 }
    // v(t) = v0·r^(1000t), so the distance is v0·(r^(1000dt) − 1) / (1000·ln r).
    let k = 1000 * log(Self.decelerationRate)
    let decay = exp(k * CGFloat(dt))
    let distance = velocity * expm1(k * CGFloat(dt)) / k
    velocity *= decay
    if abs(velocity) < Self.minimumVelocity { velocity = 0 }
    return distance
  }

  public mutating func stop() { velocity = 0 }
}

/// A one-finger drag between panes: the terminal and its neighbour move
/// with the finger, as pages do.
public enum PaneDrag: Equatable, Sendable {
  /// Sideways travel so far; negative moves toward the next pane.
  case changed(CGFloat)
  /// Lifted, with the sideways velocity in points per second.
  case ended(CGFloat, velocity: CGFloat)
  case cancelled

  /// Travel before a pan's axis is decided.
  public static let decisionDistance: CGFloat = 12
  /// Sideways travel per point of vertical travel for a pan to page.
  public static let minimumRatio: CGFloat = 1.5
  /// Sideways speed that turns the page however short the drag.
  public static let flickVelocity: CGFloat = 300

  /// Whether a pan pages (`true`) or scrolls (`false`); nil until it has
  /// travelled `decisionDistance`.
  public static func pages(_ travel: CGPoint) -> Bool? {
    guard travel.x.isFinite, travel.y.isFinite else { return false }
    guard max(abs(travel.x), abs(travel.y)) >= decisionDistance else {
      return nil
    }
    return abs(travel.x) >= minimumRatio * abs(travel.y)
  }

  /// Whether a released drag turns the page: past a third of the width,
  /// or flicked onward. Returns `true` for the next pane (moving left),
  /// `false` for the previous, nil to settle back.
  public static func commit(
    travel dx: CGFloat,
    velocity vx: CGFloat,
    width: CGFloat
  ) -> Bool? {
    guard dx.isFinite, vx.isFinite, width > 0, dx != 0 else { return nil }
    let fast = abs(vx) >= flickVelocity
    // Flicked back toward where it started: settle.
    if fast, (vx < 0) != (dx < 0) { return nil }
    guard fast || abs(dx) >= width / 3 else { return nil }
    return dx < 0
  }
}

/// How far the user has lowered a terminal lifted above the keyboard.
///
/// The lift scrolls the top of the grid out of view, and moving the
/// viewport cannot bring it back, so the oldest history stayed hidden
/// while the keyboard was up. Like a scroll view's content inset, a
/// scroll toward history first lowers the view; one back toward live
/// output restores the lift only once the viewport is live again.
public struct KeyboardReveal: Equatable, Sendable {
  /// Points of the lift undone, from zero to the lift.
  public private(set) var revealed: CGFloat = 0

  public init() {}

  /// Takes what `points` of scrolling (positive toward history) spends
  /// on the lift and returns the rest, for the viewport.
  public mutating func consume(
    _ points: CGFloat,
    lift: CGFloat,
    atLive: Bool
  ) -> CGFloat {
    guard points.isFinite, lift.isFinite else { return points }
    revealed = min(revealed, max(0, lift))
    if points > 0 {
      let take = min(points, max(0, lift) - revealed)
      revealed += take
      return points - take
    }
    if points < 0, atLive {
      let give = min(-points, revealed)
      revealed -= give
      return points + give
    }
    return points
  }

  public mutating func reset() { revealed = 0 }
}

/// How a scroll of whole lines reaches the terminal.
public enum ScrollRouting: Equatable, Sendable {
  /// The application tracks the mouse: wheel events.
  case wheel
  /// Alternate screen with alternate scroll mode: arrow keys.
  case arrows
  /// Move the viewport through scrollback.
  case viewport

  public init(modes: Modes) {
    if !modes.isDisjoint(with: Modes.mouseTracking) {
      self = .wheel
    } else if modes.contains(.alternateScreen), modes.contains(.alternateScroll)
    {
      self = .arrows
    } else {
      self = .viewport
    }
  }
}

// MARK: - Geometry and selection

/// Maps view points to grid cells.
public struct GridGeometry: Equatable, Sendable {
  /// Points to pixels.
  public var scale: CGFloat
  /// Grid inset in pixels.
  public var padding: CGPoint
  /// Cell size in pixels.
  public var cellSize: CGSize

  public init(scale: CGFloat, padding: CGPoint, cellSize: CGSize) {
    self.scale = scale
    self.padding = padding
    self.cellSize = cellSize
  }

  /// Cell under `point` (view points, top-left origin); may lie outside the grid.
  public func cell(at point: CGPoint) -> (column: Int, row: Int) {
    let x = (point.x * scale - padding.x) / cellSize.width
    let y = (point.y * scale - padding.y) / cellSize.height
    return (TerminalGeometry.cellIndex(x), TerminalGeometry.cellIndex(y))
  }

  /// Pixel position inside the padding, for SGR pixel reports.
  public func pixel(at point: CGPoint) -> (x: Int, y: Int) {
    (
      Int((point.x * scale - padding.x).rounded()),
      Int((point.y * scale - padding.y).rounded())
    )
  }

  /// Rect of a cell in view points.
  public func rect(column: Int, row: Int) -> CGRect {
    CGRect(
      x: (padding.x + CGFloat(column) * cellSize.width) / scale,
      y: (padding.y + CGFloat(row) * cellSize.height) / scale,
      width: cellSize.width / scale,
      height: cellSize.height / scale,
    )
  }

  /// Height of one line in points.
  public var lineHeight: CGFloat { cellSize.height / scale }
}
