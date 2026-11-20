import SessionCore

/// Cursor shapes in the presentation profile.
public enum CursorShape: String, Hashable, Sendable, Codable {
  case block, underline, bar
}

public enum ActiveBuffer: String, Hashable, Sendable, Codable {
  case primary, alternate
}

/// A resolved color: `nil` in a style means the client's default.
public struct RGBColor: Hashable, Sendable, Codable {
  public var rgb: UInt32  // 0xRRGGBB

  public init(_ rgb: UInt32) { self.rgb = rgb & 0xFF_FFFF }

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer().decode(UInt32.self)
    guard value <= 0xFF_FFFF else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "bad color")
      )
    }
    rgb = value
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rgb)
  }
}

/// Text attributes in the RST/1 presentation profile. Hyperlinks,
/// protection and other host-only attributes are not transmitted.
public struct TextAttributes: OptionSet, Hashable, Sendable, Codable {
  public var rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public static let bold = TextAttributes(rawValue: 1 << 0)
  public static let faint = TextAttributes(rawValue: 1 << 1)
  public static let italic = TextAttributes(rawValue: 1 << 2)
  public static let underline = TextAttributes(rawValue: 1 << 3)
  public static let doubleUnderline = TextAttributes(rawValue: 1 << 4)
  public static let curlyUnderline = TextAttributes(rawValue: 1 << 5)
  public static let dottedUnderline = TextAttributes(rawValue: 1 << 6)
  public static let dashedUnderline = TextAttributes(rawValue: 1 << 7)
  public static let blink = TextAttributes(rawValue: 1 << 8)
  public static let inverse = TextAttributes(rawValue: 1 << 9)
  public static let invisible = TextAttributes(rawValue: 1 << 10)
  public static let strikethrough = TextAttributes(rawValue: 1 << 11)
  public static let overline = TextAttributes(rawValue: 1 << 12)

  public static let all = TextAttributes(rawValue: (1 << 13) - 1)

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(UInt16.self)
    guard raw & ~Self.all.rawValue == 0 else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "bad attributes"
        )
      )
    }
    rawValue = raw
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
  }
}

public struct CellStyle: Hashable, Sendable, Codable {
  public var foreground: RGBColor?
  public var background: RGBColor?
  public var underlineColor: RGBColor?
  public var attributes: TextAttributes

  public init(
    foreground: RGBColor? = nil,
    background: RGBColor? = nil,
    underlineColor: RGBColor? = nil,
    attributes: TextAttributes = []
  ) {
    self.foreground = foreground
    self.background = background
    self.underlineColor = underlineColor
    self.attributes = attributes
  }

  public static let plain = CellStyle()

  enum CodingKeys: String, CodingKey {
    case foreground = "fg"
    case background = "bg"
    case underlineColor = "ul"
    case attributes = "a"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    foreground = try c.decodeIfPresent(RGBColor.self, forKey: .foreground)
    background = try c.decodeIfPresent(RGBColor.self, forKey: .background)
    underlineColor = try c.decodeIfPresent(
      RGBColor.self,
      forKey: .underlineColor
    )
    attributes =
      try c.decodeIfPresent(TextAttributes.self, forKey: .attributes) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(foreground, forKey: .foreground)
    try c.encodeIfPresent(background, forKey: .background)
    try c.encodeIfPresent(underlineColor, forKey: .underlineColor)
    if !attributes.isEmpty { try c.encode(attributes, forKey: .attributes) }
  }
}

/// One cell: complete grapheme text, display width and style index.
///
/// Width is 1 for a narrow cell, 2 for the lead of a wide cell, and 0 for
/// the continuation that follows a wide lead. Empty text is a blank cell.
/// Encoded compactly as `[text, width, style]`.
public struct ScreenCell: Hashable, Sendable, Codable {
  public var text: String
  public var width: UInt8
  public var style: Int

  public init(_ text: String = "", width: UInt8 = 1, style: Int = 0) {
    self.text = text
    self.width = width
    self.style = style
  }

  public static let blank = ScreenCell()
  public static let continuation = ScreenCell("", width: 0, style: 0)

