/// Named keys a client may submit. Printable keys use `character`.
public enum SemanticKeyName: Hashable, Sendable {
  case character(Unicode.Scalar)
  case enter, tab, backspace, escape
  case up, down, left, right
  case home, end, pageUp, pageDown, insert, delete
  case function(Int)
  /// Sent only to hosts whose `Attached` lists `keypadKeys`.
  case keypad(SemanticKeypadKey)

  /// Wire spelling: `enter`, `f5`, `kp:<key>`, or `char:<scalar>`.
  public var wireName: String {
    switch self {
    case let .character(scalar): "char:" + String(Character(scalar))
    case .enter: "enter"
    case .tab: "tab"
    case .backspace: "backspace"
    case .escape: "escape"
    case .up: "up"
    case .down: "down"
    case .left: "left"
    case .right: "right"
    case .home: "home"
    case .end: "end"
    case .pageUp: "pageUp"
    case .pageDown: "pageDown"
    case .insert: "insert"
    case .delete: "delete"
    case let .function(n): "f\(n)"
    case let .keypad(key): "kp:" + key.rawValue
    }
  }

  public init?(wireName: String) {
    if wireName.hasPrefix("kp:") {
      guard let key = SemanticKeypadKey(rawValue: String(wireName.dropFirst(3)))
      else { return nil }
      self = .keypad(key)
      return
    }
    if wireName.hasPrefix("char:") {
      let rest = wireName.dropFirst(5).unicodeScalars
      guard rest.count == 1, let scalar = rest.first else { return nil }
      self = .character(scalar)
      return
    }
    switch wireName {
    case "enter": self = .enter
    case "tab": self = .tab
    case "backspace": self = .backspace
    case "escape": self = .escape
    case "up": self = .up
    case "down": self = .down
    case "left": self = .left
    case "right": self = .right
    case "home": self = .home
    case "end": self = .end
    case "pageUp": self = .pageUp
    case "pageDown": self = .pageDown
    case "insert": self = .insert
    case "delete": self = .delete
    default:
      guard wireName.hasPrefix("f"), wireName.utf8.count <= 3,
        let n = Int(wireName.dropFirst()), (1 ... 12).contains(n),
        String(n) == wireName.dropFirst()
      else { return nil }
      self = .function(n)
    }
  }
}

/// Numeric keypad keys, named as on the wire after `kp:`.
public enum SemanticKeypadKey: String, CaseIterable, Hashable, Sendable {
  case zero, one, two, three, four, five, six, seven, eight, nine
  case decimal, divide, multiply, subtract, add, enter, equal, separator
  case left, right, up, down, pageUp, pageDown, home, end, insert, delete
  case begin
}

public struct SemanticModifiers: OptionSet, Hashable, Sendable, Codable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = SemanticModifiers(rawValue: 1 << 0)
  public static let alt = SemanticModifiers(rawValue: 1 << 1)
  public static let control = SemanticModifiers(rawValue: 1 << 2)

  static let names: [(String, SemanticModifiers)] = [
    ("shift", .shift), ("alt", .alt), ("control", .control),
  ]

  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var result = SemanticModifiers()
    var count = 0
    while !container.isAtEnd {
      count += 1
      let name = try container.decode(String.self)
      guard count <= 3, let flag = Self.names.first(where: { $0.0 == name })
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "bad modifier"
        )
      }
      result.insert(flag.1)
    }
    self = result
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    for (name, flag) in Self.names where contains(flag) {
      try container.encode(name)
    }
  }
}

public struct SemanticKey: Hashable, Sendable, Codable {
  public var name: SemanticKeyName
  public var modifiers: SemanticModifiers

  public init(_ name: SemanticKeyName, modifiers: SemanticModifiers = []) {
    self.name = name
    self.modifiers = modifiers
  }

  enum CodingKeys: String, CodingKey { case name, modifiers }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let wire = try c.decode(String.self, forKey: .name)
    guard wire.utf8.count <= 16, let name = SemanticKeyName(wireName: wire)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .name,
        in: c,
        debugDescription: "unknown key"
      )
    }
    self.name = name
    modifiers =
      try c.decodeIfPresent(SemanticModifiers.self, forKey: .modifiers) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name.wireName, forKey: .name)
    if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
  }
}

/// Which way a wheel notch turns. `up` reveals older content.
public enum SemanticWheelDirection: String, Hashable, Sendable, Codable {
  case up, down, left, right
}

/// One mouse-wheel notch at a viewport cell, sent only to hosts whose
/// `Attached` lists `mouseWheel`. The host reports it only while the
/// program enabled mouse reporting, with its own encoding modes.
public struct SemanticWheel: Hashable, Sendable, Codable {
  public var direction: SemanticWheelDirection
  /// Zero-based viewport cell.
  public var column: Int
  public var row: Int
  public var modifiers: SemanticModifiers

