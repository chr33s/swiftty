import Checksum
import Foundation

/// A row's address plus its edit version (spec.multiplexer.md §4, "Row
/// identity and versions"). Equal identities mean equal row content.
public struct RowIdentity: Codable, Sendable, Hashable {
  public var address: HistoryAddress
  public var version: UInt64

  public init(address: HistoryAddress, version: UInt64) {
    self.address = address
    self.version = version
  }
}

/// What the service remembers of the frame a client installed: enough to
/// say which of its rows a new frame can copy, without any cells.
public struct FrameBaseline: Sendable, Equatable {
  public var revision: UInt64
  public var columns: Int
  public var rows: Int
  public var alternateScreen: Bool
  public var generation: UInt64
  public var geometryGeneration: UInt64
  public var identities: [RowIdentity]
  /// A delta omits the palette while it equals this one.
  public var palette: FramePalette

  /// Nil for a frame without row versions; it cannot be a delta base.
  public init?(_ frame: PaneFrame) {
    guard let identities = frame.rowIdentities else { return nil }
    revision = frame.identity.revision
    columns = frame.grid.columns
    rows = frame.grid.rows
    alternateScreen = frame.grid.alternateScreen
    generation = frame.history.generation
    geometryGeneration = frame.identity.geometryGeneration
    self.identities = identities
    palette = frame.palette
  }
}

/// A frame expressed against an installed base frame (spec.multiplexer.md
/// §4, "Frame deltas"). Rows are copied from the base by index or carried
/// in `replaced`; every non-cell part of the frame is carried in full.
public struct FrameDelta: Codable, Sendable, Equatable {
  /// `rowSources` entry for a row taken from `replaced`, in order.
  public static let replacedRow: Int32 = -1

  public var identity: FrameIdentity
  public var baseRevision: UInt64
  public var columns: Int
  public var rows: Int
  public var alternateScreen: Bool
  /// Per row: a base row index to copy, or `replacedRow`.
  public var rowSources: [Int32]
  /// The replaced rows only (`rows` may be zero), referring to the tables
  /// below, which belong to this delta alone.
  public var replaced: FrameGrid
  public var graphemes: [[UInt32]]
  public var styles: [FrameStyle]
  public var underlineColors: [UInt32]
  /// Versions of the replaced rows, in order; a copied row keeps its
  /// base row's version.
  public var replacedVersions: [UInt64]
  /// Nil while the palette equals the base's.
  public var palette: FramePalette?
  public var cursor: FrameCursor
  public var modes: SupportedViewModes
  public var history: HistoryWindow
  public var search: FrameSearch?
  public var title: String
  public var dropTarget: FrameDropTarget?
  /// CRC-32C over the result's ordered row identities.
  public var identityChecksum: UInt32

  public init(
    identity: FrameIdentity,
    baseRevision: UInt64,
    columns: Int,
    rows: Int,
    alternateScreen: Bool,
    rowSources: [Int32],
    replaced: FrameGrid,
    graphemes: [[UInt32]],
    styles: [FrameStyle],
    underlineColors: [UInt32],
    replacedVersions: [UInt64],
    palette: FramePalette?,
    cursor: FrameCursor,
    modes: SupportedViewModes,
    history: HistoryWindow,
    search: FrameSearch?,
    title: String,
    dropTarget: FrameDropTarget?,
    identityChecksum: UInt32
  ) {
    self.identity = identity
    self.baseRevision = baseRevision
    self.columns = columns
    self.rows = rows
    self.alternateScreen = alternateScreen
    self.rowSources = rowSources
    self.replaced = replaced
    self.graphemes = graphemes
    self.styles = styles
    self.underlineColors = underlineColors
    self.replacedVersions = replacedVersions
    self.palette = palette
    self.cursor = cursor
    self.modes = modes
    self.history = history
    self.search = search
    self.title = title
    self.dropTarget = dropTarget
    self.identityChecksum = identityChecksum
  }

  public var replacedCount: Int { replaced.rows }
}

// MARK: Building

