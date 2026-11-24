import Foundation

/// `SMXB/1`: little-endian binary encoding of exactly the `PaneFrame` and
/// `FrameDelta` value models (spec.multiplexer.md §4, "Binary frame
/// codec"). One record is a 10-byte header and tagged sections in
/// ascending tag order. The envelope is SwiftMux's frame identity or an
/// opaque RST/1 header that `ScreenProtocol` parses.
public enum SMXB {
  public static let magic: [UInt8] = Array("SMXB".utf8)
  public static let version: UInt8 = 1
  public static let headerBytes = 10

  public enum Kind: UInt8, Sendable {
    case full = 0
    case delta = 1
  }

  /// Who owns the record's identity.
  public enum Envelope: Sendable, Equatable {
    /// SwiftMux: the frame's `FrameIdentity` is authoritative.
    case mux
    /// RST/1: these header bytes are authoritative; the decoded frame
    /// carries `FrameIdentity.unbound`.
    case rst(Data)
  }

  public enum Payload: Sendable, Equatable {
    case frame(PaneFrame)
    case delta(FrameDelta)
  }

  public struct Record: Sendable, Equatable {
    public var envelope: Envelope
    public var payload: Payload

    public init(envelope: Envelope, payload: Payload) {
      self.envelope = envelope
      self.payload = payload
    }
  }

  enum Tag: UInt8, Comparable {
    case identity = 1
    case rstHeader = 2
    case grid = 3
    case rowVersions = 4
    case wrapped = 5
    case glyphs = 6
    case cellStyles = 7
    case kinds = 8
    case graphemes = 9
    case styleTable = 10
    case underlineColors = 11
    case palette = 12
    case cursor = 13
    case modes = 14
    case history = 15
    case search = 16
    case title = 17
    case dropTarget = 18
    case images = 19
    case deltaHeader = 20
    case rowSources = 21
    case replacedRows = 22

    static func < (a: Tag, b: Tag) -> Bool { a.rawValue < b.rawValue }
  }

  /// True when `data` starts with the record magic (JSON never does).
  public static func isRecord(_ data: Data) -> Bool {
    data.count >= magic.count && data.prefix(magic.count).elementsEqual(magic)
  }

  // MARK: Encoding

  public static func encode(
    _ frame: PaneFrame,
    envelope: Envelope = .mux
  ) -> Data {
    var w = Writer(kind: .full)
    w.envelope(envelope, identity: frame.identity)
    w.grid(frame.grid.columns, frame.grid.rows, frame.grid.alternateScreen)
    if let versions = frame.rowVersions { w.rowVersions(versions) }
    w.cells(frame.grid)
    w.tables(frame.graphemes, frame.styles, frame.underlineColors)
    w.metadata(
      frame.palette,
      frame.cursor,
      frame.modes,
      frame.history,
      frame.search,
      frame.title,
      frame.dropTarget
    )
    if let images = frame.images { w.images(images) }
    return w.finish()
  }

  public static func encode(
    _ delta: FrameDelta,
    envelope: Envelope = .mux
  ) -> Data {
    var w = Writer(kind: .delta)
    w.envelope(envelope, identity: delta.identity)
    w.grid(delta.columns, delta.rows, delta.alternateScreen)
    // A delta's versions are its replaced rows'.
    w.rowVersions(delta.replacedVersions)
    w.cells(delta.replaced)
    w.tables(delta.graphemes, delta.styles, delta.underlineColors)
    w.metadata(
      delta.palette,
      delta.cursor,
      delta.modes,
      delta.history,
      delta.search,
      delta.title,
      delta.dropTarget
    )
    if let images = delta.images { w.images(images) }
    w.section(.deltaHeader) {
      $0.u64(delta.baseRevision)
      $0.u32(delta.identityChecksum)
    }
    w.section(.rowSources) { b in
      b.u32(UInt32(delta.rowSources.count))
      for s in delta.rowSources { b.u32(UInt32(bitPattern: s)) }
    }
    w.section(.replacedRows) { $0.u32(UInt32(delta.replaced.rows)) }
    return w.finish()
  }

  // MARK: Decoding

