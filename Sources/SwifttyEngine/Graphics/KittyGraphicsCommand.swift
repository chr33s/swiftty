import CKittyBase64
/// Kitty graphics protocol commands (`ESC _ G … ESC \`).
///
/// Ported from Ghostty's `src/terminal/kitty/graphics_command.zig` at
/// 167acf0c: the same key/value grammar, defaults, value typing and silent
/// rejection of malformed commands, so oracle tests compare bytes.
/// Deviations (spec.graphics.md §19):
/// - D2: integers are plain decimal; `+` and `_` are rejected.
/// - Base64 follows Ghostty's SIMD build: ASCII whitespace is skipped and
///   padding is optional.
public enum KittyGraphics {
  /// Raw APC body bytes one command may carry; longer commands are
  /// dropped with no response.
  public static let maxAPCBytes = 64 << 20
  /// Largest image side, in pixels.
  static let maxDimension: UInt32 = 10_000
  /// Largest accumulated or decoded image, in bytes.
  static let maxSize = 400 * 1024 * 1024
  /// z below this draws under cell backgrounds (`Int32.min / 2`).
  public static let belowBackgroundZ: Int32 = -1_073_741_824
  /// The Unicode placeholder for virtual placements.
  public static let placeholder: UInt32 = 0x10EEEE
}

extension KittyGraphics {
  /// Control keys and decoded payload of one command.
  struct Command {
    var values = InlineArray<52, UInt32>(repeating: 0)
    var present: UInt64 = 0
    var payload: [UInt8] = []

    static func slot(_ key: UInt8) -> Int? {
      switch key {
      case 0x41 ... 0x5A: Int(key - 0x41)
      case 0x61 ... 0x7A: Int(key - 0x61) + 26
      default: nil
      }
    }

    func get(_ key: Unicode.Scalar) -> UInt32? {
      guard let i = Self.slot(UInt8(key.value)), present & (1 << UInt64(i)) != 0
      else { return nil }
      return values[i]
    }

    func value(_ key: Unicode.Scalar) -> UInt32 { get(key) ?? 0 }
    func signed(_ key: Unicode.Scalar) -> Int32 {
      Int32(bitPattern: get(key) ?? 0)
    }

    mutating func put(_ key: UInt8, _ value: UInt32) {
      guard let i = Self.slot(key) else { return }
      values[i] = value
      present |= 1 << UInt64(i)
    }

    /// `a`: defaults to transmit.
    var action: UInt8 { UInt8(truncatingIfNeeded: get("a") ?? 0x74) }

    enum Quiet: UInt8 { case no, ok, failures }

    var quiet: Quiet {
      switch get("q") {
      case nil, 0: .no
      case 1: .ok
      default: .failures
      }
    }
  }

  enum Format: UInt8, Sendable {
    case rgb, rgba, png, grayAlpha, gray
    var bytesPerPixel: Int {
      switch self {
      case .gray: 1
      case .grayAlpha: 2
      case .rgb: 3
      case .rgba: 4
      case .png: 0
      }
    }
  }

  enum Medium: UInt8, Sendable {
    case direct, file, temporaryFile, sharedMemory
  }

  /// Transmission keys (`a=t`, `T`, `q`, `f`).
  struct Transmission {
    var format = Format.rgba
    var formatUnknown = false
    var medium = Medium.direct
    var width: UInt32 = 0
    var height: UInt32 = 0
    var size: UInt32 = 0
    var offset: UInt32 = 0
    var imageID: UInt32 = 0
    var imageNumber: UInt32 = 0
    var placementID: UInt32 = 0
    var compressed = false
    var moreChunks = false
    var transient = false

