import SwiftMuxProtocol

/// One decoded outer input event.
public enum DecodedInput: Equatable, Sendable {
  case text(String)
  case key(MuxKey, MuxKeyModifiers)
  /// A complete bracketed paste. `truncated` when it exceeded the bound.
  case paste(String, truncated: Bool)
}

/// Incrementally decodes bytes from the fixed Swiftty outer profile into
/// text, standard special keys, modifiers and bracketed paste.
///
/// A lone ESC is ambiguous: it is reported as Escape only after the
/// inter-byte delay passes with nothing following (`flushPending`).
/// Advanced keyboard and mouse protocols are not enabled, so their
/// sequences never arrive.
public struct InputDecoder {
  public static let defaultEscapeDelayMilliseconds = 30

  private var buffer: [UInt8] = []
  private var pasting = false
  private var pasteBytes: [UInt8] = []
  private var pasteTruncated = false
  public let maxPasteBytes: Int

  public init(maxPasteBytes: Int = MuxLimits.standard.maxPasteBytes) {
    self.maxPasteBytes = maxPasteBytes
  }

  /// Whether bytes are held waiting for the ESC delay to resolve them.
  public var hasPending: Bool { !buffer.isEmpty && !pasting }

  public mutating func feed(_ bytes: some Sequence<UInt8>) -> [DecodedInput] {
    buffer.append(contentsOf: bytes)
    return decode(final: false)
  }

  /// The ESC delay elapsed: resolve held bytes as typed.
  public mutating func flushPending() -> [DecodedInput] { decode(final: true) }

  private static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
  private static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

  private mutating func decode(final: Bool) -> [DecodedInput] {
    var out: [DecodedInput] = []
    var text: [UInt8] = []
    func flushText() {
      guard !text.isEmpty else { return }
      out.append(.text(String(decoding: text, as: UTF8.self)))
      text.removeAll()
    }
    var i = 0
    while i < buffer.count {
      if pasting {
        // Prefix bytes inside a paste stay literal.
        if let end = find(Self.pasteEnd, from: i) {
          appendPaste(buffer[i ..< end])
          i = end + Self.pasteEnd.count
          pasting = false
          out.append(
            .paste(
              String(decoding: pasteBytes, as: UTF8.self),
              truncated: pasteTruncated
            )
          )
          pasteBytes = []
          pasteTruncated = false
          continue
        }
        // Keep a possible partial terminator for the next read.
        let keep = min(Self.pasteEnd.count - 1, buffer.count - i)
        appendPaste(buffer[i ..< buffer.count - keep])
        i = buffer.count - keep
        break
      }
      let b = buffer[i]
      if b == 0x1B {
        flushText()
        switch parseEscape(at: i, final: final) {
        case .incomplete:
          buffer.removeFirst(i)
          return out
        case let .event(event, length):
          if let event { out.append(event) }
          i += length
        case .pasteStart:
          pasting = true
          i += Self.pasteStart.count
        }
        continue
      }
      if b < 0x20 || b == 0x7F {
        flushText()
        out.append(Self.control(b))
        i += 1
        continue
      }
      // UTF-8: hold an incomplete trailing sequence.
      guard let need = utf8PrefixLength(at: i, final: final) else {
        flushText()
        buffer.removeFirst(i)
        return out
      }
      text.append(contentsOf: buffer[i ..< i + need])
      i += need
    }
    flushText()
    buffer.removeFirst(min(i, buffer.count))
    return out
  }

  private mutating func appendPaste(_ bytes: ArraySlice<UInt8>) {
    let room = maxPasteBytes - pasteBytes.count
    if bytes.count > room {
      pasteBytes.append(contentsOf: bytes.prefix(max(0, room)))
      pasteTruncated = true
    } else {
      pasteBytes.append(contentsOf: bytes)
    }
  }

  private func find(_ needle: [UInt8], from start: Int) -> Int? {
    guard buffer.count - start >= needle.count else { return nil }
    var i = start
    while i + needle.count <= buffer.count {
      if buffer[i] == needle[0], Array(buffer[i ..< i + needle.count]) == needle
      {
        return i
      }
      i += 1
    }
    return nil
  }

  private enum EscapeResult {
    case incomplete
    case event(DecodedInput?, Int)
    case pasteStart
  }

