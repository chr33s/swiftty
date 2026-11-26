import CryptoKit

/// SHA-256 of the body before the final `:mac=`, one `:`, and the token.
/// Not an HMAC. The hex is 64 lowercase characters.
enum ProgramResumeMAC {
  static func hex(prefix: [UInt8], token: String) -> String {
    var input = prefix
    input.append(0x3A)
    input.append(contentsOf: token.utf8)
    let digest = SHA256.hash(data: input)
    var characters: [UInt8] = []
    characters.reserveCapacity(64)
    let digits = Array("0123456789abcdef".utf8)
    for byte in digest {
      characters.append(digits[Int(byte >> 4)])
      characters.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: characters, as: UTF8.self)
  }
}

/// OSC 7577 decision order: ignore a bad MAC, a missing time, or a time
/// outside the window before any other field. A report that authenticates
/// and then fails validation is rejected, which removes that pid's record.
enum ProgramResumeParse {
  /// Whole sequence, `ESC ]` through the terminator.
  static let maxSequenceBytes = 8192
  /// Parser buffer bound. BEL is one byte and ST is two, so a body of this
  /// length is checked again with the real terminator.
  static let maxBodyBytes = maxSequenceBytes - 3
  static let maxArgv = 64
  /// Matches `SavedPaneLaunch.commandLimit` (4 KiB, one byte per element).
  static let commandLimit = 4096
  static let timeWindow: Int64 = 60

  enum Decision: Equatable {
    case ignore
    case reject(pid: Int32?)
    case accept(ProgramResumeReport)
    case clear(pid: Int32, time: Int64)
  }

  static func decide(
    body: [UInt8],
    sequenceBytes: Int,
    token: String?,
    now: Int64,
    lastAccepted: [Int32: Int64]
  ) -> Decision {
    if body == [0x3F] || body.isEmpty { return .ignore }
    if sequenceBytes > maxSequenceBytes { return .ignore }
    guard let token, validToken(token) else { return .ignore }
    guard let prefix = authenticatedPrefix(body, token: token) else {
      return .ignore
    }
    let pairs = splitPairs(prefix)
    guard let time = firstTime(pairs), !exceedsWindow(time, now: now) else {
      return .ignore
    }
    let pid = firstPid(pairs)
    if let pid, let previous = lastAccepted[pid], time < previous {
      return .ignore
    }
    return strict(pairs, time: time, pid: pid)
  }

  /// The bytes before the final `:mac=`, when the hash matches.
  private static func authenticatedPrefix(
    _ body: [UInt8],
    token: String
  ) -> [UInt8]? {
    let marker = Array(":mac=".utf8)
    guard body.count >= marker.count + 64 else { return nil }
    let macStart = body.count - 64
    let markerStart = macStart - marker.count
    guard body[markerStart ..< macStart].elementsEqual(marker) else {
      return nil
    }
    let mac = body[macStart...]
    guard mac.allSatisfy(isHex) else { return nil }
    let prefix = Array(body[..<markerStart])
    let digest = ProgramResumeMAC.hex(prefix: prefix, token: token)
    guard constantTimeEqual(mac, digest.utf8) else { return nil }
    return prefix
  }