  /// Decodes and validates one record. A full frame is validated as a
  /// frame; a delta's own parts are validated, and the result is checked
  /// again when it is applied to its base.
  public static func decode(
    _ data: Data,
    limits: MuxLimits = .standard,
    maxBytes: Int? = nil
  ) throws(MuxError) -> Record {
    let cap = maxBytes ?? SMXCodec.serverRecordLimit(limits)
    guard data.count <= cap else {
      throw MuxError(.resourceLimit, "record of \(data.count) bytes")
    }
    let bytes = [UInt8](data)
    guard bytes.count >= headerBytes, isRecord(data), bytes[4] == version,
      let kind = Kind(rawValue: bytes[5])
    else { throw MuxError(.invalidRequest, "SMXB header") }
    let length = Int(Reader.loadU32(bytes, 6))
    guard length == bytes.count - headerBytes else {
      throw MuxError(.invalidRequest, "SMXB length")
    }
    var sections: [Tag: ArraySlice<UInt8>] = [:]
    var offset = headerBytes
    var last: Tag?
    while offset < bytes.count {
      guard bytes.count - offset >= 5, let tag = Tag(rawValue: bytes[offset])
      else { throw MuxError(.invalidRequest, "SMXB section") }
      let size = Int(Reader.loadU32(bytes, offset + 1))
      let start = offset + 5
      guard size <= bytes.count - start else {
        throw MuxError(.invalidRequest, "SMXB section length")
      }
      if let last, tag <= last {
        throw MuxError(.invalidRequest, "SMXB section order")
      }
      last = tag
      sections[tag] = bytes[start ..< start + size]
      offset = start + size
    }
    return try Parser(sections: sections, kind: kind, limits: limits).record()
  }
}

extension FrameIdentity {
  /// Placeholder identity of a frame whose identity travels elsewhere
  /// (an RST/1 envelope).
  public static let unbound: FrameIdentity = {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    return FrameIdentity(
      server: ServerInstanceID(rawValue: zero),
      attachment: AttachmentID(rawValue: zero),
      pane: PaneID(rawValue: zero),
      revision: 0,
      layoutRevision: 0,
      geometryGeneration: 0,
      viewportRevision: 0
    )
  }()
}

// MARK: Writer

struct ByteBuffer {
  var bytes: [UInt8] = []

  mutating func u8(_ v: UInt8) { bytes.append(v) }
  mutating func u16(_ v: UInt16) {
    withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
  }
  mutating func u32(_ v: UInt32) {
    withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
  }
  mutating func u64(_ v: UInt64) {
    withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
  }
  mutating func i64(_ v: Int) { u64(UInt64(bitPattern: Int64(v))) }
  mutating func optionalIndex(_ v: Int?) { i64(v ?? -1) }
  mutating func uuid(_ u: UUID) {
    withUnsafeBytes(of: u.uuid) { bytes.append(contentsOf: $0) }
  }
  mutating func data(_ d: Data) { bytes.append(contentsOf: d) }
  mutating func string(_ s: String) {
    let utf8 = Array(s.utf8)
    u32(UInt32(utf8.count))
    bytes.append(contentsOf: utf8)
  }
}

extension SMXB {
  struct Writer {
    var out = ByteBuffer()

    init(kind: Kind) {
      out.bytes.append(contentsOf: SMXB.magic)
      out.u8(SMXB.version)
      out.u8(kind.rawValue)
      out.u32(0)
    }

    mutating func section(_ tag: Tag, _ body: (inout ByteBuffer) -> Void) {
      var b = ByteBuffer()
      body(&b)
      out.u8(tag.rawValue)
      out.u32(UInt32(b.bytes.count))
      out.bytes.append(contentsOf: b.bytes)
    }

    mutating func envelope(_ envelope: Envelope, identity: FrameIdentity) {
      switch envelope {
      case .mux:
        section(.identity) {
          $0.uuid(identity.server.rawValue)
          $0.uuid(identity.attachment.rawValue)
          $0.uuid(identity.pane.rawValue)
          $0.u64(identity.revision)
          $0.u64(identity.layoutRevision)
          $0.u64(identity.geometryGeneration)
          $0.u64(identity.viewportRevision)
        }
      case let .rst(header): section(.rstHeader) { $0.data(header) }
      }
    }

    mutating func grid(_ columns: Int, _ rows: Int, _ alternate: Bool) {
      section(.grid) {
        $0.u32(UInt32(columns))
        $0.u32(UInt32(rows))
        $0.u8(alternate ? 1 : 0)
      }
    }

    mutating func rowVersions(_ versions: [UInt64]) {
      section(.rowVersions) { b in
        b.u32(UInt32(versions.count))
        for v in versions { b.u64(v) }
      }
    }

