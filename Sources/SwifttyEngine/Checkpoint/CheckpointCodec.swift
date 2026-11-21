// Fixed-width, big-endian encoding for planned-replacement checkpoints
// (spec.durability.md §6). Never pointers, spans or Swift object layouts.
// Every count is checked against the remaining input before allocation.

package struct CheckpointError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  package let message: String
  package init(_ message: String) { self.message = message }
  package var description: String { "checkpoint: \(message)" }
}

package struct CheckpointWriter: Sendable {
  package private(set) var bytes: [UInt8] = []

  package init() {}

  package mutating func u8(_ v: UInt8) { bytes.append(v) }
  package mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
  package mutating func u16(_ v: UInt16) {
    bytes.append(UInt8(v >> 8))
    bytes.append(UInt8(truncatingIfNeeded: v))
  }
  package mutating func u32(_ v: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
      bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
    }
  }
  package mutating func u64(_ v: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
    }
  }
  /// Signed values as two's complement 64-bit.
  package mutating func int(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
  package mutating func optionalInt(_ v: Int?) {
    bool(v != nil)
    if let v { int(v) }
  }
  package mutating func optionalU32(_ v: UInt32?) {
    bool(v != nil)
    if let v { u32(v) }
  }
  package mutating func data(_ v: [UInt8]) {
    int(v.count)
    bytes.append(contentsOf: v)
  }
  package mutating func string(_ v: String) { data(Array(v.utf8)) }
  package mutating func optionalString(_ v: String?) {
    bool(v != nil)
    if let v { string(v) }
  }
  /// A length-prefixed nested section.
  package mutating func section(
    _ tag: UInt8,
    _ body: (inout CheckpointWriter) -> Void
  ) {
    var nested = CheckpointWriter()
    body(&nested)
    u8(tag)
    data(nested.bytes)
  }
}

package struct CheckpointReader: Sendable {
  private let bytes: [UInt8]
  private var offset: Int
  private let end: Int

  package init(_ bytes: [UInt8]) {
    self.bytes = bytes
    offset = 0
    end = bytes.count
  }

  private init(_ bytes: [UInt8], from start: Int, to end: Int) {
    self.bytes = bytes
    offset = start
    self.end = end
  }

  package var isAtEnd: Bool { offset == end }
  package var remaining: Int { end - offset }

  private mutating func take(_ n: Int) throws(CheckpointError) -> Range<Int> {
    guard n >= 0, n <= end - offset else {
      throw CheckpointError("truncated input")
    }
    defer { offset += n }
    return offset ..< offset + n
  }

  package mutating func u8() throws(CheckpointError) -> UInt8 {
    bytes[try take(1).lowerBound]
  }
  package mutating func bool() throws(CheckpointError) -> Bool {
    switch try u8() {
    case 0: false
    case 1: true
    default: throw CheckpointError("invalid boolean")
    }
  }
  package mutating func u16() throws(CheckpointError) -> UInt16 {
    let r = try take(2)
    return UInt16(bytes[r.lowerBound]) << 8 | UInt16(bytes[r.lowerBound + 1])
  }
  package mutating func u32() throws(CheckpointError) -> UInt32 {
    let r = try take(4)
    return bytes[r].reduce(0) { $0 << 8 | UInt32($1) }
  }
  package mutating func u64() throws(CheckpointError) -> UInt64 {
    let r = try take(8)
    return bytes[r].reduce(0) { $0 << 8 | UInt64($1) }
  }
  package mutating func int() throws(CheckpointError) -> Int {
    let value = Int64(bitPattern: try u64())
    guard let result = Int(exactly: value) else {
      throw CheckpointError("integer out of range")
    }
    return result
  }
  /// A count of items each at least `minimumSize` bytes, bounded by input.
  package mutating func count(
    max limit: Int,
    minimumSize: Int = 1
  ) throws(CheckpointError) -> Int {
    let n = try int()
    guard n >= 0, n <= limit, n * max(1, minimumSize) <= remaining else {
      throw CheckpointError(
        "invalid count \(n) (limit \(limit), \(remaining) bytes left)"
      )
    }
    return n
  }
  package mutating func bounded(
    _ range: ClosedRange<Int>
  ) throws(CheckpointError) -> Int {
    let n = try int()
    guard range.contains(n) else {
      throw CheckpointError("value \(n) out of range")
    }
    return n
  }
  package mutating func optionalInt() throws(CheckpointError) -> Int? {
    try bool() ? try int() : nil
  }
  package mutating func optionalU32() throws(CheckpointError) -> UInt32? {
    try bool() ? try u32() : nil
  }
  package mutating func data(max limit: Int) throws(CheckpointError) -> [UInt8]
  {
    let n = try count(max: limit)
    return Array(bytes[try take(n)])
  }
  package mutating func string(max limit: Int) throws(CheckpointError) -> String
  {
    let raw = try data(max: limit)
    guard let value = String(validating: raw, as: UTF8.self) else {
      throw CheckpointError("invalid UTF-8")
    }
    return value
  }
  package mutating func optionalString(
    max limit: Int
  ) throws(CheckpointError) -> String? {
    try bool() ? try string(max: limit) : nil
  }
  /// The next section, which must carry `tag`.
  package mutating func section(
    _ tag: UInt8,
    max limit: Int = .max
  ) throws(CheckpointError) -> CheckpointReader {
    guard try u8() == tag else {
      throw CheckpointError("expected section \(tag)")
    }
    let n = try count(max: limit)
    let r = try take(n)
    return CheckpointReader(bytes, from: r.lowerBound, to: r.upperBound)
  }
  package func finish() throws(CheckpointError) {
    guard isAtEnd else { throw CheckpointError("trailing bytes") }
  }
}