  public init(from decoder: any Decoder) throws {
    var c = try decoder.unkeyedContainer()
    text = try c.decode(String.self)
    width = try c.decode(UInt8.self)
    style = try c.decode(Int.self)
    guard c.isAtEnd else {
      throw DecodingError.dataCorruptedError(
        in: c,
        debugDescription: "extra cell fields"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.unkeyedContainer()
    try c.encode(text)
    try c.encode(width)
    try c.encode(style)
  }
}

public struct ScreenCursor: Hashable, Sendable, Codable {
  public var row: Int
  public var column: Int
  public var visible: Bool
  public var shape: CursorShape
  public var blinking: Bool

  public init(
    row: Int,
    column: Int,
    visible: Bool = true,
    shape: CursorShape = .block,
    blinking: Bool = false
  ) {
    self.row = row
    self.column = column
    self.visible = visible
    self.shape = shape
    self.blinking = blinking
  }
}

/// A complete, owned presentation of the host's selected viewport
/// (spec §6). Never borrowed emulator memory.
public struct ScreenSnapshot: Hashable, Sendable, Codable {
  public var sessionID: SessionID
  public var attachmentEpoch: UInt64
  public var screenRevision: UInt64
  public var resizeRevision: UInt64
  public var columns: Int
  public var rows: Int
  public var activeBuffer: ActiveBuffer
  public var cursor: ScreenCursor
  public var reverseVideo: Bool
  public var title: String
  /// One flag per row: the row soft-wraps into the next.
  public var wrapped: [Bool]
  public var styles: [CellStyle]
  /// `rows` rows of exactly `columns` cells.
  public var cells: [[ScreenCell]]
  /// Informational; not proof of visible echo.
  public var lastFullyAppliedInputSequence: UInt64

  public init(
    sessionID: SessionID,
    attachmentEpoch: UInt64,
    screenRevision: UInt64,
    resizeRevision: UInt64,
    columns: Int,
    rows: Int,
    activeBuffer: ActiveBuffer = .primary,
    cursor: ScreenCursor,
    reverseVideo: Bool = false,
    title: String = "",
    wrapped: [Bool],
    styles: [CellStyle],
    cells: [[ScreenCell]],
    lastFullyAppliedInputSequence: UInt64 = 0
  ) {
    self.sessionID = sessionID
    self.attachmentEpoch = attachmentEpoch
    self.screenRevision = screenRevision
    self.resizeRevision = resizeRevision
    self.columns = columns
    self.rows = rows
    self.activeBuffer = activeBuffer
    self.cursor = cursor
    self.reverseVideo = reverseVideo
    self.title = title
    self.wrapped = wrapped
    self.styles = styles
    self.cells = cells
    self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
  }

  public static func blank(
    sessionID: SessionID,
    columns: Int,
    rows: Int
  ) -> ScreenSnapshot {
    ScreenSnapshot(
      sessionID: sessionID,
      attachmentEpoch: 0,
      screenRevision: 0,
      resizeRevision: 0,
      columns: columns,
      rows: rows,
      cursor: ScreenCursor(row: 0, column: 0),
      wrapped: Array(repeating: false, count: rows),
      styles: [.plain],
      cells: Array(
        repeating: Array(repeating: .blank, count: columns),
        count: rows
      )
    )
  }

  enum CodingKeys: String, CodingKey {
    case sessionID, attachmentEpoch, screenRevision, resizeRevision, columns,
      rows, activeBuffer, cursor, reverseVideo, title, wrapped, styles, cells,
      lastFullyAppliedInputSequence
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try c.decode(SessionID.self, forKey: .sessionID)
    attachmentEpoch = try c.decode(WireUInt64.self, forKey: .attachmentEpoch)
      .value
    screenRevision = try c.decode(WireUInt64.self, forKey: .screenRevision)
      .value
    resizeRevision = try c.decode(WireUInt64.self, forKey: .resizeRevision)
      .value
    columns = try c.decode(Int.self, forKey: .columns)
    rows = try c.decode(Int.self, forKey: .rows)
    // Bound before decoding variable-length members.
    guard (1 ... RSTLimits.maxColumns).contains(columns),
      (1 ... RSTLimits.maxRows).contains(rows)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .columns,
        in: c,
        debugDescription: "grid out of range"
      )
    }
    activeBuffer = try c.decode(ActiveBuffer.self, forKey: .activeBuffer)
    cursor = try c.decode(ScreenCursor.self, forKey: .cursor)
    reverseVideo = try c.decode(Bool.self, forKey: .reverseVideo)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    wrapped = try c.decode([Bool].self, forKey: .wrapped)
    styles = try c.decode([CellStyle].self, forKey: .styles)
    cells = try c.decode([[ScreenCell]].self, forKey: .cells)
    lastFullyAppliedInputSequence =
      try c.decode(WireUInt64.self, forKey: .lastFullyAppliedInputSequence)
      .value
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(sessionID, forKey: .sessionID)
    try c.encode(WireUInt64(attachmentEpoch), forKey: .attachmentEpoch)
    try c.encode(WireUInt64(screenRevision), forKey: .screenRevision)
    try c.encode(WireUInt64(resizeRevision), forKey: .resizeRevision)
    try c.encode(columns, forKey: .columns)
    try c.encode(rows, forKey: .rows)
    try c.encode(activeBuffer, forKey: .activeBuffer)
    try c.encode(cursor, forKey: .cursor)
    try c.encode(reverseVideo, forKey: .reverseVideo)
    if !title.isEmpty { try c.encode(title, forKey: .title) }
    try c.encode(wrapped, forKey: .wrapped)
    try c.encode(styles, forKey: .styles)
    try c.encode(cells, forKey: .cells)
    try c.encode(
      WireUInt64(lastFullyAppliedInputSequence),
      forKey: .lastFullyAppliedInputSequence
    )
  }

