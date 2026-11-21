import Foundation

/// Validates decoded records before any presentation uses them. Invalid
/// messages never partially update a presentation.
public enum FrameValidator {
  public static func validate(
    _ frame: PaneFrame,
    limits: MuxLimits = .standard
  ) throws(MuxError) {
    let g = frame.grid
    guard let count = limits.cellCount(columns: g.columns, rows: g.rows) else {
      throw MuxError(.invalidRequest, "frame dimensions \(g.columns)x\(g.rows)")
    }
    guard g.wrapped.count == g.rows, g.kinds.count == count,
      g.styles.count == count * 2, g.glyphs.count == count * 4
    else { throw MuxError(.invalidRequest, "frame array lengths") }
    guard frame.styles.count <= limits.maxStyles, !frame.styles.isEmpty else {
      throw MuxError(.invalidRequest, "style table size")
    }
    guard frame.graphemes.count <= count else {
      throw MuxError(.invalidRequest, "grapheme table size")
    }
    guard frame.underlineColors.count <= 63 else {
      throw MuxError(.invalidRequest, "underline color table")
    }
    for scalars in frame.graphemes {
      guard !scalars.isEmpty, scalars.count <= limits.maxGraphemeScalars,
        scalars.allSatisfy({ Unicode.Scalar($0) != nil })
      else { throw MuxError(.invalidRequest, "grapheme scalars") }
    }
    for style in frame.styles {
      guard validColor(style.foreground), validColor(style.background),
        Int(style.underlineColor) <= frame.underlineColors.count
      else { throw MuxError(.invalidRequest, "style entry") }
    }
    for color in frame.underlineColors where !validColor(color) {
      throw MuxError(.invalidRequest, "underline color")
    }
    guard frame.palette.colors.count == 256 else {
      throw MuxError(.invalidRequest, "palette size")
    }
    guard frame.palette.isValid else {
      throw MuxError(.invalidRequest, "palette color")
    }
    for row in 0 ..< g.rows {
      var expectContinuation = false
      for column in 0 ..< g.columns {
        let i = row * g.columns + column
        guard let kind = CellKind(rawValue: g.kinds[g.kinds.startIndex + i])
        else { throw MuxError(.invalidRequest, "cell kind") }
        guard g.style(at: i) < frame.styles.count else {
          throw MuxError(.invalidRequest, "style index")
        }
        let glyph = g.glyph(at: i)
        if expectContinuation {
          guard kind == .continuation, glyph == 0 else {
            throw MuxError(.invalidRequest, "wide cell continuation")
          }
          expectContinuation = false
          continue
        }
        switch kind {
        case .continuation:
          throw MuxError(.invalidRequest, "orphan continuation")
        case .padding:
          guard glyph == 0, column == g.columns - 1 else {
            throw MuxError(.invalidRequest, "padding cell")
          }
        case .wideLead:
          guard column < g.columns - 1 else {
            throw MuxError(.invalidRequest, "wide lead at row end")
          }
          expectContinuation = true
          try validateGlyph(glyph, graphemes: frame.graphemes.count)
        case .narrow: try validateGlyph(glyph, graphemes: frame.graphemes.count)
        }
      }
    }
    let c = frame.cursor
    guard c.x >= 0, c.x < g.columns, c.y >= 0, c.y < g.rows, c.style <= 2 else {
      throw MuxError(.invalidRequest, "cursor")
    }
    let h = frame.history
    guard h.isBounded, h.availableRows >= g.rows,
      h.viewportOffset <= h.scrollbackRows
    else { throw MuxError(.invalidRequest, "history window") }
    if let search = frame.search {
      // `SMXB/1` encodes an absent index as -1, so a negative `selected`
      // from JSON would not survive the binary form.
      guard search.matchCount >= 0, search.visible.count <= count,
        search.selected.map({ $0 >= 0 && $0 < search.matchCount }) ?? true,
        search.selectedVisible.map({ $0 >= 0 && $0 < search.visible.count })
          ?? true
      else { throw MuxError(.invalidRequest, "search state") }
      for span in search.visible {
        guard span.startRow <= span.endRow, span.endRow >= 0,
          span.startRow < g.rows, (0 ..< g.columns).contains(span.startColumn),
          (0 ..< g.columns).contains(span.endColumn)
        else { throw MuxError(.invalidRequest, "search span") }
      }
    }
    guard frame.title.utf8.count <= 4096 else {
      throw MuxError(.invalidRequest, "title length")
    }
    if let versions = frame.rowVersions, versions.count != g.rows {
      throw MuxError(.invalidRequest, "row versions")
    }
    if let target = frame.dropTarget {
      guard target.types.count <= FrameDropTarget.maxTypes,
        target.types.allSatisfy({
          !$0.isEmpty && $0.utf8.count <= FrameDropTarget.maxTypeBytes
        })
      else { throw MuxError(.invalidRequest, "drop target types") }
    }
  }

  private static func validColor(_ raw: UInt32) -> Bool {
    switch raw >> 24 {
    case 0: raw == 0
    case 1: raw & 0x00FF_FF00 == 0
    case 2: true
    default: false
    }
  }

  private static func validateGlyph(
    _ glyph: UInt32,
    graphemes: Int
  ) throws(MuxError) {
    if glyph & FrameGrid.graphemeFlag != 0 {
      guard Int(glyph & ~FrameGrid.graphemeFlag) < graphemes else {
        throw MuxError(.invalidRequest, "grapheme reference")
      }
    } else if glyph != 0, Unicode.Scalar(glyph) == nil {
      throw MuxError(.invalidRequest, "invalid scalar")
    }
  }
}

/// JSON codec with size checks before decoding.
public enum SMXCodec {
  public static func encode<T: Encodable>(
    _ value: T,
    limit: Int
  ) throws(MuxError) -> Data {
    let data: Data
    do { data = try encoder().encode(value) } catch {
      throw MuxError(.invalidRequest, "encode: \(error)")
    }
    guard data.count <= limit else {
      throw MuxError(.resourceLimit, "record of \(data.count) bytes")
    }
    return data
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    limit: Int
  ) throws(MuxError) -> T {
    guard data.count <= limit else {
      throw MuxError(.resourceLimit, "record of \(data.count) bytes")
    }
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw MuxError(.invalidRequest, "decode: \(error)")
    }
  }

  private static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dataEncodingStrategy = .base64
    return e
  }

  /// Largest server record: a frame plus envelope, capped at Int.max.
  public static func serverRecordLimit(_ limits: MuxLimits) -> Int {
    let (limit, overflow) = limits.maxFrameBytes.addingReportingOverflow(
      64 << 10
    )
    return overflow ? Int.max : limit
  }

  /// Client records are ordinary control records.
  public static func clientRecordLimit(_ limits: MuxLimits) -> Int {
    limits.maxControlRecordBytes
  }
}
