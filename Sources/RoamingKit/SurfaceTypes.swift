import ScreenProtocol
import SessionCore
import SwifttyEngine

/// Semantic input a frontend submits (spec §6, §A.4.4): committed
/// text, keys and paste, before any terminal-byte encoding. IME preedit
/// stays local; only committed text arrives here. Wheel notches reach
/// hosts with `mouseWheel`; other mouse input stays local.
public enum SurfaceInput: Hashable, Sendable {
  case text(String)
  case key(SemanticKey)
  case paste(String)
  case wheel(SemanticWheel)

  /// The RST/1 operation for this input.
  public var operation: InputOperation {
    switch self {
    case let .text(text): .committedText(text)
    case let .key(key): .key(key)
    case let .paste(text): .paste(text)
    case let .wheel(wheel): .wheel(wheel)
    }
  }

  /// The local encoder input for byte-stream backends.
  public var terminalInput: TerminalInput {
    switch self {
    case let .text(text): .text(text)
    case let .paste(text): .paste(text)
    case let .key(key):
      .key(
        KeyEvent(Self.key(key.name), modifiers: Self.modifiers(key.modifiers))
      )
    case let .wheel(wheel):
      .mouse(
        MouseEvent(
          .press,
          Self.button(wheel.direction),
          column: wheel.column,
          row: wheel.row,
          modifiers: Self.modifiers(wheel.modifiers)
        )
      )
    }
  }

  static func key(_ name: SemanticKeyName) -> Key {
    switch name {
    case let .character(scalar): .character(scalar)
    case .enter: .enter
    case .tab: .tab
    case .backspace: .backspace
    case .escape: .escape
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .home: .home
    case .end: .end
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .insert: .insert
    case .delete: .delete
    case let .function(n): .function(n)
    case let .keypad(k):
      KeypadKey(rawValue: k.rawValue).map(Key.keypad) ?? .enter
    }
  }

  static func button(_ direction: SemanticWheelDirection) -> MouseEvent.Button {
    switch direction {
    case .up: .wheelUp
    case .down: .wheelDown
    case .left: .wheelLeft
    case .right: .wheelRight
    }
  }

  static func modifiers(_ modifiers: SemanticModifiers) -> KeyModifiers {
    var out = KeyModifiers()
    if modifiers.contains(.shift) { out.insert(.shift) }
    if modifiers.contains(.alt) { out.insert(.alt) }
    if modifiers.contains(.control) { out.insert(.control) }
    return out
  }
}

/// Why a backend refused input. Refused input is never queued for later
/// or echoed locally (spec §8).
public enum InputRefusal: Hashable, Sendable {
  /// Offline, reconnecting, attaching or backgrounded.
  case notActive(ClientConnectionState)
  /// The bounded pending-input queue is full; retry after progress.
  case backpressure
  /// Empty or over the size limits.
  case invalid
  case closed
}

public enum SurfaceInputResult: Hashable, Sendable {
  /// Submitted; `sequence` is the RST/1 operation number when ledgered.
  case accepted(sequence: UInt64?)
  case refused(InputRefusal)

  public var isAccepted: Bool {
    if case .accepted = self { return true }
    return false
  }
}

/// Backend lifecycle as the view sees it. Distinguishes a temporary
/// attachment failure from an actual end of the session (spec §A.4.1).
public enum SurfaceLifecycle: Hashable, Sendable {
  /// Establishing the first attachment or channel.
  case connecting
  /// Displaying current state and accepting input.
  case active
  /// Temporarily unavailable (suspect, reconnecting, backgrounded); the
  /// host session is retained. Input is refused.
  case interrupted
  /// The program exited with this status, if known.
  case exited(Int32?)
  /// The session no longer exists (helper restart, expiry, connection
  /// lost for an ordinary SSH shell). Never replayed into a new shell.
  case lost
  /// Closed by the user.
  case closed

  public var isFinal: Bool {
    switch self {
    case .exited, .lost, .closed: true
    default: false
    }
  }
}

/// One immutable, owned frame with a client-local render generation that
/// increases with every install and every attachment fence.
public struct SurfaceFrame: Sendable, Equatable {
  public var generation: UInt64
  public var frame: PresentationFrame

  public init(generation: UInt64, frame: PresentationFrame) {
    self.generation = generation
    self.frame = frame
  }
}

/// A selection on the displayed frame, in cell coordinates, inclusive.
public struct SurfaceSelection: Hashable, Sendable {
  public var start: (row: Int, column: Int)
  public var end: (row: Int, column: Int)

  public init(start: (row: Int, column: Int), end: (row: Int, column: Int)) {
    self.start = start
    self.end = end
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.start == b.start && a.end == b.end
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(start.row)
    hasher.combine(start.column)
    hasher.combine(end.row)
    hasher.combine(end.column)
  }
}

extension PresentationFrame {
  /// Text of a linear selection, joining soft-wrapped rows and trimming
  /// trailing blanks of hard-wrapped ones.
  public func text(in selection: SurfaceSelection) -> String {
    var a = selection.start
    var b = selection.end
    if (b.row, b.column) < (a.row, a.column) { swap(&a, &b) }
    a.row = max(0, a.row)
    b.row = min(rows - 1, b.row)
    guard a.row <= b.row, columns > 0 else { return "" }
    var out = ""
    for row in a.row ... b.row {
      let first = row == a.row ? max(0, a.column) : 0
      let last = row == b.row ? min(columns - 1, b.column) : columns - 1
      var line = ""
      if first <= last {
        for x in first ... last {
          let cell = cells[row * columns + x]
          if cell.width == 0 { continue }
          line += cell.text.isEmpty ? " " : cell.text
        }
      }
      let soft = row < b.row && wrapped[row]
      if !soft { while line.last == " " { line.removeLast() } }
      out += line
      if row < b.row, !soft { out += "\n" }
    }
    return out
  }
}