public enum FrameDeltaBuilder {
  /// The delta that turns `base` into `frame`, or nil when a full frame
  /// must be sent: no versions, a different size, screen or history
  /// generation, a geometry change, or at least half the rows replaced.
  public static func delta(
    from frame: PaneFrame,
    base: FrameBaseline
  ) -> FrameDelta? {
    let g = frame.grid
    guard let versions = frame.rowVersions, versions.count == g.rows,
      base.columns == g.columns, base.rows == g.rows,
      base.alternateScreen == g.alternateScreen,
      base.generation == frame.history.generation,
      base.geometryGeneration == frame.identity.geometryGeneration,
      base.identities.count == base.rows,
      base.revision < frame.identity.revision
    else { return nil }
    var index: [RowIdentity: Int32] = [:]
    index.reserveCapacity(base.rows)
    for (k, identity) in base.identities.enumerated()
    where index[identity] == nil { index[identity] = Int32(k) }
    var sources = [Int32](repeating: FrameDelta.replacedRow, count: g.rows)
    var replacedRows: [Int] = []
    for y in 0 ..< g.rows {
      if let k = index[frame.rowIdentity(y)!] {
        sources[y] = k
      } else {
        replacedRows.append(y)
      }
    }
    guard replacedRows.count * 2 < g.rows else { return nil }
    let extracted = extract(rows: replacedRows, of: frame)
    let identities = frame.rowIdentities!
    return FrameDelta(
      identity: frame.identity,
      baseRevision: base.revision,
      columns: g.columns,
      rows: g.rows,
      alternateScreen: g.alternateScreen,
      rowSources: sources,
      replaced: extracted.grid,
      graphemes: extracted.graphemes,
      styles: extracted.styles,
      underlineColors: extracted.underlineColors,
      replacedVersions: replacedRows.map { versions[$0] },
      palette: frame.palette == base.palette ? nil : frame.palette,
      cursor: frame.cursor,
      modes: frame.modes,
      history: frame.history,
      search: frame.search,
      title: frame.title,
      dropTarget: frame.dropTarget,
      identityChecksum: RowChecksum.identities(identities)
    )
  }

  struct Extracted {
    var grid: FrameGrid
    var graphemes: [[UInt32]]
    var styles: [FrameStyle]
    var underlineColors: [UInt32]
  }

  /// Copies `rows` of `frame` into a grid with compacted tables.
  static func extract(rows: [Int], of frame: PaneFrame) -> Extracted {
    let columns = frame.grid.columns
    var tables = TableInterner()
    var styleMap = [Int32](repeating: -1, count: frame.styles.count)
    let count = rows.count * columns
    var glyphs = [UInt32](repeating: 0, count: count)
    var styles = [UInt16](repeating: 0, count: count)
    var kinds = [UInt8](repeating: 0, count: count)
    var wrapped = [UInt8](repeating: 0, count: rows.count)
    let g = frame.grid
    for (r, y) in rows.enumerated() {
      wrapped[r] = g.isWrapped(row: y) ? 1 : 0
      for x in 0 ..< columns {
        let i = y * columns + x
        let o = r * columns + x
        kinds[o] = g.kinds[g.kinds.startIndex + i]
        let s = g.style(at: i)
        if styleMap[s] < 0 {
          styleMap[s] = Int32(
            tables.style(
              frame.styles[s],
              underlineColors: frame.underlineColors
            )
          )
        }
        styles[o] = UInt16(styleMap[s])
        let glyph = g.glyph(at: i)
        if glyph & FrameGrid.graphemeFlag != 0 {
          glyphs[o] = tables.grapheme(
            frame.graphemes[Int(glyph & ~FrameGrid.graphemeFlag)]
          )
        } else {
          glyphs[o] = glyph
        }
      }
    }
    return Extracted(
      grid: FrameGrid(
        columns: columns,
        rows: rows.count,
        alternateScreen: g.alternateScreen,
        wrapped: Data(wrapped),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: styles.withUnsafeBytes { Data($0) },
        kinds: Data(kinds)
      ),
      graphemes: tables.graphemes,
      styles: tables.styles,
      underlineColors: tables.underlineColors
    )
  }
}

/// Builds frame-local tables, sharing equal styles and underline colors.
struct TableInterner {
  var styles: [FrameStyle] = []
  var underlineColors: [UInt32] = []
  var graphemes: [[UInt32]] = []
  private var styleIndex: [FrameStyle: Int] = [:]
  private var underlineIndex: [UInt32: Int] = [:]

