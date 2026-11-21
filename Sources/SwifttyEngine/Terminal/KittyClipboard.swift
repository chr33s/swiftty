/// Kitty clipboard protocol (OSC 5522) values and the state behind them,
/// ported from Ghostty, which follows kitty's reference implementation
/// (kitty/clipboard.py) where it and the prose specification disagree:
///
/// - Malformed metadata, and a missing or unknown `type`, drop the packet
///   silently.
/// - Payloads and the `mime`, `name` and `pw` values are strict RFC 4648
///   base64. An invalid `wdata` or `walias` aborts an in-flight write
///   with EINVAL; an invalid `read` is dropped, since reads have no error.
/// - One MIME type's `wdata` payloads form one base64 stream split at any
///   boundary. A packet ending at terminal padding restarts the stream.
/// - `id` keeps only `[a-zA-Z0-9-_+.]`, truncated to 512 bytes.
/// - A `type=write` replaces any in-flight transaction; a commit with
///   none is ignored.
///
/// Specification: https://sw.kovidgoyal.net/kitty/clipboard/
public enum KittyClipboard {
  public struct Content: Sendable, Equatable {
    public var mime: String
    public var data: [UInt8]
    public init(mime: String, data: [UInt8]) {
      self.mime = mime
      self.data = data
    }
  }

  /// A read the host serves synchronously.
  public struct ReadRequest: Sendable, Equatable {
    public var primary: Bool
    /// Data types requested, at most `maxReadMimes`, in request order.
    public var mimes: [String]
    /// Whether the targets (`.`) listing was requested.
    public var list: Bool
    /// The requesting program's name, for permission prompts.
    public var name: String
    /// A remembered password grants this read; it remains advisory.
    public var granted: Bool
    /// Whether a success may ask to remember the password.
    public var canRemember: Bool
    /// Identifies a deferred read to `completeKittyClipboardRead`.
    public var token: UInt64 = 0
  }

  public enum ReadResult: Sendable, Equatable {
    /// `available` is reported only for listings; contents not requested
    /// are never served.
    case success(available: [String], contents: [Content], remember: Bool)
    case denied, unsupported, busy, ioError
    /// Answered later through `TerminalState.completeKittyClipboardRead`,
    /// for example after a permission prompt.
    case deferred
  }

  /// A read waiting for its deferred answer.
  struct PendingRead {
    var token: UInt64
    var primary: Bool
    var id: [UInt8]
    var pw: [UInt8]
    var mimes: [String]
    var list: Bool
    var terminator: String
  }

  static let maxPendingReads = 4

  /// A committed write the host applies synchronously.
  public struct WriteRequest: Sendable, Equatable {
    public var primary: Bool
    public var contents: [Content]
    public var name: String
    public var granted: Bool
    public var canRemember: Bool
    /// Identifies a deferred write to `completeKittyClipboardWrite`.
    public var token: UInt64 = 0
  }

  public enum WriteResult: Sendable, Equatable {
    case success(remember: Bool)
    case denied, unsupported, busy, invalidData, ioError
    /// Answered later through `TerminalState.completeKittyClipboardWrite`.
    case deferred
  }

  /// A committed write waiting for its deferred answer.
  struct PendingWrite {
    var token: UInt64
    var id: [UInt8]
    var pw: [UInt8]
    var terminator: String
  }

  /// A nil result is a denial: the program is waiting for an answer.
  public typealias Reader = @Sendable (ReadRequest) -> ReadResult?
  public typealias Writer = @Sendable (WriteRequest) -> WriteResult?

  public static let maxWriteBytes = 64 << 20
  static let maxWriteMimes = 64
  static let maxWriteAliases = 64
  /// Requested data types served by one read; the rest are not served,
  /// which is how the protocol reports an unavailable type anyway.
  public static let maxReadMimes = 4
  /// Raw bytes per DATA packet.
  static let readChunkSize = 4096
  static let maxListingMimes = 16
  static let maxIDLength = 512
  static let maxPasswordLength = 128
  static let maxMimeLength = 256
  static let maxNameLength = 256
  static let maxGrants = 32
  static let passwordLength = 22
  static let passwordAlphabet = Array(
    "23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".utf8
  )

  enum Operation: String { case read, walias, wdata, write }

  enum Status: String {
    case DATA, DONE, EBUSY, EFBIG, EINVAL, EIO, ENOSYS, EPERM, OK
  }

  // MARK: Requests

  struct InvalidValue: Error {}

  /// Decoded metadata of one packet.
  struct Metadata {
    var op: Operation
    var primary = false
    var id: [UInt8] = []
    var mime = ""
    var pw: [UInt8] = []
    var name = ""

