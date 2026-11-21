import Foundation

// Saved output at rest (spec.durability.md §12.2.4, C1). Its own versioned
// binary format, not the SMX wire codec: no titles, cursor, modes, links or
// input. Every integer is fixed-width and big-endian.

/// A style: colors are `TerminalColor` raw values (tag byte 0 default,
/// 1 palette index, 2 RGB), flags are cell attribute bits.
public struct SavedOutputStyle: Sendable, Hashable {
  public var foreground: UInt32
  public var background: UInt32
  public var underline: UInt32
  public var flags: UInt16

  public init(
    foreground: UInt32,
    background: UInt32,
    underline: UInt32,
    flags: UInt16
  ) {
    self.foreground = foreground
    self.background = background
    self.underline = underline
    self.flags = flags
  }

  public static let plain = SavedOutputStyle(
    foreground: 0,
    background: 0,
    underline: 0,
    flags: 0
  )
}

public struct SavedOutputCell: Sendable, Hashable {
  /// Index into `graphemes`.
  public var grapheme: UInt32
  /// 1 or 2 columns.
  public var width: UInt8
  /// Index into `styles`.
  public var style: UInt16

  public init(grapheme: UInt32, width: UInt8, style: UInt16) {
    self.grapheme = grapheme
    self.width = width
    self.style = style
  }
}

public struct SavedOutputRow: Sendable, Hashable {
  public var wrapped: Bool
  /// Trailing blank cells are dropped.
  public var cells: [SavedOutputCell]

  public init(wrapped: Bool, cells: [SavedOutputCell]) {
    self.wrapped = wrapped
    self.cells = cells
  }
}

/// Bounded main-screen rows of one pane.
public struct SavedOutput: Sendable, Equatable {
  public static let formatVersion: UInt16 = 1
  /// Newest rows kept per pane (§12.2.9).
  public static let maxRows = 2000
  public static let maxBytes = 2 << 20
  public static let maxColumns = 1024
  public static let maxStyles = 4096
  public static let maxGraphemeScalars = 32

  public var columns: Int
  /// 256 entries, `0xRRGGBB`.
  public var palette: [UInt32]
  public var defaultForeground: UInt32
  public var defaultBackground: UInt32
  public var styles: [SavedOutputStyle]
  public var graphemes: [String]
  public var rows: [SavedOutputRow]

  public init(
    columns: Int,
    palette: [UInt32],
    defaultForeground: UInt32,
    defaultBackground: UInt32,
    styles: [SavedOutputStyle],
    graphemes: [String],
    rows: [SavedOutputRow]
  ) {
    self.columns = columns
    self.palette = palette
    self.defaultForeground = defaultForeground
    self.defaultBackground = defaultBackground
    self.styles = styles
    self.graphemes = graphemes
    self.rows = rows
  }

  /// Plain text, one line per row; wrapped rows continue without a break.
  public var text: String {
    var out = ""
    for row in rows {
      for cell in row.cells { out += graphemes[Int(cell.grapheme)] }
      if !row.wrapped { out += "\n" }
    }
    return out
  }

  // MARK: Encoding

  public func encoded() throws(MuxError) -> Data {
    var data = Data()
    func u8(_ v: UInt8) { data.append(v) }
    func u16(_ v: UInt16) {
      withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }
    func u32(_ v: UInt32) {
      withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }
    guard palette.count == 256, columns > 0, columns <= Self.maxColumns,
      styles.count <= Self.maxStyles, rows.count <= Self.maxRows,
      graphemes.count <= Int(UInt32.max)
    else { throw MuxError(.resourceLimit, "saved output exceeds its bounds") }
    data.append(contentsOf: Array("SMXO".utf8))
    u16(Self.formatVersion)
    u16(UInt16(columns))
    for color in palette { u32(color) }
    u32(defaultForeground)
    u32(defaultBackground)
    u16(UInt16(styles.count))
    for style in styles {
      u32(style.foreground)
      u32(style.background)
      u32(style.underline)
      u16(style.flags)
    }
    u32(UInt32(graphemes.count))
    for grapheme in graphemes {
      let bytes = Array(grapheme.utf8)
      guard bytes.count <= 255 else {
        throw MuxError(.resourceLimit, "saved grapheme too long")
      }
      u8(UInt8(bytes.count))
      data.append(contentsOf: bytes)
    }
    u32(UInt32(rows.count))
    for row in rows {
      u8(row.wrapped ? 1 : 0)
      u16(UInt16(row.cells.count))
      for cell in row.cells {
        u32(cell.grapheme)
        u8(cell.width)
        u16(cell.style)
      }
      guard data.count <= Self.maxBytes else {
        throw MuxError(.resourceLimit, "saved output exceeds its bounds")
      }
    }
    return data
  }

