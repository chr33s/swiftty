import SwifttyEngine

/// A visible kitty graphics image for assistive technologies
/// (spec.graphics.md §13.4): its cells and a label. There is no content
/// description; the pixels are program output with no alternative text.
public struct ImageRegion: Equatable, Sendable {
  public var row: Int
  public var column: Int
  public var columns: Int
  public var rows: Int

  public var label: String { "Image, \(columns) by \(rows) cells" }
}

extension RenderSnapshot {
  /// Images larger than one cell, clipped to the snapshot: anchored and
  /// relative placements as they are, placeholder runs of one image on
  /// consecutive rows merged.
  public var imageRegions: [ImageRegion] {
    var out: [ImageRegion] = []
    var runs:
      [(serial: UInt64, column: Int, columns: Int, row: Int, rows: Int)] = []
    for p in images {
      if p.isPlaceholder {
        if let i = runs.lastIndex(where: {
          $0.serial == p.pixels.serial && $0.column == p.column
            && $0.columns == p.columns && $0.row + $0.rows == p.row
        }) {
          runs[i].rows += 1
        } else {
          runs.append((p.pixels.serial, p.column, p.columns, p.row, 1))
        }
      } else {
        out.append(
          ImageRegion(
            row: p.row,
            column: p.column,
            columns: p.columns,
            rows: p.rows
          )
        )
      }
    }
    out += runs.map {
      ImageRegion(
        row: $0.row,
        column: $0.column,
        columns: $0.columns,
        rows: $0.rows
      )
    }
    return out.compactMap { r in
      let top = max(0, r.row)
      let left = max(0, r.column)
      let bottom = min(rowCount, r.row + r.rows)
      let right = min(columns, r.column + r.columns)
      guard bottom > top, right > left else { return nil }
      let clipped = ImageRegion(
        row: top,
        column: left,
        columns: right - left,
        rows: bottom - top
      )
      return clipped.columns * clipped.rows > 1 ? clipped : nil
    }
  }
}