    /// Raw fields; nil drops the packet. Every record needs `=` (so empty
    /// metadata is malformed) and the last duplicate wins.
    private static func fields(
      _ raw: ArraySlice<UInt8>
    ) -> [String: ArraySlice<UInt8>]? {
      var result: [String: ArraySlice<UInt8>] = [:]
      for record in raw.split(separator: 0x3A, omittingEmptySubsequences: false)
      {
        guard let equals = record.firstIndex(of: 0x3D) else { return nil }
        let key = String(decoding: record[..<equals], as: UTF8.self)
        switch key {
        case "type", "loc", "id", "mime", "pw", "name":
          result[key] = record[(equals + 1)...]
        default: break  // unknown keys are ignored
        }
      }
      return result
    }

    /// The operation of well-formed metadata, without decoding values.
    static func operation(_ raw: ArraySlice<UInt8>) -> Operation? {
      fields(raw)?["type"]
        .flatMap { Operation(rawValue: String(decoding: $0, as: UTF8.self)) }
    }

    /// Nil drops the packet; `InvalidValue` reports a value that is not
    /// base64 UTF-8 or exceeds a limit.
    static func parse(_ raw: ArraySlice<UInt8>) throws(InvalidValue) -> Self? {
      guard let fields = fields(raw),
        let op = fields["type"]
          .flatMap({ Operation(rawValue: String(decoding: $0, as: UTF8.self)) })
      else { return nil }
      var result = Metadata(op: op)
      result.primary =
        fields["loc"].map { $0.elementsEqual("primary".utf8) } ?? false
      for c in fields["id"] ?? [] where result.id.count < maxIDLength {
        switch c {
        case 0x61 ... 0x7A, 0x41 ... 0x5A, 0x30 ... 0x39, 0x2D, 0x5F, 0x2B,
          0x2E:
          result.id.append(c)
        default: continue
        }
      }
      result.mime = try text(fields["mime"], limit: maxMimeLength) ?? ""
      // An over-long password can never match a grant: treat it as absent.
      do {
        result.pw = Array(
          (try text(fields["pw"], limit: maxPasswordLength) ?? "").utf8
        )
      } catch { result.pw = [] }
      result.name = try text(fields["name"], limit: maxNameLength) ?? ""
      return result
    }

    private static func text(
      _ value: ArraySlice<UInt8>?,
      limit: Int
    ) throws(InvalidValue) -> String? {
      guard let value, !value.isEmpty else { return nil }
      guard value.count <= (limit + 2) / 3 * 4,
        let decoded = Base64.decode(value),
        let string = String(validating: decoded, as: UTF8.self),
        decoded.count <= limit
      else { throw InvalidValue() }
      return string
    }
  }

  /// Whitespace-separated types, like Python's `str.split()`.
  static func mimeList(_ text: String) -> [String] {
    text.split(whereSeparator: { " \t\n\r\u{0B}\u{0C}".contains($0) })
      .map(String.init)
  }

  // MARK: Grants

  /// Passwords whose requests skip the host's permission prompt.
  struct Grants {
    enum Direction { case read, write }

    private struct Entry {
      var pw: [UInt8]
      var read = false
      var write = false
      var oneTime: Bool
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    /// A grant for an existing password gains the new direction.
    mutating func grant(_ pw: [UInt8], _ direction: Direction, oneTime: Bool) {
      guard !pw.isEmpty, pw.count <= maxPasswordLength else { return }
      let index: Int
      if let i = entries.firstIndex(where: { $0.pw == pw }) {
        entries[i].oneTime = entries[i].oneTime && oneTime
        index = i
      } else {
        if entries.count >= maxGrants { entries.removeFirst() }
        entries.append(Entry(pw: pw, oneTime: oneTime))
        index = entries.count - 1
      }
      switch direction {
      case .read: entries[index].read = true
      case .write: entries[index].write = true
      }
    }

    package func checkpoint(into w: inout CheckpointWriter) {
      w.int(entries.count)
      for entry in entries {
        w.data(entry.pw)
        w.bool(entry.read)
        w.bool(entry.write)
        w.bool(entry.oneTime)
      }
    }

    package mutating func restore(
      from r: inout CheckpointReader
    ) throws(CheckpointError) {
      let count = try r.count(max: maxGrants, minimumSize: 11)
      var restored: [Entry] = []
      for _ in 0 ..< count {
        let pw = try r.data(max: maxPasswordLength)
        var entry = Entry(pw: pw, oneTime: false)
        entry.read = try r.bool()
        entry.write = try r.bool()
        entry.oneTime = try r.bool()
        restored.append(entry)
      }
      entries = restored
    }

    /// A one-time grant is consumed by any check, as kitty pops it.
    mutating func use(_ pw: [UInt8], _ direction: Direction) -> Bool {
      guard !pw.isEmpty, let i = entries.firstIndex(where: { $0.pw == pw })
      else { return false }
      let entry = entries[i]
      if entry.oneTime { entries.remove(at: i) }
      return direction == .read ? entry.read : entry.write
    }
  }