    /// Packed arrays are already little-endian; written as they are.
    mutating func cells(_ grid: FrameGrid) {
      section(.wrapped) { $0.data(grid.wrapped) }
      section(.glyphs) { $0.data(grid.glyphs) }
      section(.cellStyles) { $0.data(grid.styles) }
      section(.kinds) { $0.data(grid.kinds) }
    }

    mutating func tables(
      _ graphemes: [[UInt32]],
      _ styles: [FrameStyle],
      _ underline: [UInt32]
    ) {
      section(.graphemes) { b in
        b.u32(UInt32(graphemes.count))
        for g in graphemes {
          b.u16(UInt16(clamping: g.count))
          for s in g { b.u32(s) }
        }
      }
      section(.styleTable) { b in
        b.u32(UInt32(styles.count))
        for s in styles {
          b.u32(s.foreground)
          b.u32(s.background)
          b.u16(s.flags)
          b.u8(s.underlineColor)
        }
      }
      section(.underlineColors) { b in
        b.u32(UInt32(underline.count))
        for c in underline { b.u32(c) }
      }
    }

    // swiftlint:disable:next function_parameter_count
    mutating func metadata(
      _ palette: FramePalette?,
      _ cursor: FrameCursor,
      _ modes: SupportedViewModes,
      _ history: HistoryWindow,
      _ search: FrameSearch?,
      _ title: String,
      _ drop: FrameDropTarget?
    ) {
      if let palette {
        section(.palette) { b in
          b.u32(UInt32(palette.colors.count))
          for c in palette.colors { b.u32(c) }
          b.u32(palette.foreground)
          b.u32(palette.background)
          b.u32(palette.cursor)
          let optional = [
            palette.cursorText, palette.selectionForeground,
            palette.selectionBackground,
          ]
          var mask: UInt8 = 0
          for (i, v) in optional.enumerated() where v != nil { mask |= 1 << i }
          b.u8(mask)
          for v in optional { b.u32(v ?? 0) }
        }
      }

      section(.cursor) {
        $0.i64(cursor.x)
        $0.i64(cursor.y)
        $0.u8(cursor.visible ? 1 : 0)
        $0.u8(cursor.style)
        $0.u8(cursor.blinking ? 1 : 0)
      }
      section(.modes) { $0.u32(modes.rawValue) }
      section(.history) {
        $0.u64(history.generation)
        $0.i64(history.firstRow)
        $0.i64(history.availableRows)
        $0.i64(history.viewportTop)
        $0.i64(history.viewportOffset)
        $0.i64(history.scrollbackRows)
      }
      if let search {
        section(.search) { b in
          b.i64(search.matchCount)
          b.optionalIndex(search.selected)
          b.optionalIndex(search.selectedVisible)
          b.u32(UInt32(search.visible.count))
          for s in search.visible {
            b.i64(s.startRow)
            b.i64(s.startColumn)
            b.i64(s.endRow)
            b.i64(s.endColumn)
          }
        }
      }
      section(.title) { $0.data(Data(title.utf8)) }
      if let drop {
        section(.dropTarget) { b in
          b.u32(UInt32(drop.types.count))
          for t in drop.types { b.string(t) }
          let accepted: UInt8 =
            switch drop.accepted {
            case nil: 0
            case .none?: 1
            case .copy?: 2
            case .move?: 3
            }
          b.u8(accepted)
        }
      }
    }

    mutating func images(_ images: FrameImages) {
      section(.images) { b in
        b.u16(images.cellWidth)
        b.u16(images.cellHeight)
        b.u32(UInt32(images.images.count))
        for i in images.images {
          b.u64(i.key)
          b.u32(i.width)
          b.u32(i.height)
          b.u8(i.bytesPerPixel)
        }
        b.u32(UInt32(images.placements.count))
        for p in images.placements {
          b.u16(p.image)
          b.u8(p.layer)
          b.u32(UInt32(bitPattern: p.z))
          b.u8(p.placeholder ? 1 : 0)
          b.u32(UInt32(bitPattern: p.row))
          b.u32(UInt32(bitPattern: p.column))
          for v in [
            p.columns, p.rows, p.offsetX, p.offsetY, p.width, p.height,
            p.sourceX, p.sourceY, p.sourceWidth, p.sourceHeight,
          ] { b.u32(v) }
        }
        b.u32(UInt32(images.prefetch.count))
        for i in images.prefetch {
          b.u64(i.key)
          b.u32(i.width)
          b.u32(i.height)
          b.u8(i.bytesPerPixel)
        }
      }
    }