    /// Nil when a key holds a value the protocol does not define.
    init?(_ c: Command) {
      if let f = c.get("f") {
        switch f {
        case 24: format = .rgb
        case 0, 32: format = .rgba
        case 100: format = .png
        default: formatUnknown = true
        }
      }
      if let t = c.get("t") {
        switch t {
        case 0x64: medium = .direct
        case 0x66: medium = .file
        case 0x74: medium = .temporaryFile
        case 0x73: medium = .sharedMemory
        default: return nil
        }
      }
      width = c.value("s")
      height = c.value("v")
      size = c.value("S")
      offset = c.value("O")
      imageID = c.value("i")
      imageNumber = c.value("I")
      placementID = c.value("p")
      if let o = c.get("o") {
        guard o == 0x7A else { return nil }
        compressed = true
      }
      if medium == .direct, let m = c.get("m") { moreChunks = m > 0 }
      transient = c.value("N") & 1 != 0
    }
  }

  /// Display keys (`a=p`, `T`).
  struct Display {
    var imageID: UInt32 = 0
    var imageNumber: UInt32 = 0
    var placementID: UInt32 = 0
    var x: UInt32 = 0
    var y: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var xOffset: UInt32 = 0
    var yOffset: UInt32 = 0
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var movesCursor = true
    var virtual = false
    var parentID: UInt32 = 0
    var parentPlacementID: UInt32 = 0
    var horizontalOffset: Int32 = 0
    var verticalOffset: Int32 = 0
    var z: Int32 = 0

    init() {}

    init(_ c: Command) {
      imageID = c.value("i")
      imageNumber = c.value("I")
      placementID = c.value("p")
      x = c.value("x")
      y = c.value("y")
      width = c.value("w")
      height = c.value("h")
      xOffset = c.value("X")
      yOffset = c.value("Y")
      columns = c.value("c")
      rows = c.value("r")
      if let m = c.get("C") { movesCursor = m != 1 }
      virtual = c.value("U") != 0
      z = c.signed("z")
      parentID = c.value("P")
      parentPlacementID = c.value("Q")
      horizontalOffset = c.signed("H")
      verticalOffset = c.signed("V")
    }
  }

  /// Delete targets (`a=d`).
  enum Delete: Equatable {
    case all(delete: Bool)
    case id(delete: Bool, imageID: UInt32, placementID: UInt32)
    case newest(delete: Bool, imageNumber: UInt32, placementID: UInt32)
    case cursor(delete: Bool)
    case frames(
      delete: Bool,
      imageID: UInt32,
      imageNumber: UInt32,
      frame: UInt32
    )
    case cell(delete: Bool, x: UInt32, y: UInt32)
    case cellZ(delete: Bool, x: UInt32, y: UInt32, z: Int32)
    case range(delete: Bool, first: UInt32, last: UInt32)
    case column(delete: Bool, x: UInt32)
    case row(delete: Bool, y: UInt32)
    case z(delete: Bool, z: Int32)

    init?(_ c: Command) {
      let what = c.get("d") ?? 0x61
      guard (0x41 ... 0x5A).contains(what) || (0x61 ... 0x7A).contains(what)
      else { return nil }
      let upper = (0x41 ... 0x5A).contains(what)
      switch UInt8(what) | 0x20 {
      case 0x61: self = .all(delete: upper)
      case 0x69:
        self = .id(
          delete: upper,
          imageID: c.value("i"),
          placementID: c.value("p")
        )
      case 0x6E:
        self = .newest(
          delete: upper,
          imageNumber: c.value("I"),
          placementID: c.value("p")
        )
      case 0x63: self = .cursor(delete: upper)
      case 0x66:
        self = .frames(
          delete: upper,
          imageID: c.value("i"),
          imageNumber: c.value("I"),
          frame: c.value("r")
        )
      case 0x70: self = .cell(delete: upper, x: c.value("x"), y: c.value("y"))
      case 0x71:
        self = .cellZ(
          delete: upper,
          x: c.value("x"),
          y: c.value("y"),
          z: c.signed("z")
        )
      case 0x72:
        self = .range(delete: upper, first: c.value("x"), last: c.value("y"))
      case 0x78: self = .column(delete: upper, x: c.value("x"))
      case 0x79: self = .row(delete: upper, y: c.value("y"))
      case 0x7A: self = .z(delete: upper, z: c.signed("z"))
      default: return nil
      }
    }