  /// Validates every count and reference before allocating.
  public init(decoding data: Data) throws(MuxError) {
    var offset = data.startIndex
    func take(_ n: Int) throws(MuxError) -> Data {
      guard n >= 0, n <= data.endIndex - offset else {
        throw MuxError(.invalidRequest, "truncated saved output")
      }
      defer { offset += n }
      return data[offset ..< offset + n]
    }
    func u8() throws(MuxError) -> UInt8 { try take(1).first! }
    func u16() throws(MuxError) -> UInt16 {
      try take(2).reduce(0) { $0 << 8 | UInt16($1) }
    }
    func u32() throws(MuxError) -> UInt32 {
      try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
    guard data.count <= Self.maxBytes, try take(4) == Data("SMXO".utf8),
      try u16() == Self.formatVersion
    else { throw MuxError(.invalidRequest, "not saved output") }
    let columns = Int(try u16())
    guard columns > 0, columns <= Self.maxColumns else {
      throw MuxError(.invalidRequest, "invalid saved output width")
    }
    var palette: [UInt32] = []
    palette.reserveCapacity(256)
    for _ in 0 ..< 256 { palette.append(try u32()) }
    let foreground = try u32()
    let background = try u32()
    let styleCount = Int(try u16())
    guard styleCount <= Self.maxStyles,
      styleCount * 14 <= data.endIndex - offset
    else { throw MuxError(.invalidRequest, "invalid saved output styles") }
    var styles: [SavedOutputStyle] = []
    styles.reserveCapacity(styleCount)
    for _ in 0 ..< styleCount {
      styles.append(
        SavedOutputStyle(
          foreground: try u32(),
          background: try u32(),
          underline: try u32(),
          flags: try u16()
        )
      )
    }
    let graphemeCount = Int(try u32())
    guard graphemeCount <= data.endIndex - offset else {
      throw MuxError(.invalidRequest, "invalid saved output graphemes")
    }
    var graphemes: [String] = []
    graphemes.reserveCapacity(graphemeCount)
    for _ in 0 ..< graphemeCount {
      let bytes = try take(Int(try u8()))
      guard let text = String(bytes: bytes, encoding: .utf8),
        text.unicodeScalars.count <= Self.maxGraphemeScalars
      else { throw MuxError(.invalidRequest, "invalid saved grapheme") }
      graphemes.append(text)
    }
    let rowCount = Int(try u32())
    guard rowCount <= Self.maxRows else {
      throw MuxError(.invalidRequest, "too many saved output rows")
    }
    var rows: [SavedOutputRow] = []
    rows.reserveCapacity(rowCount)
    for _ in 0 ..< rowCount {
      let wrapped = try u8() != 0
      let count = Int(try u16())
      guard count <= columns, count * 7 <= data.endIndex - offset else {
        throw MuxError(.invalidRequest, "invalid saved output row")
      }
      var cells: [SavedOutputCell] = []
      cells.reserveCapacity(count)
      var width = 0
      for _ in 0 ..< count {
        let cell = SavedOutputCell(
          grapheme: try u32(),
          width: try u8(),
          style: try u16()
        )
        width += Int(cell.width)
        guard Int(cell.grapheme) < graphemes.count,
          Int(cell.style) < max(1, styles.count),
          cell.width == 1 || cell.width == 2, width <= columns
        else { throw MuxError(.invalidRequest, "invalid saved output cell") }
        cells.append(cell)
      }
      rows.append(SavedOutputRow(wrapped: wrapped, cells: cells))
    }
    guard offset == data.endIndex else {
      throw MuxError(.invalidRequest, "trailing saved output bytes")
    }
    self.init(
      columns: columns,
      palette: palette,
      defaultForeground: foreground,
      defaultBackground: background,
      styles: styles,
      graphemes: graphemes,
      rows: rows
    )
  }
}

/// Collects main-screen rows from frames into `SavedOutput`.
public struct SavedOutputBuilder: Sendable {
  private var columns = 1
  private var palette: [UInt32] = Array(repeating: 0, count: 256)
  private var foreground: UInt32 = 0xFFFFFF
  private var background: UInt32 = 0
  private var styles: [SavedOutputStyle] = [.plain]
  private var styleIndex: [SavedOutputStyle: UInt16] = [.plain: 0]
  private var graphemes: [String] = [" "]
  private var graphemeIndex: [String: UInt32] = [" ": 0]
  private(set) var rows: [SavedOutputRow] = []