  public init(
    _ direction: SemanticWheelDirection,
    column: Int,
    row: Int,
    modifiers: SemanticModifiers = []
  ) {
    self.direction = direction
    self.column = column
    self.row = row
    self.modifiers = modifiers
  }

  enum CodingKeys: String, CodingKey { case direction, column, row, modifiers }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    direction = try c.decode(SemanticWheelDirection.self, forKey: .direction)
    column = try c.decode(Int.self, forKey: .column)
    row = try c.decode(Int.self, forKey: .row)
    modifiers =
      try c.decodeIfPresent(SemanticModifiers.self, forKey: .modifiers) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(direction, forKey: .direction)
    try c.encode(column, forKey: .column)
    try c.encode(row, forKey: .row)
    if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
  }
}

/// One ordered client operation (spec §8). The host encodes it once with
/// its authoritative terminal modes.
public enum InputOperation: Hashable, Sendable, Codable {
  case committedText(String)
  case key(SemanticKey)
  case paste(String)
  case resize(columns: Int, rows: Int, resizeRevision: UInt64)
  /// Needs `mouseWheel`.
  case wheel(SemanticWheel)

  enum CodingKeys: String, CodingKey {
    case op, text, key, columns, rows, resizeRevision, wheel
  }

  /// Upper bound on the bytes this operation can generate at the host,
  /// used for admission accounting before encoding.
  public var expansionBound: Int {
    switch self {
    // Bracketed paste markers plus escaped control characters.
    case let .paste(text): text.utf8.count * 2 + 12
    case let .committedText(text): text.utf8.count
    // Kitty keyboard encodings stay well under this.
    case .key: 64
    // An SGR report at the largest grid: `ESC [ < 64 ; 200 ; 80 M`.
    case .wheel: 32
    case .resize: 0
    }
  }

  /// Bytes retained while unacknowledged (client accounting).
  public var retainedBytes: Int {
    switch self {
    case let .paste(text), let .committedText(text): text.utf8.count + 16
    case .key: 32
    case .resize, .wheel: 24
    }
  }

  public enum ValidationError: Error, Equatable {
    case empty, pasteTooLarge, textTooLarge, gridOutOfRange, invalidKey
    case invalidWheel
  }

  public func validate() throws(ValidationError) {
    switch self {
    case let .committedText(text):
      guard !text.isEmpty else { throw .empty }
      guard text.utf8.count <= RSTLimits.maxPasteBytes else {
        throw .textTooLarge
      }
    case let .paste(text):
      guard text.utf8.count <= RSTLimits.maxPasteBytes else {
        throw .pasteTooLarge
      }
    case let .key(key):
      if case let .function(number) = key.name, !(1 ... 12).contains(number) {
        throw .invalidKey
      }
      guard key.modifiers.isSubset(of: [.shift, .alt, .control]) else {
        throw .invalidKey
      }
    case let .resize(columns, rows, _):
      guard (1 ... RSTLimits.maxColumns).contains(columns),
        (1 ... RSTLimits.maxRows).contains(rows)
      else { throw .gridOutOfRange }
    case let .wheel(wheel):
      guard (0 ..< RSTLimits.maxColumns).contains(wheel.column),
        (0 ..< RSTLimits.maxRows).contains(wheel.row),
        wheel.modifiers.isSubset(of: [.shift, .alt, .control])
      else { throw .invalidWheel }
    }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .op) {
    case "committedText":
      self = .committedText(try c.decode(String.self, forKey: .text))
    case "paste": self = .paste(try c.decode(String.self, forKey: .text))
    case "key": self = .key(try c.decode(SemanticKey.self, forKey: .key))
    case "resize":
      self = .resize(
        columns: try c.decode(Int.self, forKey: .columns),
        rows: try c.decode(Int.self, forKey: .rows),
        resizeRevision: try c.decode(WireUInt64.self, forKey: .resizeRevision)
          .value
      )
    case "wheel":
      self = .wheel(try c.decode(SemanticWheel.self, forKey: .wheel))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .op,
        in: c,
        debugDescription: "unknown operation"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .committedText(text):
      try c.encode("committedText", forKey: .op)
      try c.encode(text, forKey: .text)
    case let .paste(text):
      try c.encode("paste", forKey: .op)
      try c.encode(text, forKey: .text)
    case let .key(key):
      try c.encode("key", forKey: .op)
      try c.encode(key, forKey: .key)
    case let .resize(columns, rows, revision):
      try c.encode("resize", forKey: .op)
      try c.encode(columns, forKey: .columns)
      try c.encode(rows, forKey: .rows)
      try c.encode(WireUInt64(revision), forKey: .resizeRevision)
    case let .wheel(wheel):
      try c.encode("wheel", forKey: .op)
      try c.encode(wheel, forKey: .wheel)
    }
  }
}