  /// Plain text of each row (tests and accessibility).
  public var textLines: [String] {
    cells.map { row in
      var line = ""
      for cell in row where cell.width != 0 {
        line += cell.text.isEmpty ? " " : cell.text
      }
      while line.last == " " { line.removeLast() }
      return line
    }
  }
}

public enum SnapshotValidationError: Error, Equatable, Sendable {
  case gridOutOfRange
  case rowCountMismatch
  case columnCountMismatch(row: Int)
  case styleTableSize
  case styleIndex(row: Int, column: Int)
  case invalidWidth(row: Int, column: Int)
  case orphanContinuation(row: Int, column: Int)
  case missingContinuation(row: Int, column: Int)
  case graphemeTooLong(row: Int, column: Int)
  case controlCharacter(row: Int, column: Int)
  case cursorOutOfRange
  case titleTooLong
  case wrongSession
  case staleEpoch
}

extension ScreenSnapshot {
  /// Validates bounds and cell structure before any rendering
  /// (spec §6, §12, §A.4.3).
  public func validate(
    limits: NegotiatedLimits = NegotiatedLimits()
  ) throws(SnapshotValidationError) {
    guard limits.effective.contains(GridSize(columns: columns, rows: rows))
    else { throw .gridOutOfRange }
    guard cells.count == rows, wrapped.count == rows else {
      throw .rowCountMismatch
    }
    guard !styles.isEmpty, styles.count <= RSTLimits.maxStyles,
      styles.count <= columns * rows + 1
    else { throw .styleTableSize }
    guard title.utf8.count <= RSTLimits.maxTitleBytes else {
      throw .titleTooLong
    }
    // The cursor may sit one past the last column (pending wrap).
    guard (0 ..< rows).contains(cursor.row),
      (0 ... columns).contains(cursor.column)
    else { throw .cursorOutOfRange }
    for (y, row) in cells.enumerated() {
      guard row.count == columns else { throw .columnCountMismatch(row: y) }
      var x = 0
      while x < columns {
        let cell = row[x]
        guard cell.style >= 0, cell.style < styles.count else {
          throw .styleIndex(row: y, column: x)
        }
        guard cell.text.utf8.count <= RSTLimits.maxGraphemeBytes else {
          throw .graphemeTooLong(row: y, column: x)
        }
        for scalar in cell.text.unicodeScalars
        where scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value) {
          throw .controlCharacter(row: y, column: x)
        }
        switch cell.width {
        case 0: throw .orphanContinuation(row: y, column: x)
        case 1: x += 1
        case 2:
          guard x + 1 < columns, row[x + 1].width == 0, row[x + 1].text.isEmpty
          else { throw .missingContinuation(row: y, column: x) }
          guard row[x + 1].style >= 0, row[x + 1].style < styles.count else {
            throw .styleIndex(row: y, column: x + 1)
          }
          x += 2
        default: throw .invalidWidth(row: y, column: x)
        }
      }
    }
  }
}
