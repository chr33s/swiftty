import Foundation

/// A byte offset in the original UTF-8 input, before sanitization.
struct SourceFailure: Error {
  var offset: Int
  var message: String
}

public enum JSONCSanitizer {
  /// Comments and trailing commas become ASCII spaces. Every UTF-8 byte,
  /// CR and LF retains its original offset; string contents are untouched.
  /// An unterminated block comment leaves the source unchanged, so a strict
  /// JSON decoder cannot silently accept an incomplete configuration.
  public static func sanitize(_ source: String) -> Data {
    (try? sanitizeChecked(source)) ?? Data(source.utf8)
  }

  static func sanitizeChecked(_ source: String) throws -> Data {
    var bytes = Array(source.utf8)
    var index = 0
    var comma: Int?
    while index < bytes.count {
      switch bytes[index] {
      case 34:
        comma = nil
        index += 1
        while index < bytes.count {
          let byte = bytes[index]
          index += 1
          if byte == 92 {
            index = min(index + 1, bytes.count)
          } else if byte == 34 {
            break
          }
        }
      case 47 where index + 1 < bytes.count && bytes[index + 1] == 47:
        while index < bytes.count && bytes[index] != 10 && bytes[index] != 13 {
          bytes[index] = 32
          index += 1
        }
      case 47 where index + 1 < bytes.count && bytes[index + 1] == 42:
        let start = index
        bytes[index] = 32
        bytes[index + 1] = 32
        index += 2
        var closed = false
        while index < bytes.count {
          if bytes[index] == 42 && index + 1 < bytes.count
            && bytes[index + 1] == 47
          {
            bytes[index] = 32
            bytes[index + 1] = 32
            index += 2
            closed = true
            break
          }
          if bytes[index] != 10 && bytes[index] != 13 { bytes[index] = 32 }
          index += 1
        }
        if !closed {
          throw SourceFailure(
            offset: start,
            message: "Unterminated block comment"
          )
        }
      case 44:
        var previous = index - 1
        while previous >= 0 && [9, 10, 13, 32].contains(bytes[previous]) {
          previous -= 1
        }
        comma =
          previous >= 0 && ![44, 58, 91, 123].contains(bytes[previous])
          ? index : nil
        index += 1
      case 93, 125:
        if let comma { bytes[comma] = 32 }
        comma = nil
        index += 1
      case 9, 10, 13, 32: index += 1
      default:
        comma = nil
        index += 1
      }
    }
    return Data(bytes)
  }
}