    mutating func finish() -> Data {
      let length = UInt32(out.bytes.count - SMXB.headerBytes).littleEndian
      withUnsafeBytes(of: length) { raw in
        for i in 0 ..< 4 { out.bytes[6 + i] = raw[i] }
      }
      return Data(out.bytes)
    }
  }
}

// MARK: Reader

struct Reader {
  let bytes: ArraySlice<UInt8>
  var offset: Int

  init(_ bytes: ArraySlice<UInt8>) {
    self.bytes = bytes
    offset = bytes.startIndex
  }

  static func loadU32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(
      b[i + 3]
    ) << 24
  }

  var remaining: Int { bytes.endIndex - offset }
  var atEnd: Bool { offset == bytes.endIndex }

  mutating func take(_ n: Int) throws(MuxError) -> ArraySlice<UInt8> {
    guard n >= 0, n <= remaining else {
      throw MuxError(.invalidRequest, "SMXB truncated section")
    }
    defer { offset += n }
    return bytes[offset ..< offset + n]
  }

  mutating func u8() throws(MuxError) -> UInt8 { try take(1).first! }
  mutating func u16() throws(MuxError) -> UInt16 {
    let s = try take(2)
    return UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8
  }
  mutating func u32() throws(MuxError) -> UInt32 {
    let s = try take(4)
    var v: UInt32 = 0
    for (k, b) in s.enumerated() { v |= UInt32(b) << (8 * UInt32(k)) }
    return v
  }
  mutating func u64() throws(MuxError) -> UInt64 {
    let s = try take(8)
    var v: UInt64 = 0
    for (k, b) in s.enumerated() { v |= UInt64(b) << (8 * UInt64(k)) }
    return v
  }
  mutating func i64() throws(MuxError) -> Int {
    let v = Int64(bitPattern: try u64())
    guard let i = Int(exactly: v) else {
      throw MuxError(.invalidRequest, "SMXB integer")
    }
    return i
  }
  mutating func optionalIndex() throws(MuxError) -> Int? {
    let v = try i64()
    guard v >= -1 else { throw MuxError(.invalidRequest, "SMXB index") }
    return v < 0 ? nil : v
  }
  mutating func bool() throws(MuxError) -> Bool {
    switch try u8() {
    case 0: return false
    case 1: return true
    default: throw MuxError(.invalidRequest, "SMXB flag")
    }
  }
  mutating func uuid() throws(MuxError) -> UUID {
    let s = Array(try take(16))
    return UUID(
      uuid: (
        s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10],
        s[11], s[12], s[13], s[14], s[15]
      )
    )
  }
  /// A count whose elements each need at least `unit` bytes.
  mutating func count(unit: Int) throws(MuxError) -> Int {
    let n = Int(try u32())
    guard n <= remaining / max(1, unit) else {
      throw MuxError(.invalidRequest, "SMXB count")
    }
    return n
  }
  func end() throws(MuxError) {
    guard atEnd else { throw MuxError(.invalidRequest, "SMXB trailing bytes") }
  }
}

extension SMXB {
  struct Parser {
    let sections: [Tag: ArraySlice<UInt8>]
    let kind: Kind
    let limits: MuxLimits

    func required(_ tag: Tag) throws(MuxError) -> Reader {
      guard let s = sections[tag] else {
        throw MuxError(.invalidRequest, "SMXB missing section \(tag.rawValue)")
      }
      return Reader(s)
    }

