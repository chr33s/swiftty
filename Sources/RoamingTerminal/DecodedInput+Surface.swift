import RoamingKit
import SessionCore
import SwiftMuxProtocol
import TTYKit

// Outer-terminal input onto the semantic operations a roaming client
// submits. The host encodes keys with its own terminal modes.

extension SemanticKeyName {
  /// The semantic name of a decoded outer key, or nil for keys RST/1
  /// cannot carry (controls as characters, function keys beyond F12).
  public init?(_ key: MuxKey) {
    switch key {
    case let .character(value):
      guard let scalar = Unicode.Scalar(value), value >= 0x20, value != 0x7F,
        !(0x80 ... 0x9F).contains(value)
      else { return nil }
      self = .character(scalar)
    case .enter: self = .enter
    case .tab: self = .tab
    case .backspace: self = .backspace
    case .escape: self = .escape
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .home: self = .home
    case .end: self = .end
    case .pageUp: self = .pageUp
    case .pageDown: self = .pageDown
    case .insert: self = .insert
    case .delete: self = .delete
    case let .function(n):
      guard (1 ... 12).contains(n) else { return nil }
      self = .function(n)
    case let .keypad(key):
      guard let keypad = SemanticKeypadKey(rawValue: key.rawValue) else {
        return nil
      }
      self = .keypad(keypad)
    }
  }
}

extension SemanticModifiers {
  public init(_ modifiers: MuxKeyModifiers) {
    var out = SemanticModifiers()
    if modifiers.contains(.shift) { out.insert(.shift) }
    if modifiers.contains(.alt) { out.insert(.alt) }
    if modifiers.contains(.control) { out.insert(.control) }
    self = out
  }
}

extension SurfaceInput {
  /// The semantic input for decoded outer input, or nil when it must not
  /// reach the host: empty text, a truncated paste, an unmappable key.
  public init?(_ input: DecodedInput) {
    switch input {
    case let .text(text):
      guard !text.isEmpty else { return nil }
      self = .text(text)
    case let .paste(text, truncated):
      // A partial paste could run a different command than the one copied.
      guard !text.isEmpty, !truncated else { return nil }
      self = .paste(text)
    case let .key(key, modifiers):
      guard let name = SemanticKeyName(key) else { return nil }
      self = .key(SemanticKey(name, modifiers: SemanticModifiers(modifiers)))
    }
  }
}
