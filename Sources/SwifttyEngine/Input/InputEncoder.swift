public struct KeyModifiers: OptionSet, Sendable, Hashable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let shift = KeyModifiers(rawValue: 1 << 0)
  public static let alt = KeyModifiers(rawValue: 1 << 1)
  public static let control = KeyModifiers(rawValue: 1 << 2)
  public static let command = KeyModifiers(rawValue: 1 << 3)
  /// Lock states. Only the kitty protocol reports them.
  public static let capsLock = KeyModifiers(rawValue: 1 << 4)
  public static let numLock = KeyModifiers(rawValue: 1 << 5)
  public static let locks: KeyModifiers = [.capsLock, .numLock]

  /// xterm modifier parameter (1 + shift/alt/ctrl bits).
  var xtermParameter: Int { 1 + Int(rawValue & 0b111) }
}

public enum Key: Sendable, Hashable {
  /// A key producing `scalar` before modifiers are applied.
  case character(Unicode.Scalar)
  case enter, tab, backspace, escape
  case up, down, left, right
  case home, end, pageUp, pageDown, insert, delete
  case function(Int)  // F1...F12
  /// A numeric keypad key. With NumLock off, frontends send the
  /// navigation cases the keys are labelled with.
  case keypad(KeypadKey)
}

/// Raw values are the protocol names RST/1 and SMX/2 carry.
public enum KeypadKey: String, Sendable, Hashable, CaseIterable {
  case zero, one, two, three, four, five, six, seven, eight, nine
  case decimal, divide, multiply, subtract, add, enter, equal, separator
  case left, right, up, down, pageUp, pageDown, home, end, insert, delete
  case begin

  /// The text a keypad key types, or nil for Enter and navigation keys.
  public var text: Unicode.Scalar? {
    switch self {
    case .zero: "0"
    case .one: "1"
    case .two: "2"
    case .three: "3"
    case .four: "4"
    case .five: "5"
    case .six: "6"
    case .seven: "7"
    case .eight: "8"
    case .nine: "9"
    case .decimal: "."
    case .divide: "/"
    case .multiply: "*"
    case .subtract: "-"
    case .add: "+"
    case .equal: "="
    case .separator: ","
    default: nil
    }
  }

  /// SS3 final byte under the application keypad (DECKPAM).
  var applicationFinal: UInt8? {
    switch self {
    case .zero: 0x70  // p
    case .one: 0x71
    case .two: 0x72
    case .three: 0x73
    case .four: 0x74
    case .five: 0x75
    case .six: 0x76
    case .seven: 0x77
    case .eight: 0x78
    case .nine: 0x79  // y
    case .decimal: 0x6E  // n
    case .divide: 0x6F  // o
    case .multiply: 0x6A  // j
    case .subtract: 0x6D  // m
    case .add: 0x6B  // k
    case .enter: 0x4D  // M
    default: nil
    }
  }

  /// The main-keyboard key a navigation keypad key encodes like.
  public var navigationKey: Key? {
    switch self {
    case .left: .left
    case .right: .right
    case .up: .up
    case .down: .down
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .home: .home
    case .end: .end
    case .insert: .insert
    case .delete: .delete
    default: nil
    }
  }

  /// The main-keyboard key typing the same thing, for consumers without
  /// keypad encodings; nil for Begin.
  public var mainKey: Key? {
    if let text { return .character(text) }
    return self == .enter ? .enter : navigationKey
  }

  /// Kitty functional key code (KP_0 = 57399 ... KP_BEGIN = 57427).
  var kittyCode: UInt32 { 57399 + UInt32(Self.allCases.firstIndex(of: self)!) }
}

public struct KeyEvent: Sendable, Hashable {
  public enum Action: Sendable, Hashable { case press, `repeat`, release }

  public var key: Key
  public var modifiers: KeyModifiers
  /// Releases are only encoded under the kitty protocol's event types flag.
  public var action: Action
  /// Text the key produced, for the kitty protocol's associated text flag.
  public var text: String?
  /// For the kitty protocol's alternate keys flag: the key's character
  /// with shift applied, and the key at the same position on a US
  /// (PC-101) layout.
  public var shiftedKey: Unicode.Scalar?
  public var baseLayoutKey: Unicode.Scalar?