    func record() throws(MuxError) -> Record {
      let allowed: Set<Tag> =
        kind == .full
        ? [
          .identity, .rstHeader, .grid, .rowVersions, .wrapped, .glyphs,
          .cellStyles, .kinds, .graphemes, .styleTable, .underlineColors,
          .palette, .cursor, .modes, .history, .search, .title, .dropTarget,
          .images,
        ]
        : [
          .identity, .rstHeader, .grid, .rowVersions, .wrapped, .glyphs,
          .cellStyles, .kinds, .graphemes, .styleTable, .underlineColors,
          .palette, .cursor, .modes, .history, .search, .title, .dropTarget,
          .images, .deltaHeader, .rowSources, .replacedRows,
        ]
      guard Set(sections.keys).isSubset(of: allowed) else {
        throw MuxError(.invalidRequest, "SMXB section not allowed")
      }
      let envelope: Envelope
      var identity = FrameIdentity.unbound
      switch (sections[.identity], sections[.rstHeader]) {
      case (_?, nil):
        envelope = .mux
        var r = try required(.identity)
        identity = FrameIdentity(
          server: ServerInstanceID(rawValue: try r.uuid()),
          attachment: AttachmentID(rawValue: try r.uuid()),
          pane: PaneID(rawValue: try r.uuid()),
          revision: try r.u64(),
          layoutRevision: try r.u64(),
          geometryGeneration: try r.u64(),
          viewportRevision: try r.u64()
        )
        try r.end()
      case let (nil, header?): envelope = .rst(Data(header))
      default: throw MuxError(.invalidRequest, "SMXB envelope")
      }
      var g = try required(.grid)
      let columns = Int(try g.u32())
      let rows = Int(try g.u32())
      let alternate = try g.bool()
      try g.end()
      guard limits.cellCount(columns: columns, rows: rows) != nil else {
        throw MuxError(.invalidRequest, "SMXB dimensions \(columns)x\(rows)")
      }
      // Every row's version in a frame; the replaced rows' in a delta.
      var versions: [UInt64]?
      if sections[.rowVersions] != nil {
        var r = try required(.rowVersions)
        let n = try r.count(unit: 8)
        guard n <= rows else { throw MuxError(.invalidRequest, "row versions") }
        var list: [UInt64] = []
        list.reserveCapacity(n)
        for _ in 0 ..< n { list.append(try r.u64()) }
        try r.end()
        versions = list
      }
      if kind == .full, let versions, versions.count != rows {
        throw MuxError(.invalidRequest, "row versions")
      }
      // Cell rows: the frame's, or a delta's replaced rows.
      var cellRows = rows
      var delta: (base: UInt64, crc: UInt32, sources: [Int32])?
      if kind == .delta {
        guard versions != nil else {
          throw MuxError(.invalidRequest, "delta row versions")
        }
        var h = try required(.deltaHeader)
        let base = try h.u64()
        let crc = try h.u32()
        try h.end()
        var s = try required(.rowSources)
        let n = try s.count(unit: 4)
        guard n == rows else { throw MuxError(.invalidRequest, "row sources") }
        var sources: [Int32] = []
        sources.reserveCapacity(n)
        for _ in 0 ..< n { sources.append(Int32(bitPattern: try s.u32())) }
        try s.end()
        var c = try required(.replacedRows)
        cellRows = Int(try c.u32())
        try c.end()
        guard cellRows <= rows, versions?.count == cellRows else {
          throw MuxError(.invalidRequest, "replaced rows")
        }
        delta = (base, crc, sources)
      }
      let cells = cellRows * columns
      let wrapped = Data(try required(.wrapped).bytes)
      let glyphs = Data(try required(.glyphs).bytes)
      let cellStyles = Data(try required(.cellStyles).bytes)
      let kinds = Data(try required(.kinds).bytes)
      guard wrapped.count == cellRows, glyphs.count == cells * 4,
        cellStyles.count == cells * 2, kinds.count == cells
      else { throw MuxError(.invalidRequest, "SMXB cell arrays") }
      let grid = FrameGrid(
        columns: columns,
        rows: cellRows,
        alternateScreen: alternate,
        wrapped: wrapped,
        glyphs: glyphs,
        styles: cellStyles,
        kinds: kinds
      )
      var t = try required(.graphemes)
      let graphemeCount = try t.count(unit: 2)
      guard graphemeCount <= max(cells, 0) else {
        throw MuxError(.invalidRequest, "grapheme table size")
      }
      var graphemes: [[UInt32]] = []
      graphemes.reserveCapacity(graphemeCount)
      for _ in 0 ..< graphemeCount {
        let n = Int(try t.u16())
        guard n >= 1, n <= limits.maxGraphemeScalars else {
          throw MuxError(.invalidRequest, "grapheme scalars")
        }
        var scalars: [UInt32] = []
        scalars.reserveCapacity(n)
        for _ in 0 ..< n { scalars.append(try t.u32()) }
        graphemes.append(scalars)
      }
      try t.end()
      var st = try required(.styleTable)
      let styleCount = try st.count(unit: 11)
      guard styleCount <= limits.maxStyles else {
        throw MuxError(.invalidRequest, "style table size")
      }
      var styles: [FrameStyle] = []
      styles.reserveCapacity(styleCount)
      for _ in 0 ..< styleCount {
        styles.append(
          FrameStyle(
            foreground: try st.u32(),
            background: try st.u32(),
            flags: try st.u16(),
            underlineColor: try st.u8()
          )
        )
      }
      try st.end()
      var u = try required(.underlineColors)
      let underlineCount = try u.count(unit: 4)
      guard underlineCount <= 63 else {
        throw MuxError(.invalidRequest, "underline color table")
      }
      var underline: [UInt32] = []
      for _ in 0 ..< underlineCount { underline.append(try u.u32()) }
      try u.end()
      let meta = try metadata(rows: rows, columns: columns)
      switch kind {
      case .full:
        guard let palette = meta.palette else {
          throw MuxError(.invalidRequest, "SMXB missing palette")
        }
        let frame = PaneFrame(
          identity: identity,
          grid: grid,
          graphemes: graphemes,
          styles: styles,
          underlineColors: underline,
          palette: palette,
          cursor: meta.cursor,
          modes: meta.modes,
          history: meta.history,
          search: meta.search,
          title: meta.title,
          dropTarget: meta.drop,
          rowVersions: versions,
          images: meta.images
        )
        try FrameValidator.validate(frame, limits: limits)
        return Record(envelope: envelope, payload: .frame(frame))
      case .delta:
        let d = delta!
        let value = FrameDelta(
          identity: identity,
          baseRevision: d.base,
          columns: columns,
          rows: rows,
          alternateScreen: alternate,
          rowSources: d.sources,
          replaced: grid,
          graphemes: graphemes,
          styles: styles,
          underlineColors: underline,
          replacedVersions: versions!,
          palette: meta.palette,
          cursor: meta.cursor,
          modes: meta.modes,
          history: meta.history,
          search: meta.search,
          title: meta.title,
          dropTarget: meta.drop,
          images: meta.images,
          identityChecksum: d.crc
        )
        try FrameDeltaApplier.validateShape(value, limits: limits)
        return Record(envelope: envelope, payload: .delta(value))
      }
    }