    var deletesImages: Bool {
      switch self {
      case let .all(d), let .cursor(d): d
      case let .id(d, _, _), let .newest(d, _, _), let .cell(d, _, _),
        let .range(d, _, _):
        d
      case let .frames(d, _, _, _), let .cellZ(d, _, _, _): d
      case let .column(d, _), let .row(d, _), let .z(d, _): d
      }
    }
  }

  /// A reply: written only when it carries an image id or number.
  struct Response: Equatable {
    var id: UInt32 = 0
    var imageNumber: UInt32 = 0
    var placementID: UInt32 = 0
    var frame: UInt32 = 0
    var message = "OK"

    var isOK: Bool { message == "OK" }
    var isEmpty: Bool { id == 0 && imageNumber == 0 }

    func encoded() -> [UInt8]? {
      guard !isEmpty else { return nil }
      var keys: [String] = []
      if id > 0 { keys.append("i=\(id)") }
      if imageNumber > 0 { keys.append("I=\(imageNumber)") }
      if placementID > 0 { keys.append("p=\(placementID)") }
      if frame > 0 { keys.append("r=\(frame)") }
      return Array(
        "\u{1B}_G\(keys.joined(separator: ","));\(message)\u{1B}\\".utf8
      )
    }
  }
}

extension KittyGraphics {
  /// The parser of the command being received, off the terminal's layout.
  final class CommandBox { var parser = CommandParser() }

  /// Incremental parser for one APC body after its leading `G`.
  struct CommandParser {
    private enum State { case key, keyIgnore, value, valueIgnore, data }
    private var state = State.key
    private var temp = InlineArray<11, UInt8>(repeating: 0)
    private var tempCount = 0
    private var currentKey: UInt8 = 0
    private var command = Command()
    /// Base64 payload bytes, decoded on completion.
    private var data: [UInt8] = []
    private var failed = false
    private var received = 0