  public init(
    _ key: Key,
    modifiers: KeyModifiers = [],
    action: Action = .press,
    text: String? = nil,
    shiftedKey: Unicode.Scalar? = nil,
    baseLayoutKey: Unicode.Scalar? = nil,
  ) {
    self.key = key
    self.modifiers = modifiers
    self.action = action
    self.text = text
    self.shiftedKey = shiftedKey
    self.baseLayoutKey = baseLayoutKey
  }
}

public struct MouseEvent: Sendable, Hashable {
  public enum Action: Sendable { case press, release, motion }
  public enum Button: Sendable {
    case left, middle, right, none, wheelUp, wheelDown, wheelLeft, wheelRight
  }

  public var action: Action
  public var button: Button
  /// Zero-based cell coordinates.
  public var column: Int
  public var row: Int
  public var modifiers: KeyModifiers
  /// Zero-based terminal-space pixel position (excluding padding) for SGR
  /// pixel reports (mode 1016). It is not clamped to the grid.
  public var pixelX: Int?
  public var pixelY: Int?

  /// A wheel notch rather than a button.
  public var isWheel: Bool {
    switch button {
    case .wheelUp, .wheelDown, .wheelLeft, .wheelRight: true
    case .left, .middle, .right, .none: false
    }
  }

  public init(
    _ action: Action,
    _ button: Button,
    column: Int,
    row: Int,
    modifiers: KeyModifiers = [],
    pixelX: Int? = nil,
    pixelY: Int? = nil
  ) {
    self.action = action
    self.button = button
    self.column = column
    self.row = row
    self.modifiers = modifiers
    self.pixelX = pixelX
    self.pixelY = pixelY
  }
}

public enum TerminalInput: Sendable {
  /// Committed text (typed characters, IME output). Control actions use `.key`
  /// and intentional protocol bytes use `.bytes`.
  case text(String)
  case key(KeyEvent)
  case paste(String)
  case mouse(MouseEvent)
  case focus(Bool)
  case bytes([UInt8])
}

/// Encodes input into the byte sequences applications expect, following
/// xterm conventions and the terminal's current modes.
public enum InputEncoder {
  /// Kitty encoding is activated by disambiguation or reporting all keys.
  /// Event types, alternate keys, and associated text only refine encoding.
  public static func isKittyKeyboardActive(_ flags: UInt8) -> Bool {
    flags & 0b1001 != 0
  }

  /// Appends encoded input using the current modes.
  /// - Parameters:
  ///   - input: Event to encode.
  ///   - modes: Terminal modes.
  ///   - keyboardFlags: Kitty enhancement flags.
  ///   - out: Destination bytes.
  /// - Returns: Whether the event has an encoding in these modes.
  @discardableResult
  public static func encode(
    _ input: TerminalInput,
    modes: Modes,
    keyboardFlags: UInt8 = 0,
    into out: inout [UInt8]
  ) -> Bool {
    switch input {
    case let .text(s):
      guard keyboardFlags & 8 != 0, !s.isEmpty else {
        out.append(contentsOf: s.utf8)
        return true
      }
      // A composition commit has no physical key identity. Report zero,
      // including when all-key reporting deliberately omits associated text.
      guard s.unicodeScalars.allSatisfy(Self.isKeyTextScalar) else {
        return false
      }
      var params = "0"
      if keyboardFlags & 16 != 0 {
        params += ";1;"
        params += s.unicodeScalars.map { String($0.value) }
          .joined(separator: ":")
      }
      appendCSI(out: &out, params, 0x75)
    case let .bytes(b): out.append(contentsOf: b)
    case let .key(event):
      if isKittyKeyboardActive(keyboardFlags) {
        return encodeKittyKey(
          event,
          flags: keyboardFlags,
          modes: modes,
          into: &out
        )
      }
      guard event.action != .release else { return false }
      // A printable key's own text (shifted or composed) when no
      // Ctrl/Alt asks for a control encoding.
      if case .character = event.key, let text = event.text, !text.isEmpty,
        event.modifiers.isDisjoint(with: [.control, .alt]),
        !modes.contains(.modifyOtherKeys)
          || modifiedOtherKey(event, keyModifiers(event)) == nil
      {
        out.append(contentsOf: text.utf8)
        return true
      }
      return encodeKey(event, modes: modes, into: &out)
    case let .paste(s):
      let bracketed = modes.contains(.bracketedPaste)
      if bracketed { out.append(contentsOf: "\u{1B}[200~".utf8) }
      var previous: UInt8 = 0
      for byte in s.utf8 {
        let b = sanitizedPasteByte(byte)
        if !bracketed, b == 0x0A {
          if previous != 0x0D { out.append(0x0D) }
        } else {
          out.append(b)
        }
        previous = b
      }
      if bracketed { out.append(contentsOf: "\u{1B}[201~".utf8) }
    case let .mouse(event): return encodeMouse(event, modes: modes, into: &out)
    case let .focus(focused):
      guard modes.contains(.focusEvents) else { return false }
      out.append(contentsOf: focused ? "\u{1B}[I".utf8 : "\u{1B}[O".utf8)
    }
    return true
  }