  public init() {}

  /// Appends rows `range` of `frame` (main screen only).
  public mutating func append(_ frame: PaneFrame, rows range: Range<Int>) {
    let grid = frame.grid
    guard !grid.alternateScreen else { return }
    columns = max(columns, min(grid.columns, SavedOutput.maxColumns))
    if frame.palette.colors.count == 256 { palette = frame.palette.colors }
    foreground = frame.palette.foreground
    background = frame.palette.background
    for y in range where y >= 0 && y < grid.rows {
      var cells: [SavedOutputCell] = []
      var x = 0
      while x < grid.columns, x < SavedOutput.maxColumns {
        let i = y * grid.columns + x
        let kind = grid.kind(at: i)
        guard kind == .narrow || kind == .wideLead else {
          x += 1
          continue
        }
        let text = Self.text(frame, glyph: grid.glyph(at: i))
        let style = style(frame, index: grid.style(at: i))
        let width: UInt8 = kind == .wideLead ? 2 : 1
        cells.append(
          SavedOutputCell(grapheme: grapheme(text), width: width, style: style)
        )
        x += Int(width)
      }
      while let last = cells.last, last.grapheme == 0, last.style == 0 {
        cells.removeLast()
      }
      rows.append(SavedOutputRow(wrapped: grid.isWrapped(row: y), cells: cells))
      if rows.count > SavedOutput.maxRows { rows.removeFirst() }
    }
  }

  /// The newest rows within the byte bound.
  public func build() -> SavedOutput {
    var output = SavedOutput(
      columns: columns,
      palette: palette,
      defaultForeground: foreground,
      defaultBackground: background,
      styles: styles,
      graphemes: graphemes,
      rows: rows
    )
    while !output.rows.isEmpty, (try? output.encoded()) == nil {
      output.rows.removeFirst(min(output.rows.count, 100))
    }
    return output
  }

  private static func text(_ frame: PaneFrame, glyph: UInt32) -> String {
    if glyph & FrameGrid.graphemeFlag != 0 {
      let index = Int(glyph & ~FrameGrid.graphemeFlag)
      guard index < frame.graphemes.count else { return " " }
      var text = ""
      for scalar in frame.graphemes[index]
        .prefix(SavedOutput.maxGraphemeScalars)
      {
        if let value = Unicode.Scalar(scalar) {
          text.unicodeScalars.append(value)
        }
      }
      return text.isEmpty ? " " : text
    }
    guard glyph >= 0x20, let scalar = Unicode.Scalar(glyph) else { return " " }
    return String(Character(scalar))
  }

  private mutating func grapheme(_ text: String) -> UInt32 {
    if let index = graphemeIndex[text] { return index }
    let index = UInt32(graphemes.count)
    graphemes.append(text)
    graphemeIndex[text] = index
    return index
  }

  private mutating func style(_ frame: PaneFrame, index: Int) -> UInt16 {
    guard index < frame.styles.count else { return 0 }
    let source = frame.styles[index]
    let underline =
      source.underlineColor > 0
        && Int(source.underlineColor) - 1 < frame.underlineColors.count
      ? frame.underlineColors[Int(source.underlineColor) - 1] : 0
    let style = SavedOutputStyle(
      foreground: source.foreground,
      background: source.background,
      underline: underline,
      flags: source.flags
    )
    if let existing = styleIndex[style] { return existing }
    guard styles.count < SavedOutput.maxStyles else { return 0 }
    let value = UInt16(styles.count)
    styles.append(style)
    styleIndex[style] = value
    return value
  }
}

/// One page of a pane's saved output (gateway-only, `savedLayoutMetadata`).
public struct SavedOutputPage: Codable, Sendable, Equatable {
  /// Advances with applied main-screen changes.
  public var revision: UInt64
  /// False: unchanged since the requested revision; no bytes follow.
  public var modified: Bool
  public var total: Int
  public var offset: Int
  public var bytes: Data
  /// Pages are at most this size, below `maxControlRecordBytes`.
  public static let maxBytes = 192 << 10

  public init(
    revision: UInt64,
    modified: Bool,
    total: Int,
    offset: Int,
    bytes: Data
  ) {
    self.revision = revision
    self.modified = modified
    self.total = total
    self.offset = offset
    self.bytes = bytes
  }
}