  /// `style` refers to `underlineColors` of its own table; the result
  /// refers to this interner's table.
  mutating func style(
    _ style: FrameStyle,
    underlineColors source: [UInt32]
  ) -> Int {
    var resolved = style
    if style.underlineColor != 0 {
      let color = source[Int(style.underlineColor) - 1]
      let index: Int
      if let known = underlineIndex[color] {
        index = known
      } else {
        index = underlineColors.count
        underlineColors.append(color)
        underlineIndex[color] = index
      }
      resolved.underlineColor = UInt8(truncatingIfNeeded: index + 1)
    }
    if let known = styleIndex[resolved] { return known }
    let index = styles.count
    styles.append(resolved)
    styleIndex[resolved] = index
    return index
  }

  mutating func grapheme(_ scalars: [UInt32]) -> UInt32 {
    let index = UInt32(graphemes.count)
    graphemes.append(scalars)
    return FrameGrid.graphemeFlag | index
  }
}

// MARK: Applying

public enum FrameDeltaApplier {
  /// The frame `delta` describes, built from `base`. Throws without a
  /// partial result when the base does not match or the result is invalid.
  public static func apply(
    _ delta: FrameDelta,
    to base: PaneFrame,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> PaneFrame {
    let b = base.grid
    let id = delta.identity
    guard base.identity.revision == delta.baseRevision,
      base.identity.pane == id.pane, base.identity.server == id.server,
      base.identity.attachment == id.attachment,
      base.identity.geometryGeneration == id.geometryGeneration,
      b.columns == delta.columns, b.rows == delta.rows,
      b.alternateScreen == delta.alternateScreen,
      base.history.generation == delta.history.generation
    else { throw MuxError(.staleRevision, "delta base mismatch") }
    try validateShape(delta, limits: limits)
    let columns = delta.columns
    guard let count = limits.cellCount(columns: columns, rows: delta.rows)
    else { throw MuxError(.invalidRequest, "delta dimensions") }
    var tables = TableInterner()
    var baseStyles = [Int32](repeating: -1, count: base.styles.count)
    var deltaStyles = [Int32](repeating: -1, count: delta.styles.count)
    var glyphs = [UInt32](repeating: 0, count: count)
    var styles = [UInt16](repeating: 0, count: count)
    var kinds = [UInt8](repeating: 0, count: count)
    var wrapped = [UInt8](repeating: 0, count: delta.rows)
    let r = delta.replaced
    var next = 0
    // A copied row keeps its base row's version; it must have one.
    guard let baseVersions = base.rowVersions, baseVersions.count == b.rows
    else { throw MuxError(.staleRevision, "delta base without row versions") }
    var versions = [UInt64](repeating: 0, count: delta.rows)
    var identities: [RowIdentity] = []
    identities.reserveCapacity(delta.rows)
    do {
      var replacedIndex = 0
      for y in 0 ..< delta.rows {
        let source = delta.rowSources[y]
        if source == FrameDelta.replacedRow {
          versions[y] = delta.replacedVersions[replacedIndex]
          replacedIndex += 1
        } else {
          versions[y] = baseVersions[Int(source)]
        }
        identities.append(
          RowIdentity(
            address: delta.history.address(
              viewportRow: y,
              alternateScreen: delta.alternateScreen
            ),
            version: versions[y]
          )
        )
      }
    }
    for y in 0 ..< delta.rows {
      let source = delta.rowSources[y]
      if source == FrameDelta.replacedRow {
        let row = next
        next += 1
        wrapped[y] = r.isWrapped(row: row) ? 1 : 0
        for x in 0 ..< columns {
          let i = row * columns + x
          let o = y * columns + x
          kinds[o] = r.kinds[r.kinds.startIndex + i]
          let s = r.style(at: i)
          if deltaStyles[s] < 0 {
            deltaStyles[s] = Int32(
              tables.style(
                delta.styles[s],
                underlineColors: delta.underlineColors
              )
            )
          }
          styles[o] = UInt16(deltaStyles[s])
          let glyph = r.glyph(at: i)
          glyphs[o] =
            glyph & FrameGrid.graphemeFlag != 0
            ? tables.grapheme(
              delta.graphemes[Int(glyph & ~FrameGrid.graphemeFlag)]
            ) : glyph
        }
      } else {
        let k = Int(source)
        if let known = base.rowIdentity(k), known != identities[y] {
          throw MuxError(.staleRevision, "delta row identity mismatch")
        }
        wrapped[y] = b.isWrapped(row: k) ? 1 : 0
        for x in 0 ..< columns {
          let i = k * columns + x
          let o = y * columns + x
          kinds[o] = b.kinds[b.kinds.startIndex + i]
          let s = b.style(at: i)
          if baseStyles[s] < 0 {
            baseStyles[s] = Int32(
              tables.style(
                base.styles[s],
                underlineColors: base.underlineColors
              )
            )
          }
          styles[o] = UInt16(baseStyles[s])
          let glyph = b.glyph(at: i)
          glyphs[o] =
            glyph & FrameGrid.graphemeFlag != 0
            ? tables.grapheme(
              base.graphemes[Int(glyph & ~FrameGrid.graphemeFlag)]
            ) : glyph
        }
      }
    }
    guard tables.styles.count <= limits.maxStyles,
      tables.underlineColors.count <= 63
    else { throw MuxError(.invalidRequest, "delta tables") }
    if tables.styles.isEmpty { tables.styles = [.plain] }
    let frame = PaneFrame(
      identity: delta.identity,
      grid: FrameGrid(
        columns: columns,
        rows: delta.rows,
        alternateScreen: delta.alternateScreen,
        wrapped: Data(wrapped),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: styles.withUnsafeBytes { Data($0) },
        kinds: Data(kinds)
      ),
      graphemes: tables.graphemes,
      styles: tables.styles,
      underlineColors: tables.underlineColors,
      palette: delta.palette ?? base.palette,
      cursor: delta.cursor,
      modes: delta.modes,
      history: delta.history,
      search: delta.search,
      title: delta.title,
      dropTarget: delta.dropTarget,
      rowVersions: versions
    )
    guard RowChecksum.identities(identities) == delta.identityChecksum else {
      throw MuxError(.staleRevision, "delta identity checksum")
    }
    try FrameValidator.validate(frame, limits: limits)
    return frame
  }

  /// Bounds and references of the delta's own parts, before any copying.
  static func validateShape(
    _ delta: FrameDelta,
    limits: MuxLimits
  ) throws(MuxError) {
    guard limits.cellCount(columns: delta.columns, rows: delta.rows) != nil,
      delta.rowSources.count == delta.rows, delta.history.isBounded
    else { throw MuxError(.invalidRequest, "delta rows") }
    var replaced = 0
    for source in delta.rowSources {
      if source == FrameDelta.replacedRow {
        replaced += 1
      } else {
        guard source >= 0, Int(source) < delta.rows else {
          throw MuxError(.invalidRequest, "delta row source")
        }
      }
    }
    guard delta.replacedVersions.count == replaced else {
      throw MuxError(.invalidRequest, "delta replaced versions")
    }
    let r = delta.replaced
    let (cells, overflow) = replaced.multipliedReportingOverflow(
      by: delta.columns
    )
    guard !overflow, r.rows == replaced, r.columns == delta.columns,
      r.alternateScreen == delta.alternateScreen, r.wrapped.count == replaced,
      r.kinds.count == cells, r.styles.count == cells * 2,
      r.glyphs.count == cells * 4
    else { throw MuxError(.invalidRequest, "delta replaced rows") }
    guard delta.styles.count <= limits.maxStyles,
      delta.underlineColors.count <= 63, delta.graphemes.count <= cells
    else { throw MuxError(.invalidRequest, "delta tables") }
    for style in delta.styles
    where Int(style.underlineColor) > delta.underlineColors.count {
      throw MuxError(.invalidRequest, "delta style entry")
    }
    for i in 0 ..< cells {
      guard r.style(at: i) < delta.styles.count else {
        throw MuxError(.invalidRequest, "delta style index")
      }
      let glyph = r.glyph(at: i)
      if glyph & FrameGrid.graphemeFlag != 0 {
        guard Int(glyph & ~FrameGrid.graphemeFlag) < delta.graphemes.count
        else { throw MuxError(.invalidRequest, "delta grapheme reference") }
      }
    }
  }
}

// MARK: Checksum

/// CRC-32C over row identities (`Checksum.CRC32C`).
public enum RowChecksum {
  /// Checksum over ordered identities: generation, screen, row, version.
  public static func identities(_ identities: [RowIdentity]) -> UInt32 {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(identities.count * 25)
    for identity in identities {
      withUnsafeBytes(of: identity.address.generation.littleEndian) {
        bytes.append(contentsOf: $0)
      }
      bytes.append(identity.address.alternateScreen ? 1 : 0)
      withUnsafeBytes(of: Int64(identity.address.row).littleEndian) {
        bytes.append(contentsOf: $0)
      }
      withUnsafeBytes(of: identity.version.littleEndian) {
        bytes.append(contentsOf: $0)
      }
    }
    return CRC32C.checksum(bytes)
  }
}