  /// Match xterm's paste filtering: controls that edit, signal, or escape
  /// the paste become spaces. Bracketing alone does not neutralize them.
  private static func sanitizedPasteByte(_ byte: UInt8) -> UInt8 {
    switch byte {
    case 0x00, 0x03, 0x04, 0x05, 0x08, 0x0F, 0x11, 0x12, 0x13, 0x15, 0x16, 0x17,
      0x1A, 0x1B, 0x1C, 0x7F:
      0x20
    default: byte
    }
  }

  // MARK: Keys

  static func encodeKey(
    _ event: KeyEvent,
    modes: Modes,
    into out: inout [UInt8]
  ) -> Bool {
    let mods = keyModifiers(event)
    let alt = mods.contains(.alt)
    if modes.contains(.modifyOtherKeys),
      let params = modifiedOtherKey(event, mods)
    {
      appendCSI(out: &out, params, 0x7E)
      return true
    }
    switch event.key {
    case let .character(scalar):
      var value = scalar.value
      // Meta without Ctrl sends ESC + the typed (shifted) text.
      if alt, !mods.contains(.control), let text = event.text, !text.isEmpty {
        out.append(0x1B)
        out.append(contentsOf: text.utf8)
        return true
      }
      if mods.contains(.control), let control = controlCode(value) {
        value = UInt32(control)
      }
      if alt { out.append(0x1B) }
      appendUTF8(value, &out)
    case .enter:
      if alt { out.append(0x1B) }
      out.append(0x0D)
      if modes.contains(.linefeedNewline) { out.append(0x0A) }
    case .tab:
      if mods.contains(.shift) {
        out.append(contentsOf: "\u{1B}[Z".utf8)
      } else {
        if alt { out.append(0x1B) };
        out.append(0x09)
      }
    case .backspace:
      if alt { out.append(0x1B) }
      // DECBKM swaps which of BS and DEL Ctrl selects.
      let backspace = mods.contains(.control) != modes.contains(.backarrowKey)
      out.append(backspace ? 0x08 : 0x7F)
    case .escape:
      if alt { out.append(0x1B) }
      out.append(0x1B)
    case .up: cursorKey(0x41, mods, modes, &out)
    case .down: cursorKey(0x42, mods, modes, &out)
    case .right: cursorKey(0x43, mods, modes, &out)
    case .left: cursorKey(0x44, mods, modes, &out)
    case .home: cursorKey(0x48, mods, modes, &out)
    case .end: cursorKey(0x46, mods, modes, &out)
    case .insert: tildeKey(2, mods, &out)
    case .delete: tildeKey(3, mods, &out)
    case .pageUp: tildeKey(5, mods, &out)
    case .pageDown: tildeKey(6, mods, &out)
    case let .function(n):
      switch n {
      case 1 ... 4:  // SS3 P/Q/R/S, or CSI 1;m P with modifiers
        let final = UInt8(0x50 + n - 1)
        if mods.isEmpty {
          out.append(contentsOf: [0x1B, 0x4F, final])
        } else {
          appendCSI(out: &out, "1;\(mods.xtermParameter)", final)
        }
      case 5 ... 12:
        let codes = [15, 17, 18, 19, 20, 21, 23, 24]
        tildeKey(codes[n - 5], mods, &out)
      default: return false
      }
    case let .keypad(key):
      return encodeKeypad(key, event, mods, modes: modes, into: &out)
    }
    return true
  }

  /// Shift, Alt and Ctrl; Command and lock states have no legacy encoding.
  private static func keyModifiers(_ event: KeyEvent) -> KeyModifiers {
    event.modifiers.subtracting(KeyModifiers.locks.union(.command))
  }

