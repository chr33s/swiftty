/// OSC 7501 program status: what a program reports about itself
/// (`working`, `blocked` on a question, `done`), keyed by a hierarchical id.
///
/// ```text
/// ESC ] 7501 ; ? ST                          support query
/// ESC ] 7501 ; key=value:key=value... ST     report
/// ```
///
/// Keys: `state` (required), `id`, `progress`, `kind`, `app`, and the
/// base64-encoded UTF-8 `title` and `msg`. Reports are validated as a whole:
/// an invalid or over-limit report is discarded, never partially applied.
/// Malformed pairs are skipped, but an `id` outside its grammar discards
/// the report (the protocol's id rule), even when the pair is also
/// malformed: an invalid child id must never turn into the root (for
/// `clear`, every record).
///
/// Protocol: https://www.superlogical.com/rex/docs/build/program-status
///
/// `title` and `message` are untrusted program text. Swiftty guarantees
/// valid UTF-8 without C0, DEL or C1 controls, but passes other format
/// characters through: embedders showing them in trusted UI must strip or
/// isolate bidirectional controls (U+200E/F, U+202A–202E, U+2066–2069) and
/// must not interpret the text as markup.
public enum ProgramStatusState: Sendable, Equatable {
  case idle
  case working
  case done
  case blocked
  case error
}

/// Why a `blocked` program is waiting.
public enum ProgramStatusBlockedKind: Sendable, Equatable {
  case permission
  case question
  case auth
}

public struct ProgramStatusRecord: Sendable, Equatable, Identifiable {
  /// Slash-separated path; the empty string is the root record.
  public let id: String
  public let state: ProgramStatusState
  /// Only for `blocked`.
  public let kind: ProgramStatusBlockedKind?
  /// 0...100; only for `working` and `blocked`.
  public let progress: UInt8?
  public let app: String?
  public let title: String?
  public let message: String?
  /// Store revision at which this record was last written.
  public let revision: UInt64

  public init(
    id: String,
    state: ProgramStatusState,
    kind: ProgramStatusBlockedKind? = nil,
    progress: UInt8? = nil,
    app: String? = nil,
    title: String? = nil,
    message: String? = nil,
    revision: UInt64 = 0,
  ) {
    self.id = id
    self.state = state
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
    self.revision = revision
  }

  func with(revision: UInt64) -> Self {
    Self(
      id: id,
      state: state,
      kind: kind,
      progress: progress,
      app: app,
      title: title,
      message: message,
      revision: revision
    )
  }
}

/// Every record, least recently updated first.
public struct ProgramStatusSnapshot: Sendable, Equatable {
  public let records: [ProgramStatusRecord]
  public let revision: UInt64

  public init(records: [ProgramStatusRecord] = [], revision: UInt64 = 0) {
    self.records = records
    self.revision = revision
  }

  public static let empty = Self()

  /// The record with `id` (`""` for the root).
  public subscript(id: String) -> ProgramStatusRecord? {
    records.first { $0.id == id }
  }

  /// The record's `app`, or that of its nearest ancestor with one (the
  /// root last): `build/test` inherits from `build`, then the root.
  public func app(for id: String) -> String? {
    var path = Substring(id)
    while true {
      if let app = self[String(path)]?.app { return app }
      if path.isEmpty { return nil }
      path = path.lastIndex(of: "/").map { path[..<$0] } ?? ""
    }
  }
}

/// A validated OSC 7501 sequence.
enum ProgramStatusCommand: Equatable {
  case query
  /// Replace the record `record.id` (revision unset).
  case report(ProgramStatusRecord)
  /// Remove `id` and its descendants; nil removes everything.
  case clear(id: String?)
}

extension ProgramStatusCommand {
  /// Longest whole sequence, `ESC ]` through the terminator.
  static let maxSequenceBytes = 4096
  /// Longest OSC body (`7501;…`) the parser captures: the whole-sequence
  /// limit less `ESC ]` and the shortest terminator (BEL).
  static let maxBodyBytes = maxSequenceBytes - 3
  static let maxKeyBytes = 16
  static let maxIDBytes = 128
  static let maxIDSegmentBytes = 32
  static let maxIDDepth = 8
  static let maxAppBytes = 32
  static let maxTitleEncodedBytes = 256
  static let maxTitleBytes = 192
  static let maxMessageEncodedBytes = 2732
  static let maxMessageBytes = 2048