    init() {}

    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
      guard !failed else { return }
      guard bytes.count <= KittyGraphics.maxAPCBytes - received else {
        failed = true
        data = []
        return
      }
      received += bytes.count
      var i = 0
      while i < bytes.count {
        if state == .data {
          data.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i...]))
          return
        }
        step(bytes[i])
        if failed { return }
        i += 1
      }
    }

    private mutating func accumulate(_ c: UInt8, overflow: State) {
      guard tempCount < 11 else {
        state = overflow
        tempCount = 0
        return
      }
      temp[tempCount] = c
      tempCount += 1
    }

    private mutating func step(_ c: UInt8) {
      switch state {
      case .key:
        switch c {
        case 0x3D:  // '='
          if tempCount != 1 {
            state = .valueIgnore
          } else {
            currentKey = temp[0]
            state = .value
          }
          tempCount = 0
        case 0x3B: state = .data  // payload-only command
        default: accumulate(c, overflow: .keyIgnore)
        }
      case .keyIgnore: if c == 0x3D { state = .valueIgnore }
      case .value:
        switch c {
        case 0x2C: finishValue(next: .key)
        case 0x3B: finishValue(next: .data)
        default: accumulate(c, overflow: .valueIgnore)
        }
      case .valueIgnore:
        switch c {
        case 0x2C: state = .keyIgnore
        case 0x3B: state = .data
        default: break
        }
      case .data: break
      }
    }

    private mutating func finishValue(next: State) {
      state = next
      defer { tempCount = 0 }
      if tempCount == 1, !(0x30 ... 0x39).contains(temp[0]) {
        command.put(currentKey, UInt32(temp[0]))
        return
      }
      let signed =
        currentKey == 0x7A || currentKey == 0x48 || currentKey == 0x56
      guard let v = Self.parseInt(temp, count: tempCount, signed: signed) else {
        failed = true
        return
      }
      command.put(currentKey, v)
    }

    /// Decimal with an optional `-` for signed keys; nil on overflow,
    /// empty input or any other character.
    static func parseInt(
      _ digits: InlineArray<11, UInt8>,
      count: Int,
      signed: Bool
    ) -> UInt32? {
      var i = 0
      var negative = false
      if signed, count > 0, digits[0] == 0x2D {
        negative = true
        i = 1
      }
      guard i < count else { return nil }
      var v: Int64 = 0
      while i < count {
        let d = digits[i]
        guard (0x30 ... 0x39).contains(d) else { return nil }
        v = v * 10 + Int64(d - 0x30)
        if v > 1 << 32 { return nil }
        i += 1
      }
      if signed {
        let s = negative ? -v : v
        guard s >= Int64(Int32.min), s <= Int64(Int32.max) else { return nil }
        return UInt32(bitPattern: Int32(s))
      }
      guard v <= Int64(UInt32.max) else { return nil }
      return UInt32(v)
    }

    /// The command, or nil when it is malformed (no response is sent).
    mutating func complete() -> Command? {
      guard !failed else { return nil }
      switch state {
      case .key, .keyIgnore: return nil
      case .value:
        finishValue(next: .data)
        if failed { return nil }
      case .valueIgnore, .data: break
      }
      guard let decoded = KittyGraphics.decodeBase64(data) else { return nil }
      data = []
      command.payload = decoded
      return command
    }
  }

  /// 0–63 for alphabet bytes, 64 for `=`, 65 for skipped whitespace, 255
  /// for anything else.
  private static let base64Table: [UInt8] = {
    var t = [UInt8](repeating: 255, count: 256)
    let alphabet = Array(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )
    for (i, c) in alphabet.enumerated() { t[Int(c)] = UInt8(i) }
    t[0x3D] = 64
    for c in [0x20, 0x09, 0x0A, 0x0C, 0x0D] { t[c] = 65 }
    return t
  }()

  /// Standard-alphabet base64: ASCII whitespace skipped, padding optional,
  /// trailing bits ignored. Nil for any other character, a misplaced `=`
  /// or a lone trailing sextet.
  /// Four lookup tables of pre-shifted sextets (bit 31: not an alphabet
  /// byte), for `decodeBase64Blocks`.
  private final class Base64Shifted: Sendable {
    static let shared = Base64Shifted()
    nonisolated(unsafe) let tables: UnsafeMutablePointer<UInt32>

    private init() {
      tables = .allocate(capacity: 4 * 256)
      tables.initialize(repeating: 0x8000_0000, count: 4 * 256)
      let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
      )
      for (v, c) in alphabet.enumerated() {
        for k in 0 ..< 4 {
          tables[k * 256 + Int(c)] = UInt32(v) << UInt32(18 - 6 * k)
        }
      }
    }
  }

  /// Decodes leading 16-byte blocks of plain alphabet bytes; returns the
  /// input and output offsets reached. Stops before any block holding
  /// padding, whitespace or an invalid byte, which the scalar paths handle.
  /// Writes one byte past its output (callers reserve it).
  @inline(never)
  static func decodeBase64Blocks(
    _ src: UnsafePointer<UInt8>,
    count n: Int,
    into dst: UnsafeMutablePointer<UInt8>
  ) -> (Int, Int) {
    let t = Base64Shifted.shared.tables
    let (t0, t1, t2, t3) = (t, t + 256, t + 512, t + 768)
    var i = 0
    var o = 0
    let out = UnsafeMutableRawPointer(dst)
    while i + 16 <= n {
      let s = src + i
      let w0 = t0[Int(s[0])] | t1[Int(s[1])] | t2[Int(s[2])] | t3[Int(s[3])]
      let w1 = t0[Int(s[4])] | t1[Int(s[5])] | t2[Int(s[6])] | t3[Int(s[7])]
      let w2 = t0[Int(s[8])] | t1[Int(s[9])] | t2[Int(s[10])] | t3[Int(s[11])]
      let w3 = t0[Int(s[12])] | t1[Int(s[13])] | t2[Int(s[14])] | t3[Int(s[15])]
      guard (w0 | w1 | w2 | w3) & 0x8000_0000 == 0 else { break }
      // Each group's 24 bits, big-endian; the fourth byte is overwritten.
      out.storeBytes(of: (w0 << 8).bigEndian, toByteOffset: o, as: UInt32.self)
      out.storeBytes(
        of: (w1 << 8).bigEndian,
        toByteOffset: o + 3,
        as: UInt32.self
      )
      out.storeBytes(
        of: (w2 << 8).bigEndian,
        toByteOffset: o + 6,
        as: UInt32.self
      )
      out.storeBytes(
        of: (w3 << 8).bigEndian,
        toByteOffset: o + 9,
        as: UInt32.self
      )
      o += 12
      i += 16
    }
    return (i, o)
  }

  static func decodeBase64(_ input: [UInt8]) -> [UInt8]? {
    if input.isEmpty { return [] }
    return base64Table.withUnsafeBufferPointer { table in
      input.withUnsafeBufferPointer { src -> [UInt8]? in
        let n = src.count
        var result: [UInt8]? = nil
        let capacity = n / 4 * 3 + 3
        let out = [UInt8](unsafeUninitializedCapacity: capacity) {
          dst,
          written in
          // NEON blocks of 64, then 16-byte table blocks, until padding,
          // whitespace or an invalid byte.
          let vector = swiftty_base64_decode_blocks(
            src.baseAddress!,
            n,
            dst.baseAddress!
          )
          var (i, o) = Self.decodeBase64Blocks(
            src.baseAddress! + vector,
            count: n - vector,
            into: dst.baseAddress! + vector / 4 * 3
          )
          i += vector
          o += vector / 4 * 3
          // Fast path: whole groups of four alphabet bytes.
          while i + 4 <= n {
            let a = table[Int(src[i])]
            let b = table[Int(src[i + 1])]
            let c = table[Int(src[i + 2])]
            let d = table[Int(src[i + 3])]
            guard a | b | c | d < 64 else { break }
            let v =
              UInt32(a) << 18 | UInt32(b) << 12 | UInt32(c) << 6 | UInt32(d)
            dst[o] = UInt8(v >> 16)
            dst[o + 1] = UInt8(v >> 8 & 0xFF)
            dst[o + 2] = UInt8(v & 0xFF)
            o += 3
            i += 4
          }
          // General path: whitespace, padding and the tail.
          var bits: UInt32 = 0
          var count = 0
          var padding = 0
          while i < n {
            let v = table[Int(src[i])]
            i += 1
            switch v {
            case 65: continue
            case 64:
              padding += 1
              guard padding <= 2 else {
                written = 0;
                return
              }
              continue
            case 255:
              written = 0
              return
            default:
              guard padding == 0 else {
                written = 0;
                return
              }
              bits = bits << 6 | UInt32(v)
              count += 1
              if count == 4 {
                dst[o] = UInt8(bits >> 16)
                dst[o + 1] = UInt8(bits >> 8 & 0xFF)
                dst[o + 2] = UInt8(bits & 0xFF)
                o += 3
                bits = 0
                count = 0
              }
            }
          }
          switch count {
          case 0:
            guard padding == 0 else {
              written = 0;
              return
            }
          case 1:
            written = 0
            return
          case 2:
            dst[o] = UInt8(bits >> 4 & 0xFF)
            o += 1
          default:
            dst[o] = UInt8(bits >> 10 & 0xFF)
            dst[o + 1] = UInt8(bits >> 2 & 0xFF)
            o += 2
          }
          written = o
          result = []
        }
        return result == nil ? nil : out
      }
    }
  }
}