  /// xterm `modifyOtherKeys` state 2 parameters (`27 ; modifier ; code`),
  /// or nil when the key keeps its ordinary encoding.
  static func modifiedOtherKey(
    _ event: KeyEvent,
    _ mods: KeyModifiers
  ) -> String? {
    guard !mods.isEmpty else { return nil }
    let code: UInt32
    switch event.key {
    case let .character(scalar):
      let typed = event.text.map { Array($0.unicodeScalars) } ?? []
      let produced =
        typed.count == 1 && isKeyTextScalar(typed[0])
        ? typed[0] : mods.contains(.shift) ? event.shiftedKey ?? scalar : scalar
      // Shift alone still types text, except for Space.
      guard !mods.subtracting(.shift).isEmpty || produced == " " else {
        return nil
      }
      code = produced.value
    case .enter: code = 13
    case .escape: code = 27
    case .tab:
      // Shift+Tab is CSI Z unless another modifier joins it.
      guard mods != .shift else { return nil }
      code = 9
    case .backspace:
      // Ctrl alone keeps its BS/DEL encoding (and DECBKM).
      guard mods != .control else { return nil }
      code = 127
    default: return nil
    }
    return "27;\(mods.xtermParameter);\(code)"
  }

  /// Numeric keypad keys. Mode 1035 keeps them numeric under DECKPAM.
  private static func encodeKeypad(
    _ key: KeypadKey,
    _ event: KeyEvent,
    _ mods: KeyModifiers,
    modes: Modes,
    into out: inout [UInt8]
  ) -> Bool {
    if let navigation = key.navigationKey {
      var event = event
      event.key = navigation
      return encodeKey(event, modes: modes, into: &out)
    }
    if key == .begin {
      cursorKey(0x45, mods, modes, &out)
      return true
    }
    let application =
      modes.contains(.keypadApplication)
      && !modes.contains(.ignoreKeypadWithNumLock)
    if application, let final = key.applicationFinal {
      out.append(contentsOf: [0x1B, 0x4F])
      if !mods.isEmpty { out.append(contentsOf: "\(mods.xtermParameter)".utf8) }
      out.append(final)
      return true
    }
    if key == .enter {
      var event = event
      event.key = .enter
      return encodeKey(event, modes: modes, into: &out)
    }
    guard
      let text = event.text.flatMap({ $0.isEmpty ? nil : $0 })
        ?? key.text.map(String.init)
    else { return false }
    out.append(contentsOf: text.utf8)
    return true
  }