  /// A one-time password for a paste event.
  static func oneTimePassword() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0 ..< passwordLength)
      .map { _ in passwordAlphabet.randomElement(using: &generator)! }
  }

  // MARK: Write transactions

  enum WriteFailure: Error { case invalid, tooLarge }

  /// One `type=write` with its `wdata` and `walias` packets until commit.
  struct WriteTransaction {
    var primary: Bool
    var id: [UInt8]
    var pw: [UInt8]
    var name: String
    /// Captured at the start so a limit change spares this transaction.
    var maxBytes: Int
    private var spool: [UInt8] = []
    private var entries: [(mime: String, start: Int, count: Int)] = []
    private var aliases: [(alias: String, target: String)] = []
    private var current: Int?
    private var decoder = Base64.Stream()

    init(_ meta: Metadata, maxBytes: Int) {
      primary = meta.primary
      id = meta.id
      pw = meta.pw
      name = meta.name
      self.maxBytes = maxBytes
    }

    /// Accumulates a chunk for `mime` (non-empty: empty commits).
    mutating func data(
      mime: String,
      payload: ArraySlice<UInt8>
    ) throws(WriteFailure) {
      if current.map({ entries[$0].mime }) != mime {
        if let index = current {
          // The previous type's stream must end on a complete group.
          guard decoder.finish() else { throw .invalid }
          entries[index].count = spool.count - entries[index].start
        }
        if let index = entries.firstIndex(where: { $0.mime == mime }) {
          // Reusing a type starts a fresh region in its place.
          entries[index].start = spool.count
          entries[index].count = 0
          current = index
        } else if entries.count >= maxWriteMimes {
          current = nil
          return
        } else {
          entries.append((mime, spool.count, 0))
          current = entries.count - 1
        }
      }
      guard let decoded = decoder.feed(payload) else { throw .invalid }
      // Over the limit the whole write fails: partial contents never
      // reach the host.
      guard decoded.count <= max(0, maxBytes - spool.count) else {
        throw .tooLarge
      }
      spool += decoded
    }

    /// Registers whitespace-separated aliases (base64) of `target`.
    mutating func alias(
      target: String,
      payload: ArraySlice<UInt8>
    ) throws(WriteFailure) {
      guard let decoded = Base64.decode(payload),
        let text = String(validating: decoded, as: UTF8.self)
      else { throw .invalid }
      for name in mimeList(text) where name.utf8.count <= maxMimeLength {
        if let i = aliases.firstIndex(where: { $0.alias == name }) {
          aliases[i].target = target
        } else if aliases.count >= maxWriteAliases {
          return
        } else {
          aliases.append((name, target))
        }
      }
    }

    /// Entries in arrival order, then aliases applied in order so chains
    /// resolve; an alias of an unmapped type is dropped.
    mutating func commit() throws(WriteFailure) -> [Content] {
      if let index = current {
        guard decoder.finish() else { throw .invalid }
        entries[index].count = spool.count - entries[index].start
        current = nil
      }
      var contents = entries.map {
        Content(
          mime: $0.mime,
          data: Array(spool[$0.start ..< $0.start + $0.count])
        )
      }
      for (alias, target) in aliases {
        guard let data = contents.first(where: { $0.mime == target })?.data
        else { continue }
        if let i = contents.firstIndex(where: { $0.mime == alias }) {
          contents[i].data = data
        } else {
          contents.append(Content(mime: alias, data: data))
        }
      }
      return contents
    }
  }

  // MARK: Responses

  /// One response packet; an empty payload has no payload section.
  static func response(
    _ op: Operation,
    _ status: Status,
    primary: Bool = false,
    id: [UInt8] = [],
    mime: String? = nil,
    pw: [UInt8]? = nil,
    payload: [UInt8] = [],
    terminator: String,
  ) -> [UInt8] {
    var out = metadata(op, status, primary: primary, id: id, mime: mime, pw: pw)
    if !payload.isEmpty {
      out.append(0x3B)
      out += Base64.encode(payload)
    }
    out += terminator.utf8
    return out
  }

  /// Field order matches kitty.
  private static func metadata(
    _ op: Operation,
    _ status: Status,
    primary: Bool,
    id: [UInt8],
    mime: String?,
    pw: [UInt8]?
  ) -> [UInt8] {
    var out = Array(
      "\u{1B}]5522;type=\(op.rawValue):status=\(status.rawValue)".utf8
    )
    if primary { out += ":loc=primary".utf8 }
    if !id.isEmpty { out += ":id=".utf8 + id }
    if let mime { out += ":mime=".utf8 + Base64.encode(Array(mime.utf8)) }
    if let pw { out += ":pw=".utf8 + Base64.encode(pw) }
    return out
  }

  /// OK, the targets listing when requested, DATA chunks per served type
  /// and DONE. Paste events take this shape with a one-time password.
  static func readSuccess(
    primary: Bool,
    id: [UInt8],
    pw: [UInt8]?,
    list: Bool,
    available: [String],
    contents: [Content],
    terminator: String
  ) -> [UInt8] {
    var out = response(
      .read,
      .OK,
      primary: primary,
      id: id,
      pw: pw,
      terminator: terminator
    )
    if list {
      out += metadata(.read, .DATA, primary: false, id: id, mime: ".", pw: pw)
      if !available.isEmpty {
        // One DATA packet: types that do not fit its chunk are dropped.
        var raw: [UInt8] = []
        for (i, mime) in available.enumerated() {
          let separator = i > 0 ? 1 : 0
          guard raw.count + separator + mime.utf8.count + 1 <= readChunkSize
          else { break }
          if i > 0 { raw.append(0x20) }
          raw += mime.utf8
        }
        raw.append(0x0A)
        out.append(0x3B)
        out += Base64.encode(raw)
      }
      out += terminator.utf8
    }
    for content in contents {
      var start = 0
      while start < content.data.count {
        let end = min(start + readChunkSize, content.data.count)
        out += response(
          .read,
          .DATA,
          id: id,
          mime: content.mime,
          pw: pw,
          payload: Array(content.data[start ..< end]),
          terminator: terminator
        )
        start = end
      }
    }
    out += response(.read, .DONE, id: id, pw: pw, terminator: terminator)
    return out
  }
}