// MARK: Cells

extension CheckpointWriter {
  /// Glyph, then the attribute words exactly: colors with their link and
  /// underline-colour bits, flags, and the tail with link bits and width.
  mutating func cell(_ cell: Cell) {
    u32(cell.glyph)
    u32(cell.packed.foregroundBits.rawValue)
    u32(cell.packed.backgroundBits.rawValue)
    u16(cell.packed.flags.rawValue)
    u16(cell.packed.tail)
  }

  mutating func cells(_ cells: UnsafeBufferPointer<Cell>) {
    int(cells.count)
    for c in cells { cell(c) }
  }

  mutating func attributes(_ a: CellAttributes) {
    u32(a.foregroundBits.rawValue)
    u32(a.backgroundBits.rawValue)
    u16(a.flags.rawValue)
    u16(a.tail)
  }
}

extension CheckpointReader {
  mutating func cell() throws(CheckpointError) -> Cell {
    var c = Cell(glyph: try u32(), attributes: .default, width: 0)
    c.packed.foregroundBits = TerminalColor(rawValue: try u32())
    c.packed.backgroundBits = TerminalColor(rawValue: try u32())
    c.packed.flags = CellFlags(rawValue: try u16())
    c.packed.tail = try u16()
    return c
  }

  mutating func cells(columns: Int) throws(CheckpointError) -> [Cell] {
    guard try int() == columns else {
      throw CheckpointError("row width mismatch")
    }
    guard columns * 16 <= remaining else {
      throw CheckpointError("truncated row")
    }
    var out: [Cell] = []
    out.reserveCapacity(columns)
    for _ in 0 ..< columns { out.append(try cell()) }
    return out
  }

  mutating func attributes() throws(CheckpointError) -> CellAttributes {
    var a = CellAttributes.default
    a.foregroundBits = TerminalColor(rawValue: try u32())
    a.backgroundBits = TerminalColor(rawValue: try u32())
    a.flags = CellFlags(rawValue: try u16())
    a.tail = try u16()
    return a
  }
}
