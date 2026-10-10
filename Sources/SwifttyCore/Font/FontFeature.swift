import Foundation

/// A Ghostty/CSS feature setting. Invalid settings are ignored by callers.
struct FontFeature {
  let tag: String
  let value: UInt32

  init?(_ raw: String) {
    var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    var defaultValue: UInt32 = 1
    if rest.first == "+" || rest.first == "-" {
      defaultValue = rest.first == "-" ? 0 : 1
      rest.removeFirst()
    }
    let tag: Substring
    if let quote = rest.first, quote == "\"" || quote == "'" {
      rest.removeFirst()
      guard let end = rest.firstIndex(of: quote) else { return nil }
      tag = rest[..<end]
      rest = rest[rest.index(after: end)...]
    } else {
      let end =
        rest.firstIndex { $0.isWhitespace || $0 == "=" } ?? rest.endIndex
      tag = rest[..<end]
      rest = rest[end...]
    }
    guard tag.utf8.count == 4,
      tag.utf8.allSatisfy({ (0x20 ... 0x7E).contains($0) })
    else { return nil }
    rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    let hasEquals = rest.first == "="
    if hasEquals {
      rest =
        rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)[...]
    }
    switch rest {
    case "" where !hasEquals: value = defaultValue
    case "on": value = 1
    case "off": value = 0
    default:
      guard !rest.isEmpty,
        rest.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
        let number = UInt32(rest)
      else { return nil }
      value = number
    }
    self.tag = String(tag)
  }
}