    struct Metadata {
      /// Absent only from a delta whose palette equals its base's.
      var palette: FramePalette?
      var cursor: FrameCursor
      var modes: SupportedViewModes
      var history: HistoryWindow
      var search: FrameSearch?
      var title: String
      var drop: FrameDropTarget?
      var images: FrameImages?
    }

    func metadata(rows: Int, columns: Int) throws(MuxError) -> Metadata {
      var palette: FramePalette?
      if sections[.palette] != nil {
        var p = try required(.palette)
        let n = try p.count(unit: 4)
        guard n == 256 else { throw MuxError(.invalidRequest, "palette size") }
        var colors: [UInt32] = []
        colors.reserveCapacity(n)
        for _ in 0 ..< n { colors.append(try p.u32()) }
        let fg = try p.u32()
        let bg = try p.u32()
        let cursorColor = try p.u32()
        let mask = try p.u8()
        guard mask & ~0b111 == 0 else {
          throw MuxError(.invalidRequest, "palette mask")
        }
        var optional: [UInt32?] = []
        for i in 0 ..< 3 {
          let v = try p.u32()
          optional.append(mask & (1 << i) != 0 ? v : nil)
        }
        try p.end()
        palette = FramePalette(
          colors: colors,
          foreground: fg,
          background: bg,
          cursor: cursorColor,
          cursorText: optional[0],
          selectionForeground: optional[1],
          selectionBackground: optional[2]
        )
      }
      var c = try required(.cursor)
      let cursor = FrameCursor(
        x: try c.i64(),
        y: try c.i64(),
        visible: try c.bool(),
        style: try c.u8(),
        blinking: try c.bool()
      )
      try c.end()
      var m = try required(.modes)
      let modes = SupportedViewModes(rawValue: try m.u32())
      try m.end()
      var h = try required(.history)
      let history = HistoryWindow(
        generation: try h.u64(),
        firstRow: try h.i64(),
        availableRows: try h.i64(),
        viewportTop: try h.i64(),
        viewportOffset: try h.i64(),
        scrollbackRows: try h.i64()
      )
      try h.end()
      var search: FrameSearch?
      if sections[.search] != nil {
        var s = try required(.search)
        let matchCount = try s.i64()
        let selected = try s.optionalIndex()
        let selectedVisible = try s.optionalIndex()
        let spans = try s.count(unit: 32)
        var visible: [FrameSpan] = []
        visible.reserveCapacity(spans)
        for _ in 0 ..< spans {
          visible.append(
            FrameSpan(
              startRow: try s.i64(),
              startColumn: try s.i64(),
              endRow: try s.i64(),
              endColumn: try s.i64()
            )
          )
        }
        try s.end()
        search = FrameSearch(
          matchCount: matchCount,
          selected: selected,
          visible: visible,
          selectedVisible: selectedVisible
        )
      }
      let titleBytes = try required(.title).bytes
      guard titleBytes.count <= 4096,
        let title = String(validating: titleBytes, as: UTF8.self)
      else { throw MuxError(.invalidRequest, "title") }
      var drop: FrameDropTarget?
      if sections[.dropTarget] != nil {
        var d = try required(.dropTarget)
        let n = try d.count(unit: 4)
        guard n <= FrameDropTarget.maxTypes else {
          throw MuxError(.invalidRequest, "drop target types")
        }
        var types: [String] = []
        for _ in 0 ..< n {
          let length = Int(try d.u32())
          guard length <= FrameDropTarget.maxTypeBytes,
            let type = String(validating: try d.take(length), as: UTF8.self)
          else { throw MuxError(.invalidRequest, "drop target type") }
          types.append(type)
        }
        let accepted: MuxDropOperation?
        switch try d.u8() {
        case 0: accepted = nil
        case 1: accepted = MuxDropOperation.none
        case 2: accepted = .copy
        case 3: accepted = .move
        default: throw MuxError(.invalidRequest, "drop operation")
        }
        try d.end()
        drop = FrameDropTarget(types: types, accepted: accepted)
      }
      var images: FrameImages?
      if sections[.images] != nil {
        var r = try required(.images)
        let cellWidth = try r.u16()
        let cellHeight = try r.u16()
        let imageCount = try r.count(unit: 17)
        guard imageCount <= FrameImages.maxImages else {
          throw MuxError(.invalidRequest, "frame images count")
        }
        var table: [FrameImage] = []
        for _ in 0 ..< imageCount {
          table.append(
            FrameImage(
              key: try r.u64(),
              width: try r.u32(),
              height: try r.u32(),
              bytesPerPixel: try r.u8()
            )
          )
        }
        let placementCount = try r.count(unit: 56)
        guard placementCount <= FrameImages.maxPlacements else {
          throw MuxError(.invalidRequest, "frame placements count")
        }
        var placements: [FramePlacement] = []
        placements.reserveCapacity(placementCount)
        for _ in 0 ..< placementCount {
          let image = try r.u16()
          let layer = try r.u8()
          let z = Int32(bitPattern: try r.u32())
          let placeholder = try r.bool()
          let row = Int32(bitPattern: try r.u32())
          let column = Int32(bitPattern: try r.u32())
          var v: [UInt32] = []
          for _ in 0 ..< 10 { v.append(try r.u32()) }
          placements.append(
            FramePlacement(
              image: image,
              layer: layer,
              z: z,
              placeholder: placeholder,
              row: row,
              column: column,
              columns: v[0],
              rows: v[1],
              offsetX: v[2],
              offsetY: v[3],
              width: v[4],
              height: v[5],
              sourceX: v[6],
              sourceY: v[7],
              sourceWidth: v[8],
              sourceHeight: v[9]
            )
          )
        }
        let prefetchCount = try r.count(unit: 17)
        guard prefetchCount <= FrameImages.maxImages else {
          throw MuxError(.invalidRequest, "frame prefetch count")
        }
        var prefetch: [FrameImage] = []
        for _ in 0 ..< prefetchCount {
          prefetch.append(
            FrameImage(
              key: try r.u64(),
              width: try r.u32(),
              height: try r.u32(),
              bytesPerPixel: try r.u8()
            )
          )
        }
        try r.end()
        images = FrameImages(
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          images: table,
          placements: placements,
          prefetch: prefetch
        )
        try images!.validate(rows: rows, columns: columns)
      }
      return Metadata(
        palette: palette,
        cursor: cursor,
        modes: modes,
        history: history,
        search: search,
        title: title,
        drop: drop,
        images: images
      )
    }
  }
}