  /// Parses the data after `7501;`, terminated by `terminatorBytes`
  /// (1 for BEL, 2 for ST); nil when the sequence must be discarded.
  init?(_ data: UnsafeBufferPointer<UInt8>, terminatorBytes: Int = 2) {
    guard 2 + 5 + data.count + terminatorBytes <= Self.maxSequenceBytes else {
      return nil
    }
    if data.count == 1, data[0] == 0x3F {  // ?
      self = .query
      return
    }
    var state: Substring?
    var id: String?
    var progress: Substring?
    var kind: Substring?
    var app: String?
    var title: String?
    var message: String?
    // Pairs are `:`-separated; a value may contain `=` (base64 padding).
    for pair in Substring(decoding: data, as: UTF8.self).utf8
      .split(separator: 0x3A, omittingEmptySubsequences: true)
    {
      // Malformed pairs (no `=`, a key outside `[a-z]+`, a value byte
      // outside `[A-Za-z0-9_.,+/=-]`) are skipped, except `id`, whose
      // grammar decides the whole report.
      guard let eq = pair.firstIndex(of: 0x3D), eq != pair.startIndex,
        pair[..<eq].allSatisfy({ $0 &- 0x61 < 26 })
      else { continue }
      let key = Substring(pair[..<eq])
      let value = Substring(pair[pair.index(after: eq)...])
      guard key.utf8.count <= Self.maxKeyBytes else { return nil }
      guard key == "id" || value.utf8.allSatisfy(Self.isValueByte) else {
        continue
      }
      switch key {
      case "state": state = value
      case "id":
        guard let valid = Self.validID(value) else { return nil }
        id = valid
      case "progress": progress = value
      case "kind": kind = value
      case "app":
        guard value.utf8.count <= Self.maxAppBytes else { return nil }
        // Outside the character set: absent, the report still applies.
        app =
          !value.isEmpty && value.utf8.allSatisfy(Self.isNameByte)
          ? String(value) : nil
      case "title":
        guard
          let text = Self.text(
            value,
            encoded: Self.maxTitleEncodedBytes,
            decoded: Self.maxTitleBytes
          )
        else { return nil }
        title = text
      case "msg":
        guard
          let text = Self.text(
            value,
            encoded: Self.maxMessageEncodedBytes,
            decoded: Self.maxMessageBytes
          )
        else { return nil }
        message = text
      default: break  // unknown keys are ignored
      }
    }
    let parsed: ProgramStatusState
    switch state {
    case "idle"?: parsed = .idle
    case "working"?: parsed = .working
    case "done"?: parsed = .done
    case "blocked"?: parsed = .blocked
    case "error"?: parsed = .error
    case "clear"?:
      self = .clear(id: id)
      return
    default: return nil
    }
    var percent: UInt8?
    if parsed == .working || parsed == .blocked, let progress,
      (1 ... 3).contains(progress.utf8.count),
      progress.utf8.allSatisfy({ $0 &- 0x30 < 10 }), let v = UInt8(progress),
      v <= 100
    {
      percent = v
    }
    let blockedKind: ProgramStatusBlockedKind? =
      switch parsed == .blocked ? kind : nil {
      case "permission"?: .permission
      case "question"?: .question
      case "auth"?: .auth
      default: nil
      }
    self = .report(
      ProgramStatusRecord(
        id: id ?? "",
        state: parsed,
        kind: blockedKind,
        progress: percent,
        app: app,
        title: title,
        message: message,
      )
    )
  }

  /// `[A-Za-z0-9_.,+/=-]`: any value.
  static func isValueByte(_ b: UInt8) -> Bool {
    isNameByte(b) || b == 0x2C || b == 0x2F || b == 0x3D
  }

  /// `[A-Za-z0-9_.+-]`: id segments and `app`.
  static func isNameByte(_ b: UInt8) -> Bool {
    b &- 0x30 < 10 || (b | 0x20) &- 0x61 < 26 || b == 0x2E || b == 0x2D
      || b == 0x5F || b == 0x2B
  }

  /// `segment(/segment)*`, segments of `[A-Za-z0-9_.+-]`; an empty
  /// string or empty segment is invalid (never the root).
  static func validID(_ value: Substring) -> String? {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maxIDBytes else { return nil }
    var depth = 1
    var segment = 0
    for b in bytes {
      if b == 0x2F {  // /
        guard segment > 0 else { return nil }
        depth += 1
        segment = 0
        continue
      }
      guard isNameByte(b) else { return nil }
      segment += 1
      guard segment <= maxIDSegmentBytes else { return nil }
    }
    guard segment > 0, depth <= maxIDDepth else { return nil }
    return String(value)
  }

  /// Base64 (padded or not) decoding to UTF-8 without control
  /// characters. An empty value means absent; nil means invalid.
  static func text(_ value: Substring, encoded: Int, decoded: Int) -> String?? {
    guard value.utf8.count <= encoded else { return nil }
    guard !value.isEmpty else { return .some(nil) }
    guard let bytes = base64Decode(value.utf8), bytes.count <= decoded,
      let s = String(validating: bytes, as: UTF8.self)
    else { return nil }
    for scalar in s.unicodeScalars
    where scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) {
      return nil
    }
    return .some(s)
  }

  /// Standard-alphabet base64: optional `=` padding only at the end, no
  /// whitespace. Leftover bits of the last character are ignored.
  static func base64Decode(_ input: Substring.UTF8View) -> [UInt8]? {
    var body = input[...]
    var padding = 0
    while body.last == 0x3D, padding < 2 {
      body = body.dropLast()
      padding += 1
    }
    if padding > 0, input.count % 4 != 0 { return nil }
    guard body.count % 4 != 1 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(body.count * 3 / 4)
    var acc: UInt32 = 0
    var bits = 0
    for c in body {
      let v: UInt32
      switch c {
      case 0x41 ... 0x5A: v = UInt32(c - 0x41)
      case 0x61 ... 0x7A: v = UInt32(c - 0x61 + 26)
      case 0x30 ... 0x39: v = UInt32(c - 0x30 + 52)
      case 0x2B: v = 62
      case 0x2F: v = 63
      default: return nil
      }
      acc = acc << 6 | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
      }
    }
    return out
  }
}