/// Strict RFC 4648 base64 with required padding and zero trailing bits.
enum Base64 {
  private static let alphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
  )

  static func encode(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity((bytes.count + 2) / 3 * 4)
    var i = 0
    while i < bytes.count {
      let n = min(3, bytes.count - i)
      var v = UInt32(bytes[i]) << 16
      if n > 1 { v |= UInt32(bytes[i + 1]) << 8 }
      if n > 2 { v |= UInt32(bytes[i + 2]) }
      out.append(alphabet[Int(v >> 18 & 63)])
      out.append(alphabet[Int(v >> 12 & 63)])
      out.append(n > 1 ? alphabet[Int(v >> 6 & 63)] : 0x3D)
      out.append(n > 2 ? alphabet[Int(v & 63)] : 0x3D)
      i += 3
    }
    return out
  }

  /// A complete value: it must end on a group boundary.
  static func decode(_ bytes: some Collection<UInt8>) -> [UInt8]? {
    var stream = Stream()
    guard let out = stream.feed(bytes), stream.finish() else { return nil }
    return out
  }

  /// Decodes one stream split across packets at arbitrary boundaries.
  struct Stream {
    private var bits: UInt32 = 0
    private var sextets = 0
    private var padding = 0

    /// Nil for invalid input. A padded group ends the stream; anything
    /// after it in the same packet is invalid, but the next packet starts
    /// a fresh stream.
    mutating func feed(_ input: some Collection<UInt8>) -> [UInt8]? {
      var out: [UInt8] = []
      out.reserveCapacity(input.count / 4 * 3 + 3)
      var ended = false
      for c in input {
        guard !ended else { return nil }
        if c == 0x3D {
          guard sextets + padding >= 2 else { return nil }
          padding += 1
          guard sextets + padding == 4 else { continue }
          // Strict: the bits after the last whole byte must be zero.
          if sextets == 2 {
            guard bits & 0xF == 0 else { return nil }
            out.append(UInt8(bits >> 4))
          } else {
            guard bits & 0x3 == 0 else { return nil }
            out.append(UInt8(bits >> 10))
            out.append(UInt8(bits >> 2 & 0xFF))
          }
          (bits, sextets, padding) = (0, 0, 0)
          ended = true
          continue
        }
        guard padding == 0, let value = Self.value(c) else { return nil }
        bits = bits << 6 | value
        sextets += 1
        if sextets == 4 {
          out.append(UInt8(bits >> 16))
          out.append(UInt8(bits >> 8 & 0xFF))
          out.append(UInt8(bits & 0xFF))
          (bits, sextets) = (0, 0)
        }
      }
      return out
    }

    /// Whether the stream ended on a group boundary.
    func finish() -> Bool { sextets == 0 && padding == 0 }

    private static func value(_ c: UInt8) -> UInt32? {
      switch c {
      case 0x41 ... 0x5A: UInt32(c - 0x41)
      case 0x61 ... 0x7A: UInt32(c - 0x61 + 26)
      case 0x30 ... 0x39: UInt32(c - 0x30 + 52)
      case 0x2B: 62
      case 0x2F: 63
      default: nil
      }
    }
  }
}