  /// Kitty keyboard protocol (progressive enhancement flags: 1
  /// disambiguate, 2 event types, 8 all keys as escape codes, 16
  /// associated text). Returns false when the event produces nothing.
  static func encodeKittyKey(
    _ event: KeyEvent,
    flags: UInt8,
    modes: Modes,
    into out: inout [UInt8]
  ) -> Bool {
    let allKeys = flags & 8 != 0
    let eventTypes = flags & 2 != 0
    let plainControl =
      event.key == .enter || event.key == .tab || event.key == .backspace
    // These three keys require all-key reporting for releases, even
    // when modifiers cause their presses to use CSI encodings.
    if event.action == .release, !eventTypes || (plainControl && !allKeys) {
      return false
    }
    var mods = event.modifiers
    var bits = Int(mods.rawValue & 0b111)  // shift, alt, ctrl
    if mods.contains(.command) {
      bits |= 8  // super
    }
    // Lock states are reported but never prevent text or legacy keys.
    let bindingBits = bits
    if mods.contains(.capsLock) { bits |= 64 }
    if mods.contains(.numLock) { bits |= 128 }
    mods.subtract(KeyModifiers.locks.union(.command))
    // Event types are reported only when the application asked (flag 2).
    let event2 =
      !eventTypes
      ? 1 : event.action == .repeat ? 2 : event.action == .release ? 3 : 1

    // Functional keys use canonical CSI forms, gaining modifier and
    // event fields only when needed. Application cursor mode and SS3
    // encodings apply only outside the active kitty protocol.
    let legacy: (number: Int, final: UInt8)? =
      switch event.key {
      case .up: (1, 0x41)
      case .down: (1, 0x42)
      case .right: (1, 0x43)
      case .left: (1, 0x44)
      case .home: (1, 0x48)
      case .end: (1, 0x46)
      case .insert: (2, 0x7E)
      case .delete: (3, 0x7E)
      case .pageUp: (5, 0x7E)
      case .pageDown: (6, 0x7E)
      case let .function(n):
        switch n {
        case 1: (1, 0x50)
        case 2: (1, 0x51)
        case 3: (13, 0x7E)
        case 4: (1, 0x53)
        case 5 ... 12: ([15, 17, 18, 19, 20, 21, 23, 24][n - 5], 0x7E)
        default: nil
        }
      default: nil
      }
    if let legacy {
      if bits == 0, event2 == 1 {
        appendCSI(
          out: &out,
          legacy.final == 0x7E ? "\(legacy.number)" : "",
          legacy.final
        )
        return true
      }
      let params =
        "\(legacy.number);\(1 + bits)" + (event2 != 1 ? ":\(event2)" : "")
      appendCSI(out: &out, params, legacy.final)
      return true
    }

    let code: UInt32
    var producesText = false
    var keyText = event.text
    switch event.key {
    case .escape: code = 27
    case .enter: code = 13
    case .tab: code = 9
    case .backspace: code = 127
    case let .character(scalar):
      // The frontend supplies the layout's unshifted scalar. Unicode
      // lowercasing can change that key or expand it into several scalars.
      code =
        (0x41 ... 0x5A).contains(scalar.value)
        ? scalar.value + 0x20 : scalar.value
      // Text bypasses CSI only for printable keys and text without
      // controls. Otherwise report the key through the protocol.
      producesText =
        bindingBits & ~1 == 0 && Self.isKeyTextScalar(scalar)
        && (event.text?.unicodeScalars.allSatisfy(Self.isKeyTextScalar) ?? true)
    case let .keypad(key):
      code = key.kittyCode
      producesText = bindingBits & ~1 == 0 && key.text != nil
      if keyText?.isEmpty ?? true { keyText = key.text.map(String.init) }
    default: return false
    }
    // Without "all keys", text and unmodified Enter/Tab/Backspace stay legacy
    // (and text releases are not reported).
    if !allKeys, producesText || (plainControl && bindingBits == 0) {
      guard event.action != .release else { return false }
      if producesText, let text = keyText, !text.isEmpty {
        out.append(contentsOf: text.utf8)
        return true
      }
      return encodeKey(
        KeyEvent(event.key, modifiers: mods),
        modes: modes,
        into: &out
      )
    }
    var params = "\(code)"
    if flags & 4 != 0, case let .character(scalar) = event.key,
      Self.isKeyTextScalar(scalar)
    {
      // Alternate keys: `code:shifted:base`, each part only when it adds information.
      let shifted =
        mods.contains(.shift)
        ? event.shiftedKey.flatMap {
          Self.isKeyTextScalar($0) && $0.value != code ? $0.value : nil
        } : nil
      let base = event.baseLayoutKey.flatMap {
        Self.isKeyTextScalar($0) && $0.value != code ? $0.value : nil
      }
      if let shifted { params += ":\(shifted)" }
      if let base { params += (shifted == nil ? "::" : ":") + "\(base)" }
    }
    if bits != 0 || event2 != 1 {
      params += ";\(1 + bits)" + (event2 != 1 ? ":\(event2)" : "")
    }
    if flags & 16 != 0, allKeys, event.action != .release,
      let text = event.text, !text.isEmpty,
      text.unicodeScalars.allSatisfy(Self.isKeyTextScalar)
    {
      if bits == 0, event2 == 1 { params += ";1" }
      params +=
        ";"
        + text.unicodeScalars.map { String($0.value) }.joined(separator: ":")
    }
    appendCSI(out: &out, params, 0x75)
    return true
  }

