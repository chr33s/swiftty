/// DECRQCRA (request checksum of a rectangular area) and XTCHECKSUM
/// (select the checksum variant), following xterm's `xtermCheckRect` as
/// Ghostty does, including where xterm's code and documentation disagree.
extension TerminalState {
  /// XTCHECKSUM (`CSI Ps # y`) bits. Zero is the DEC checksum.
  public struct ChecksumFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }

    /// Do not negate the result.
    public static let positive = ChecksumFlags(rawValue: 1 << 0)
    /// Do not add VT100 video attributes to each cell.
    public static let noAttributes = ChecksumFlags(rawValue: 1 << 1)
    /// Count blanks; the DEC sum keeps a plain space only as the first cell.
    public static let noTrim = ChecksumFlags(rawValue: 1 << 2)
    /// Count never-written cells as spaces instead of skipping them.
    public static let undrawn = ChecksumFlags(rawValue: 1 << 3)
    /// Sum whole scalars instead of DEC 8-bit values; spacers and
    /// combining marks are not counted.
    public static let full = ChecksumFlags(rawValue: 1 << 4)
  }

  /// `CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y`. The page is ignored.
  mutating func requestRectangleChecksum(_ csi: UnsafePointer<CSISequence>) {
    guard rectangleChecksumsEnabled, csi.pointee.count <= 6 else { return }
    func field(_ i: Int) -> Int { min(csi.pointee.value(i), Int(UInt16.max)) }
    let id = field(0)
    let sum = rectangleChecksum(
      top: field(2),
      left: field(3),
      bottom: field(4),
      right: field(5)
    )
    let hex = String(sum, radix: 16, uppercase: true)
    let padded = String(repeating: "0", count: 4 - hex.count) + hex
    reply("\u{1B}P\(id)!~\(padded)\u{1B}\\")
  }

  /// `CSI Ps # y`. Unknown bits are ignored, as in xterm.
  mutating func selectChecksumExtension(_ csi: UnsafePointer<CSISequence>) {
    guard rectangleChecksumsEnabled, csi.pointee.count <= 1 else { return }
    checksumFlags = ChecksumFlags(
      rawValue: UInt8(truncatingIfNeeded: csi.pointee.value(0))
    )
  }

  /// Sum of a 1-based rectangle (0 selects the default edge). Under DECOM
  /// it is relative to the margins; it is clamped to the screen, and an
  /// empty rectangle sums to zero.
  func rectangleChecksum(top: Int, left: Int, bottom: Int, right: Int) -> UInt16
  {
    let origin = modes.contains(.origin)
    func limit(
      _ value: Int,
      _ fallback: Int,
      _ margin: Int,
      _ maximum: Int
    ) -> Int { min(max((value == 0 ? fallback : value) + margin, 1), maximum) }
    let topMargin = origin ? scrollTop : 0
    let leftMargin = origin ? scrollLeft : 0
    let t = limit(top, 1, topMargin, rows)
    let l = limit(left, 1, leftMargin, columns)
    let b = limit(bottom, rows, topMargin, rows)
    let r = limit(right, columns, leftMargin, columns)
    let flags = checksumFlags
    var sum: UInt16 = 0
    guard t <= b, l <= r else { return 0 }
    // The DEC sum omits plain spaces except the rectangle's first cell.
    var first = true
    for y in t - 1 ... b - 1 {
      for x in l - 1 ... r - 1 {
        let cell = grid[x, y]
        var ch: UInt16
        switch checksumValue(cell, flags) {
        case .skip: continue
        case .undrawn:
          guard flags.contains(.noTrim) || flags.contains(.undrawn) else {
            continue
          }
          ch = 0x20
        case let .value(v): ch = v
        }
        if !flags.contains(.noAttributes) {
          ch &+= Self.checksumAttributes(cell.flags)
        }
        if flags.contains(.noTrim) {
          sum &+= ch
          // xterm adds combining marks only to the untrimmed DEC sum.
          if !flags.contains(.full), cell.isGrapheme {
            let scalars = graphemes.scalars(cell.glyph)
            for i in 1 ..< scalars.count {
              sum &+= UInt16(truncatingIfNeeded: scalars[i])
            }
          }
        } else if first || ch != 0x20
          || !cell.flags.isDisjoint(with: Self.checksumKeepsSpace)
        {
          sum &+= ch
        }
        first = flags.contains(.noTrim)
      }
      if !flags.contains(.noTrim) { first = false }
    }
    return flags.contains(.positive) ? sum : 0 &- sum
  }

  private enum ChecksumValue {
    case skip, undrawn
    case value(UInt16)
  }

  private func checksumValue(
    _ cell: Cell,
    _ flags: ChecksumFlags
  ) -> ChecksumValue {
    // xterm stores a placeholder outside 8 bits in a wide character's
    // right half, so the DEC sum counts it as ESC.
    if cell.flags.contains(.spacerTail) {
      return flags.contains(.full) ? .skip : .value(0x1B)
    }
    // Grapheme ids start at zero; only a plain zero glyph is undrawn.
    guard cell.isGrapheme || cell.glyph != 0 else { return .undrawn }
    let scalar = cell.isGrapheme ? graphemes.scalars(cell.glyph)[0] : cell.glyph
    if flags.contains(.full) {
      return .value(UInt16(truncatingIfNeeded: scalar))
    }
    // xterm's `xtermCharSetDec` for ASCII. It sums the byte received
    // before character-set translation; only the translated scalar is
    // kept here, so DEC line drawing counts as outside 8 bits.
    return switch scalar {
    case 0x7F, 0xFF: .value(0)
    case 0x20 ... 0x7E, 0x80 ... 0x9F, 0xA1 ... 0xFE:
      .value(UInt16(scalar & 0x7F))
    default: .value(0x1B)
    }
  }

  /// The VT100 video attributes xterm adds to each cell.
  private static func checksumAttributes(_ flags: CellFlags) -> UInt16 {
    var result: UInt16 = 0
    if flags.contains(.protected) { result += 0x04 }
    if flags.contains(.invisible) { result += 0x08 }
    if !flags.isDisjoint(with: CellFlags.anyUnderline) { result += 0x10 }
    if flags.contains(.inverse) { result += 0x20 }
    if flags.contains(.blink) { result += 0x40 }
    if flags.contains(.bold) { result += 0x80 }
    return result
  }

  /// Attributes xterm does not add but that keep a space from trimming.
  private static let checksumKeepsSpace: CellFlags = [
    .faint, .italic, .strikethrough, .doubleUnderline,
  ]
}