  private func parseEscape(at i: Int, final: Bool) -> EscapeResult {
    let rest = buffer.count - i
    guard rest >= 2 else {
      return final ? .event(.key(.escape, []), 1) : .incomplete
    }
    let next = buffer[i + 1]
    switch next {
    case UInt8(ascii: "["):
      // CSI: parameters 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
      var j = i + 2
      while j < buffer.count, j - i <= 32, (0x20 ... 0x3F).contains(buffer[j]) {
        j += 1
      }
      // Bound the prefix even when its final byte arrived in this read.
      guard j - i <= 32 else {
        return .event(.key(.character(UInt32(UInt8(ascii: "["))), .alt), 2)
      }
      guard j < buffer.count else {
        if final {
          return .event(.key(.character(UInt32(UInt8(ascii: "["))), .alt), 2)
        }
        return .incomplete
      }
      guard (0x40 ... 0x7E).contains(buffer[j]) else {
        return .event(.key(.character(UInt32(UInt8(ascii: "["))), .alt), 2)
      }
      let params = String(decoding: buffer[(i + 2) ..< j], as: UTF8.self)
      let finalByte = buffer[j]
      let length = j - i + 1
      if finalByte == UInt8(ascii: "~"), params == "200" { return .pasteStart }
      return .event(Self.csi(params, finalByte), length)
    case UInt8(ascii: "O"):
      guard rest >= 3 else {
        return final
          ? .event(.key(.character(UInt32(UInt8(ascii: "O"))), .alt), 2)
          : .incomplete
      }
      guard (0x40 ... 0x7E).contains(buffer[i + 2]) else {
        return .event(.key(.character(UInt32(UInt8(ascii: "O"))), .alt), 2)
      }
      let key: MuxKey? =
        switch buffer[i + 2] {
        case UInt8(ascii: "A"): .up
        case UInt8(ascii: "B"): .down
        case UInt8(ascii: "C"): .right
        case UInt8(ascii: "D"): .left
        case UInt8(ascii: "H"): .home
        case UInt8(ascii: "F"): .end
        case UInt8(ascii: "P"): .function(1)
        case UInt8(ascii: "Q"): .function(2)
        case UInt8(ascii: "R"): .function(3)
        case UInt8(ascii: "S"): .function(4)
        case UInt8(ascii: "M"): .enter
        default: nil
        }
      return .event(key.map { .key($0, []) }, 3)
    case 0x1B:
      // ESC ESC: Alt+Escape.
      return .event(.key(.escape, .alt), 2)
    default:
      // Alt + key: ESC prefix (meta sends escape).
      if next < 0x20 || next == 0x7F {
        guard case let .key(k, m) = Self.control(next) else {
          return .event(nil, 2)
        }
        return .event(.key(k, m.union(.alt)), 2)
      }
      guard let need = utf8PrefixLength(at: i + 1, final: false) else {
        return final ? .event(.key(.escape, []), 1) : .incomplete
      }
      let scalars = String(
        decoding: buffer[(i + 1) ..< (i + 1 + need)],
        as: UTF8.self
      )
      .unicodeScalars
      let scalar = scalars.first.map(\.value) ?? 0x20
      return .event(.key(.character(scalar), .alt), 1 + need)
    }
  }

  static func csi(_ params: String, _ final: UInt8) -> DecodedInput? {
    let parts = params.split(separator: ";", omittingEmptySubsequences: false)
    let first = parts.first.flatMap { Int($0) }
    let modifiers = parts.count > 1 ? Self.modifiers(Int(parts[1]) ?? 1) : []
    let key: MuxKey? =
      switch final {
      case UInt8(ascii: "A"): .up
      case UInt8(ascii: "B"): .down
      case UInt8(ascii: "C"): .right
      case UInt8(ascii: "D"): .left
      case UInt8(ascii: "H"): .home
      case UInt8(ascii: "F"): .end
      case UInt8(ascii: "P"): .function(1)
      case UInt8(ascii: "Q"): .function(2)
      case UInt8(ascii: "R"): .function(3)
      case UInt8(ascii: "S"): .function(4)
      case UInt8(ascii: "Z"): .tab
      case UInt8(ascii: "~"):
        switch first {
        case 1, 7: .home
        case 2: .insert
        case 3: .delete
        case 4, 8: .end
        case 5: .pageUp
        case 6: .pageDown
        case 11: .function(1)
        case 12: .function(2)
        case 13: .function(3)
        case 14: .function(4)
        case 15: .function(5)
        case 17: .function(6)
        case 18: .function(7)
        case 19: .function(8)
        case 20: .function(9)
        case 21: .function(10)
        case 23: .function(11)
        case 24: .function(12)
        default: nil
        }
      default: nil
      }
    guard let key else { return nil }
    if final == UInt8(ascii: "Z") { return .key(.tab, modifiers.union(.shift)) }
    return .key(key, modifiers)
  }

  /// xterm modifier parameter: 1 + (shift 1 | alt 2 | ctrl 4).
  static func modifiers(_ parameter: Int) -> MuxKeyModifiers {
    guard parameter > 1 else { return [] }
    let bits = parameter - 1
    var m: MuxKeyModifiers = []
    if bits & 1 != 0 { m.insert(.shift) }
    if bits & 2 != 0 { m.insert(.alt) }
    if bits & 4 != 0 { m.insert(.control) }
    return m
  }

  static func control(_ b: UInt8) -> DecodedInput {
    switch b {
    case 0x0D: .key(.enter, [])
    case 0x09: .key(.tab, [])
    case 0x7F: .key(.backspace, [])
    case 0x08: .key(.backspace, .control)
    case 0x1B: .key(.escape, [])
    case 0x00: .key(.character(UInt32(UInt8(ascii: " "))), .control)
    case 0x1C ... 0x1F: .key(.character(UInt32(b) + 0x40), .control)
    default: .key(.character(UInt32(b) + 0x60), .control)  // 0x01 → 'a'
    }
  }

  /// Consume a scalar or its malformed prefix, leaving the first unrelated
  /// byte for normal key decoding. Only a still-valid partial scalar waits.
  private func utf8PrefixLength(at start: Int, final: Bool) -> Int? {
    let lead = buffer[start]
    let length: Int
    switch lead {
    case 0xC2 ... 0xDF: length = 2
    case 0xE0 ... 0xEF: length = 3
    case 0xF0 ... 0xF4: length = 4
    default: return 1
    }
    for offset in 1 ..< length {
      guard start + offset < buffer.count else { return final ? offset : nil }
      let range: ClosedRange<UInt8>
      if offset == 1 {
        range =
          switch lead {
          case 0xE0: 0xA0 ... 0xBF
          case 0xED: 0x80 ... 0x9F
          case 0xF0: 0x90 ... 0xBF
          case 0xF4: 0x80 ... 0x8F
          default: 0x80 ... 0xBF
          }
      } else {
        range = 0x80 ... 0xBF
      }
      guard range.contains(buffer[start + offset]) else { return offset }
    }
    return length
  }
}