  /// Kitty key text excludes C0, DEL and C1 control scalars.
  private static func isKeyTextScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 0x20 && (scalar.value < 0x7F || scalar.value > 0x9F)
  }

  /// Control-key mapping for printable keys (xterm/VT220 table).
  static func controlCode(_ value: UInt32) -> UInt8? {
    switch value {
    case 0x61 ... 0x7A: UInt8(value - 0x60)  // a-z
    case 0x41 ... 0x5A: UInt8(value - 0x40)  // A-Z
    case 0x40, 0x20, 0x32: 0x00  // @ space 2
    case 0x5B, 0x33: 0x1B  // [ 3
    case 0x5C, 0x34: 0x1C  // \ 4
    case 0x5D, 0x35: 0x1D  // ] 5
    case 0x5E, 0x36: 0x1E  // ^ 6
    case 0x5F, 0x2F, 0x37: 0x1F  // _ / 7
    case 0x38, 0x3F: 0x7F  // 8 ?
    default: nil
    }
  }

  private static func cursorKey(
    _ final: UInt8,
    _ mods: KeyModifiers,
    _ modes: Modes,
    _ out: inout [UInt8]
  ) {
    if !mods.isEmpty {
      appendCSI(out: &out, "1;\(mods.xtermParameter)", final)
    } else if modes.contains(.cursorKeys) {
      out.append(contentsOf: [0x1B, 0x4F, final])
    } else {
      out.append(contentsOf: [0x1B, 0x5B, final])
    }
  }

  private static func tildeKey(
    _ code: Int,
    _ mods: KeyModifiers,
    _ out: inout [UInt8]
  ) {
    appendCSI(
      out: &out,
      mods.isEmpty ? "\(code)" : "\(code);\(mods.xtermParameter)",
      0x7E
    )
  }

  private static func appendCSI(
    out: inout [UInt8],
    _ params: String,
    _ final: UInt8
  ) {
    out.append(0x1B)
    out.append(0x5B)
    out.append(contentsOf: params.utf8)
    out.append(final)
  }

  @inline(__always)
  static func appendUTF8(_ value: UInt32, _ out: inout [UInt8]) {
    switch value {
    case 0 ..< 0x80: out.append(UInt8(value))
    case 0x80 ..< 0x800:
      out.append(UInt8(0xC0 | value >> 6))
      out.append(UInt8(0x80 | value & 0x3F))
    case 0x800 ..< 0x10000:
      out.append(UInt8(0xE0 | value >> 12))
      out.append(UInt8(0x80 | value >> 6 & 0x3F))
      out.append(UInt8(0x80 | value & 0x3F))
    default:
      out.append(UInt8(0xF0 | value >> 18))
      out.append(UInt8(0x80 | value >> 12 & 0x3F))
      out.append(UInt8(0x80 | value >> 6 & 0x3F))
      out.append(UInt8(0x80 | value & 0x3F))
    }
  }

  // MARK: Mouse

  static func encodeMouse(
    _ event: MouseEvent,
    modes: Modes,
    into out: inout [UInt8]
  ) -> Bool {
    let tracking = modes.intersection(Modes.mouseTracking)
    guard !tracking.isEmpty else { return false }
    let isWheel = event.isWheel

    switch event.action {
    case .press:
      // X10 only reports the three ordinary mouse buttons.
      if tracking.contains(.mouseX10), isWheel || event.button == .none {
        return false
      }
    case .release:
      guard !tracking.contains(.mouseX10), !isWheel else { return false }
    case .motion:
      if tracking.contains(.mouseAny) { break }
      guard tracking.contains(.mouseButton), event.button != .none else {
        return false
      }
    }

    var code =
      switch event.button {
      case .left: 0
      case .middle: 1
      case .right: 2
      case .none: 3
      case .wheelUp: 64
      case .wheelDown: 65
      case .wheelLeft: 66
      case .wheelRight: 67
      }
    let pixels = modes.contains(.mouseSGRPixels)
    let sgr = pixels || modes.contains(.mouseSGR)
    if event.action == .release, !sgr { code = 3 }
    if event.action == .motion { code += 32 }
    if !tracking.contains(.mouseX10) {
      if event.modifiers.contains(.shift) { code += 4 }
      if event.modifiers.contains(.alt) { code += 8 }
      if event.modifiers.contains(.control) { code += 16 }
    }

    let x = max(0, min(event.column, Int.max - 1)) + 1
    let y = max(0, min(event.row, Int.max - 1)) + 1
    if pixels {
      // Without a pixel position the report would be wrong; send none.
      guard let px = event.pixelX, let py = event.pixelY else { return false }
      appendCSI(
        out: &out,
        "<\(code);\(px);\(py)",
        event.action == .release ? 0x6D : 0x4D
      )
    } else if sgr {
      appendCSI(
        out: &out,
        "<\(code);\(x);\(y)",
        event.action == .release ? 0x6D : 0x4D
      )
    } else if modes.contains(.mouseURXVT) {
      appendCSI(out: &out, "\(code + 32);\(x);\(y)", 0x4D)
    } else if modes.contains(.mouseUTF8) {
      out.append(contentsOf: [0x1B, 0x5B, 0x4D])
      for v in [code + 32, min(x, 2015) + 32, min(y, 2015) + 32] {
        appendUTF8(UInt32(v), &out)
      }
    } else {
      guard x <= 223, y <= 223 else { return false }
      out.append(contentsOf: [
        0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(x + 32), UInt8(y + 32),
      ])
    }
    return true
  }
}