  private static func constantTimeEqual(
    _ a: ArraySlice<UInt8>,
    _ b: String.UTF8View
  ) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
  }

  private struct Pair {
    var key: [UInt8]
    var value: [UInt8]
    var wellFormed: Bool
  }

  private static func strict(
    _ pairs: [Pair],
    time: Int64,
    pid: Int32?
  ) -> Decision {
    var seen: Set<[UInt8]> = []
    var values: [String: [UInt8]] = [:]
    for pair in pairs {
      guard pair.wellFormed, seen.insert(pair.key).inserted else {
        return .reject(pid: pid)
      }
      if keyIs(pair.key, "mac") { return .reject(pid: pid) }
      if known(pair.key) {
        values[String(decoding: pair.key, as: UTF8.self)] = pair.value
      }
    }
    guard let pid else { return .reject(pid: nil) }
    if let need = values["need"], !needIsImplemented(need) {
      return .reject(pid: pid)
    }
    let argv = values["argv"]
    let clear = values["clear"]
    guard (argv == nil) != (clear == nil) else { return .reject(pid: pid) }
    if let clear {
      guard clear.elementsEqual("1".utf8) else { return .reject(pid: pid) }
      return .clear(pid: pid, time: time)
    }
    guard let decoded = decodeArgv(argv ?? []),
      let directory = decodeDirectory(values["cwd"])
    else { return .reject(pid: pid) }
    return .accept(
      ProgramResumeReport(
        pid: pid,
        argv: decoded,
        workingDirectory: directory,
        time: time
      )
    )
  }

  private static func firstTime(_ pairs: [Pair]) -> Int64? {
    for pair in pairs where keyIs(pair.key, "time") {
      return canonical(pair.value)
    }
    return nil
  }

  private static func firstPid(_ pairs: [Pair]) -> Int32? {
    for pair in pairs where keyIs(pair.key, "pid") {
      guard let value = canonical(pair.value) else { return nil }
      return Int32(exactly: value)
    }
    return nil
  }

  private static func splitPairs(_ prefix: [UInt8]) -> [Pair] {
    guard !prefix.isEmpty else { return [] }
    var pairs: [Pair] = []
    var start = 0
    for index in prefix.indices where prefix[index] == 0x3A {
      pairs.append(pair(prefix[start ..< index]))
      start = index + 1
    }
    pairs.append(pair(prefix[start...]))
    return pairs
  }

  private static func pair(_ segment: ArraySlice<UInt8>) -> Pair {
    guard let eq = segment.firstIndex(of: 0x3D) else {
      return Pair(key: Array(segment), value: [], wellFormed: false)
    }
    let key = Array(segment[..<eq])
    let value = Array(segment[segment.index(after: eq)...])
    let keyOK = !key.isEmpty && key.allSatisfy(isKeyByte)
    let valueOK = value.allSatisfy(ProgramStatusCommand.isValueByte)
    return Pair(key: key, value: value, wellFormed: keyOK && valueOK)
  }

  private static func decodeArgv(_ value: [UInt8]) -> [String]? {
    guard !value.isEmpty else { return nil }
    let parts = value.split(separator: 0x2C, omittingEmptySubsequences: false)
    guard (1 ... maxArgv).contains(parts.count) else { return nil }
    var argv: [String] = []
    argv.reserveCapacity(parts.count)
    for (index, part) in parts.enumerated() {
      guard let bytes = ProgramStatusCommand.base64Decode(part),
        let decoded = clean(bytes), index > 0 || validProgram(decoded)
      else { return nil }
      argv.append(decoded)
    }
    let bytes = argv.reduce(0) { $0 + $1.utf8.count + 1 }
    guard bytes <= commandLimit else { return nil }
    return argv
  }

  /// `.some(nil)` means `cwd` was absent. Nil means the value failed
  /// validation and the report is rejected.
  private static func decodeDirectory(_ value: [UInt8]?) -> String?? {
    guard let value else { return .some(nil) }
    guard !value.isEmpty else { return nil }
    guard let bytes = ProgramStatusCommand.base64Decode(value),
      let decoded = clean(bytes), decoded.utf8.count <= commandLimit,
      decoded.hasPrefix("/")
    else { return nil }
    return .some(decoded)
  }

  private static func needIsImplemented(_ value: [UInt8]) -> Bool {
    if value.isEmpty { return true }
    let names = value.split(separator: 0x2C, omittingEmptySubsequences: false)
    for name in names {
      let bytes = Array(name)
      guard !bytes.isEmpty, bytes.allSatisfy(isKeyByte), known(bytes) else {
        return false
      }
    }
    return true
  }

  private static func validProgram(_ name: String) -> Bool {
    if name == "." || name == ".." { return false }
    if name.hasPrefix("/") { return true }
    return !name.isEmpty && !name.hasPrefix("-") && !name.contains("/")
  }

  private static func clean(_ bytes: [UInt8]) -> String? {
    guard let text = String(validating: bytes, as: UTF8.self) else {
      return nil
    }
    for scalar in text.unicodeScalars
    where scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) {
      return nil
    }
    return text
  }

  private static func canonical(_ value: [UInt8]) -> Int64? {
    guard let first = value.first, (0x31 ... 0x39).contains(first) else {
      return nil
    }
    guard value.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return nil }
    var number: Int64 = 0
    for byte in value {
      let digit = Int64(byte - 0x30)
      let (scaled, scaleOverflow) = number.multipliedReportingOverflow(by: 10)
      let (sum, sumOverflow) = scaled.addingReportingOverflow(digit)
      if scaleOverflow || sumOverflow { return nil }
      number = sum
    }
    return number
  }

  private static func exceedsWindow(_ time: Int64, now: Int64) -> Bool {
    let (delta, overflow) = time.subtractingReportingOverflow(now)
    if overflow || delta == Int64.min { return true }
    let distance = delta < 0 ? -delta : delta
    return distance > timeWindow
  }

  private static func validToken(_ token: String) -> Bool {
    let count = token.utf8.count
    guard (22 ... 64).contains(count) else { return false }
    return token.utf8.allSatisfy { byte in
      byte &- 0x30 < 10 || (byte | 0x20) &- 0x61 < 26 || byte == 0x2D
        || byte == 0x5F
    }
  }

  private static func known(_ key: [UInt8]) -> Bool {
    keyIs(key, "pid") || keyIs(key, "time") || keyIs(key, "argv")
      || keyIs(key, "cwd") || keyIs(key, "clear") || keyIs(key, "need")
      || keyIs(key, "mac")
  }

  private static func keyIs(_ key: [UInt8], _ name: String) -> Bool {
    key.elementsEqual(name.utf8)
  }

  private static func isKeyByte(_ byte: UInt8) -> Bool { byte &- 0x61 < 26 }

  private static func isHex(_ byte: UInt8) -> Bool {
    byte &- 0x30 < 10 || byte &- 0x61 < 6
  }
}
