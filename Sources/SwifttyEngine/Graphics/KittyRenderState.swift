/// Resolves kitty graphics placements into viewport coordinates for
/// presentation: anchored and relative placements, and Unicode
/// placeholder runs drawing virtual placements.
///
/// Ported from Ghostty's `src/terminal/render.zig` (`Kitty`) and
/// `src/terminal/kitty/graphics_unicode.zig` at 167acf0c. Placeholder
/// runs always draw below text at z = −1, as in Ghostty.
extension KittyGraphics {
  public enum Layer: UInt8, Sendable, Comparable {
    case belowBackground, belowText, aboveText

    public static func < (a: Layer, b: Layer) -> Bool {
      a.rawValue < b.rawValue
    }

    static func from(z: Int32) -> Layer {
      z < KittyGraphics.belowBackgroundZ
        ? .belowBackground : z < 0 ? .belowText : .aboveText
    }
  }

  /// One placement to draw, in viewport cells plus pixel offsets.
  public struct Placement: Sendable, Equatable {
    public var imageID: UInt32
    /// Changes whenever the displayed pixels change.
    public var generation: UInt64
    public var pixels: KittyImagePixels
    public var layer: Layer
    public var z: Int32
    /// Top-left cell, relative to the viewport's first row; may be
    /// negative or past the bottom when the placement is partly visible.
    public var row: Int
    public var column: Int
    public var columns: Int
    public var rows: Int
    /// Pixel offset inside the top-left cell.
    public var offsetX: Int
    public var offsetY: Int
    /// Destination size in pixels.
    public var width: Int
    public var height: Int
    public var sourceX: Int
    public var sourceY: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// Drawn from Unicode placeholder cells.
    public var isPlaceholder: Bool

    public init(
      imageID: UInt32,
      generation: UInt64,
      pixels: KittyImagePixels,
      layer: Layer,
      z: Int32,
      row: Int,
      column: Int,
      columns: Int,
      rows: Int,
      offsetX: Int,
      offsetY: Int,
      width: Int,
      height: Int,
      sourceX: Int,
      sourceY: Int,
      sourceWidth: Int,
      sourceHeight: Int,
      isPlaceholder: Bool
    ) {
      self.imageID = imageID
      self.generation = generation
      self.pixels = pixels
      self.layer = layer
      self.z = z
      self.row = row
      self.column = column
      self.columns = columns
      self.rows = rows
      self.offsetX = offsetX
      self.offsetY = offsetY
      self.width = width
      self.height = height
      self.sourceX = sourceX
      self.sourceY = sourceY
      self.sourceWidth = sourceWidth
      self.sourceHeight = sourceHeight
      self.isPlaceholder = isPlaceholder
    }

    public static func == (a: Placement, b: Placement) -> Bool {
      a.imageID == b.imageID && a.generation == b.generation
        && a.pixels === b.pixels && a.layer == b.layer && a.z == b.z
        && a.row == b.row && a.column == b.column && a.columns == b.columns
        && a.rows == b.rows && a.offsetX == b.offsetX && a.offsetY == b.offsetY
        && a.width == b.width && a.height == b.height && a.sourceX == b.sourceX
        && a.sourceY == b.sourceY && a.sourceWidth == b.sourceWidth
        && a.sourceHeight == b.sourceHeight
        && a.isPlaceholder == b.isPlaceholder
    }
  }

  /// Most placements one capture returns; the lowest layers and z go first.
  public static let maxPlacementsPerCapture = 4096

  /// Row/column index a diacritic encodes, or nil.
  @inline(__always)
  static func diacriticIndex(_ scalar: UInt32) -> UInt32? {
    let page = Int(scalar >> 8)
    guard page < DiacriticTable.pageCount else { return nil }
    let t = DiacriticTable.shared.slots
    let slot = Int(t[page])
    guard slot != 0 else { return nil }
    let v = t[DiacriticTable.pageCount + (slot - 1) << 8 + Int(scalar & 0xFF)]
    return v == 0 ? nil : UInt32(v - 1)
  }

  /// Two-level lookup from scalar to diacritic index: a page map over
  /// `scalar >> 8`, then 256-entry pages holding `index + 1` (0: none).
  final class DiacriticTable: Sendable {
    static let pageCount = 0x1D3
    static let shared = DiacriticTable()
    nonisolated(unsafe) let slots: UnsafeMutablePointer<UInt16>

    private init() {
      var pages: [Int: Int] = [:]
      for d in KittyGraphics.diacritics where pages[Int(d >> 8)] == nil {
        pages[Int(d >> 8)] = pages.count + 1
      }
      let count = Self.pageCount + pages.count << 8
      slots = .allocate(capacity: count)
      slots.initialize(repeating: 0, count: count)
      for (page, slot) in pages { slots[page] = UInt16(slot) }
      for (i, d) in KittyGraphics.diacritics.enumerated() {
        let slot = pages[Int(d >> 8)]!
        slots[Self.pageCount + (slot - 1) << 8 + Int(d & 0xFF)] = UInt16(i + 1)
      }
    }
  }

  static func colorID(_ c: TerminalColor) -> UInt32 {
    switch c.kind {
    case .default: 0
    case let .palette(i): UInt32(i)
    case let .rgb(v): v & 0xFF_FFFF
    }
  }

  /// The placeholder runs of one row (`TerminalState.kittyPlaceholderRow`).
  public struct PlaceholderRow: Sendable, Equatable {
    var runs: [PlaceholderRun] = []
    /// Whether the row holds no placeholder run.
    public var isEmpty: Bool { runs.isEmpty }
    public init() {}
  }

  /// One placeholder cell, or a run of them after `append`.
  struct PlaceholderRun: Sendable, Equatable {
    var imageLow: UInt32
    var imageHigh: UInt32?
    var placementID: UInt32?
    var row: UInt32?
    var column: UInt32?
    var width: UInt32 = 1
    var x = 0

    init(foreground: UInt32, underline: UInt32, diacritics d: [UInt32]) {
      self.init(
        foreground: foreground,
        underline: underline,
        marks: (
          d.count > 0 ? d[0] : nil, d.count > 1 ? d[1] : nil,
          d.count > 2 ? d[2] : nil
        )
      )
    }

    init(
      foreground: UInt32,
      underline: UInt32,
      marks: (UInt32?, UInt32?, UInt32?)
    ) {
      imageLow = foreground
      placementID = underline != 0 ? underline : nil
      if let r = marks.0 {
        row = KittyGraphics.diacriticIndex(r)
        if let c = marks.1 {
          column = KittyGraphics.diacriticIndex(c)
          if let h = marks.2, let high = KittyGraphics.diacriticIndex(h),
            high < 256
          {
            imageHigh = high
          }
        }
      }
    }

    func started() -> PlaceholderRun {
      var r = self
      if r.row == nil { r.row = 0 }
      if r.column == nil { r.column = 0 }
      return r
    }

    mutating func append(_ other: PlaceholderRun) -> Bool {
      guard imageLow == other.imageLow, placementID == other.placementID,
        other.row == nil || other.row == row,
        other.column == nil || other.column == column! + width,
        other.imageHigh == nil || other.imageHigh == imageHigh
      else { return false }
      width += 1
      return true
    }

    var imageID: UInt32 { imageLow | (imageHigh ?? 0) << 24 }
  }

  /// Ghostty's `unicode.Placement.renderPlacement`: the slice of the
  /// virtual placement one run draws, aspect-fitted and centred.
  static func placeholderGeometry(
    run: PlaceholderRun,
    target: KittyImageStorage.Placement,
    image: Image,
    cellWidth: UInt32,
    cellHeight: UInt32
  ) -> (
    offsetX: Int, offsetY: Int, width: Int, height: Int, sx: Int, sy: Int,
    sw: Int, sh: Int
  )? {
    var gridRows = target.rows
    var gridColumns = target.columns
    if gridRows == 0 { gridRows = (image.height + cellHeight - 1) / cellHeight }
    if gridColumns == 0 {
      gridColumns = (image.width + cellWidth - 1) / cellWidth
    }
    guard gridRows > 0, gridColumns > 0, gridRows <= UInt32(UInt16.max),
      gridColumns <= UInt32(UInt16.max)
    else { return nil }
    let iw = Double(image.width)
    let ih = Double(image.height)
    let rowsPx = Double(gridRows * cellHeight)
    let colsPx = Double(gridColumns * cellWidth)
    var xScale = 0.0
    var yScale = 0.0
    var xOff = 0.0
    var yOff = 0.0
    if iw * rowsPx > ih * colsPx {
      xScale = colsPx / max(iw, 1)
      yScale = xScale
      yOff = (rowsPx - ih * yScale) / 2
    } else {
      yScale = rowsPx / max(ih, 1)
      xScale = yScale
      xOff = (colsPx - iw * xScale) / 2
    }
    let scaledXOffset = xOff / xScale
    let scaledYOffset = yOff / yScale
    let scaledWidth = iw + scaledXOffset * 2
    let scaledHeight = ih + scaledYOffset * 2
    var sw = scaledWidth * (Double(run.width) / Double(gridColumns))
    var sh = scaledHeight * (1 / Double(gridRows))
    var sx = scaledWidth * (Double(run.column ?? 0) / Double(gridColumns))
    var sy = scaledHeight * (Double(run.row ?? 0) / Double(gridRows))
    var dx = 0.0
    var dy = 0.0
    var width = Double(run.width * cellWidth)
    var height = Double(cellHeight)
    if sy < scaledYOffset {
      let offset = scaledYOffset - sy
      sh -= offset
      dy = offset
      height -= offset * yScale
      sy = 0
      if sh > ih {
        sh = ih
        height = ih * yScale
      }
    } else if sy + sh > scaledHeight - scaledYOffset {
      sy -= scaledYOffset
      sh = scaledHeight - scaledYOffset - sy
      sh -= scaledYOffset
      height = sh * yScale
    } else {
      sy -= scaledYOffset
    }
    if sx < scaledXOffset {
      let offset = scaledXOffset - sx
      sw -= offset
      dx = offset
      width -= offset * xScale
      sx = 0
      if sw > iw {
        sw = iw
        width = iw * xScale
      }
    } else if sx + sw > scaledWidth - scaledXOffset {
      sx -= scaledXOffset
      sw = scaledWidth - scaledXOffset - sx
      sw -= scaledXOffset
      width = sw * xScale
    } else {
      sx -= scaledXOffset
    }
    guard sw > 0, sh > 0 else { return nil }
    let r = { (v: Double) in Int(v.rounded()) }
    // Independent rounding can push the source rect a pixel past the
    // image; clients reject such frames, so clamp it back inside.
    let maxX = Int(image.width)
    let maxY = Int(image.height)
    let x = min(max(r(sx), 0), maxX - 1)
    let y = min(max(r(sy), 0), maxY - 1)
    let w = min(r(sw), maxX - x)
    let h = min(r(sh), maxY - y)
    guard w > 0, h > 0 else { return nil }
    return (r(dx * xScale), r(dy * yScale), r(width), r(height), x, y, w, h)
  }
}

extension TerminalState {
  /// Absolute row shown on viewport row 0.
  public var viewportTopAbsoluteRow: Int {
    screenAbsoluteRow(0) - (isAlternateScreen ? 0 : viewportOffset)
  }

  /// Placements visible in `rows` viewport rows from absolute row `top`
  /// (defaults: the current viewport), sorted by layer, z and image id.
  public func kittyPlacements(
    top: Int? = nil,
    rows count: Int? = nil,
    placeholderRows: [KittyGraphics.PlaceholderRow]? = nil
  ) -> [KittyGraphics.Placement] {
    let storage = kittyImages
    guard kittyGraphicsEnabled, !storage.images.isEmpty else { return [] }
    let g = kittyGeometry
    let top = top ?? viewportTopAbsoluteRow
    let count = count ?? rows
    var out: [KittyGraphics.Placement] = []

    // Placeholder runs per captured row, from the caller's cache when
    // given (spec.graphics.md §10.2).
    var runs:
      [(
        y: Int, run: KittyGraphics.PlaceholderRun,
        key: KittyImageStorage.PlacementKey?
      )] = []
    if kittyUsesPlaceholders {
      for y in 0 ..< count {
        let row =
          placeholderRows.flatMap { y < $0.count ? $0[y] : nil }
          ?? kittyPlaceholderRow(absoluteRow: top + y)
        for r in row.runs {
          let target = storage.placeholderTarget(
            imageID: r.imageID,
            placementID: r.placementID ?? 0
          )
          runs.append((y, r, target?.0))
        }
      }
      for entry in runs {
        guard let key = entry.key, let target = storage.placements[key],
          let image = storage.image(id: entry.run.imageID),
          let pixels = image.displayedPixels, g.cellWidth > 0, g.cellHeight > 0,
          let geo = KittyGraphics.placeholderGeometry(
            run: entry.run,
            target: target,
            image: image,
            cellWidth: g.cellWidth,
            cellHeight: g.cellHeight
          ), geo.width > 0, geo.height > 0
        else { continue }
        out.append(
          KittyGraphics.Placement(
            imageID: image.id,
            generation: image.generation,
            pixels: pixels,
            layer: .belowText,
            z: -1,
            row: entry.y,
            column: entry.run.x,
            columns: Int(entry.run.width),
            rows: 1,
            offsetX: geo.offsetX,
            offsetY: geo.offsetY,
            width: geo.width,
            height: geo.height,
            sourceX: geo.sx,
            sourceY: geo.sy,
            sourceWidth: geo.sw,
            sourceHeight: geo.sh,
            isPlaceholder: true
          )
        )
      }
    }

    for (key, p) in storage.placements {
      let origin: (x: Int, y: Int)
      var h = 0
      var v = 0
      switch p.location {
      case .virtual: continue
      case let .anchor(row, column):
        guard row >= g.firstRow else { continue }
        origin = (column, row - top)
      case let .relative(parent, ph, pv):
        guard
          let chain = storage.resolveChain(
            parent: parent,
            horizontal: ph,
            vertical: pv
          )
        else { continue }
        h = Int(chain.horizontal)
        v = Int(chain.vertical)
        switch chain.root.location {
        case let .anchor(row, column):
          guard row >= g.firstRow else { continue }
          origin = (column, row - top)
        case .virtual:
          var o: (x: Int, y: Int)?
          for entry in runs where entry.key == chain.rootKey {
            o =
              o.map { (min($0.x, entry.run.x), min($0.y, entry.y)) } ?? (
                entry.run.x, entry.y
              )
          }
          guard let o else { continue }
          origin = o
        case .relative: continue
        }
      }
      guard let image = storage.image(id: key.imageID),
        let pixels = image.displayedPixels
      else { continue }
      let grid = KittyImageStorage.gridSize(p, image, g)
      guard grid.columns > 0, grid.rows > 0 else { continue }
      let dest = KittyImageStorage.pixelSize(p, image, g)
      guard dest.width > 0, dest.height > 0 else { continue }
      let x = origin.x + h
      let y = origin.y + v
      guard y + Int(grid.rows) - 1 >= 0, y < count,
        x + Int(grid.columns) - 1 >= 0, x < columns
      else { continue }
      let offset = KittyImageStorage.cellOffset(p, g)
      let source = KittyImageStorage.sourceRect(p, image)
      out.append(
        KittyGraphics.Placement(
          imageID: key.imageID,
          generation: image.generation,
          pixels: pixels,
          layer: .from(z: p.z),
          z: p.z,
          row: y,
          column: x,
          columns: Int(grid.columns),
          rows: Int(grid.rows),
          offsetX: Int(offset.x),
          offsetY: Int(offset.y),
          width: Int(dest.width),
          height: Int(dest.height),
          sourceX: Int(source.x),
          sourceY: Int(source.y),
          sourceWidth: Int(source.width),
          sourceHeight: Int(source.height),
          isPlaceholder: false
        )
      )
    }
    out.sort {
      ($0.layer, $0.z, $0.imageID, $0.row, $0.column) < (
        $1.layer, $1.z, $1.imageID, $1.row, $1.column
      )
    }
    if out.count > KittyGraphics.maxPlacementsPerCapture {
      out.removeFirst(out.count - KittyGraphics.maxPlacementsPerCapture)
    }
    return out
  }

  /// The pixels with `serial` on either screen, including animation
  /// frames; nil once they were replaced or deleted.
  public func kittyPixels(serial: UInt64) -> KittyImagePixels? {
    for storage in [kittyPrimary, kittyAlternate] {
      for image in storage.images.values {
        if let p = image.pixels, p.serial == serial { return p }
        for frame in image.animation?.frames ?? []
        where frame.pixels.serial == serial { return frame.pixels }
      }
    }
    return nil
  }

  /// All frames of the animated images `placements` show, excluding the
  /// ones shown (Phase 5 frame sets, spec.graphics.md §16.4).
  public func kittyAnimationFrames(
    of placements: [KittyGraphics.Placement]
  ) -> [KittyImagePixels] {
    var seen = Set(placements.map(\.pixels.serial))
    var out: [KittyImagePixels] = []
    for id in Set(placements.map(\.imageID)) {
      guard let image = kittyImages.image(id: id),
        let animation = image.animation
      else { continue }
      for pixels in [image.pixels].compactMap({ $0 })
        + animation.frames.map(\.pixels)
      where seen.insert(pixels.serial).inserted { out.append(pixels) }
    }
    return out
  }

  /// Whether the active screen has virtual placements, so placeholder
  /// cells may draw images.
  public var kittyUsesPlaceholders: Bool {
    kittyImages.placements.values.contains { $0.location == .virtual }
  }

  /// Graphics inputs a snapshot capture keys on, read in one call (it
  /// runs every frame): nil without images on either screen (as
  /// `hasKittyImages`), else `kittyGraphicsRevision` and
  /// `viewportTopAbsoluteRow`.
  public var kittySnapshotKey: (revision: UInt64, top: Int)? {
    guard !kittyPrimary.images.isEmpty || !kittyAlternate.images.isEmpty else {
      return nil
    }
    let s = isAlternateScreen ? kittyAlternate : kittyPrimary
    return (
      s.generation &+ s.dirty &* 0x9E37_79B9_7F4A_7C15, viewportTopAbsoluteRow
    )
  }

  /// The placeholder runs of one row: they depend only on its cells, so
  /// callers cache them per row and rescan only damaged rows.
  public func kittyPlaceholderRow(
    absoluteRow row: Int
  ) -> KittyGraphics.PlaceholderRow {
    var out = KittyGraphics.PlaceholderRow()
    _ = withLine(absoluteRow: row) { cells, _ in
      // Most rows hold no placeholder: find the first candidate cheaply.
      guard let start = Self.firstPlaceholderCandidate(cells) else { return }
      let diacritics = KittyGraphics.diacritics
      var current: KittyGraphics.PlaceholderRun?
      // Fast path for the common cell, which continues `current`: same
      // color bits as the previous cell in the run (so the same image and
      // placement ids), the row diacritic it carried, and the diacritic of
      // the next column. Anything else takes the general path below.
      var runBits: UInt32 = 0
      var runRowMark: UInt32 = .max
      var nextColumnMark: UInt32 = .max
      // Read once: per-cell reads through `self` reloaded them every cell.
      let entries = graphemes.entries.span
      let table = graphemes.scalars.span
      for x in start ..< cells.count {
        let cell = cells[x]
        if current != nil, cell.isGrapheme,
          cell.packed.foregroundBits.rawValue == runBits
        {
          let entry = entries[Int(cell.glyph)]
          let at = Int(entry >> 32)
          if entry & 0xFFFF_FFFF == 3, at + 3 <= table.count,
            table[unchecked: at] == KittyGraphics.placeholder,
            table[unchecked: at + 1] == runRowMark,
            table[unchecked: at + 2] == nextColumnMark
          {
            current!.width += 1
            let next = Int(current!.column! + current!.width)
            nextColumnMark = next < diacritics.count ? diacritics[next] : .max
            continue
          }
        }
        var marks: (UInt32?, UInt32?, UInt32?) = (nil, nil, nil)
        let first: UInt32
        if cell.isGrapheme {
          let scalars = graphemes.scalars(cell.glyph)
          first = scalars.count > 0 ? scalars[0] : 0
          if first == KittyGraphics.placeholder {
            if scalars.count > 1 { marks.0 = scalars[1] }
            if scalars.count > 2 { marks.1 = scalars[2] }
            if scalars.count > 3 { marks.2 = scalars[3] }
          }
        } else {
          first = cell.glyph
        }
        guard first == KittyGraphics.placeholder else {
          if let r = current { out.runs.append(r) }
          current = nil
          continue
        }
        let underline =
          underlineColor(cell.attributes.underlineColor)
          .map(KittyGraphics.colorID) ?? 0
        var run = KittyGraphics.PlaceholderRun(
          foreground: KittyGraphics.colorID(cell.attributes.foreground),
          underline: underline,
          marks: marks
        )
        run.x = x
        if current != nil, current!.append(run) {
          // Equal ids: these bits may stand for the run as well.
          runBits = cell.packed.foregroundBits.rawValue
          if run.row != nil { runRowMark = marks.0! }
        } else {
          if let r = current { out.runs.append(r) }
          current = run.started()
          runBits = cell.packed.foregroundBits.rawValue
          // Only a mark that set the run's row may stand for it.
          runRowMark = run.row != nil ? marks.0! : .max
        }
        let next = Int(current!.column! + current!.width)
        nextColumnMark = next < diacritics.count ? diacritics[next] : .max
      }
      if let r = current { out.runs.append(r) }
    }
    return out
  }

  /// The first cell that may be a placeholder: U+10EEEE alone or a
  /// grapheme (whose first scalar the caller checks).
  @inline(never)
  static func firstPlaceholderCandidate(
    _ cells: UnsafeBufferPointer<Cell>
  ) -> Int? {
    guard let p = cells.baseAddress else { return nil }
    @inline(__always)
    func candidate(_ x: Int) -> UInt8 {
      let c = p[x]
      return (c.isGrapheme ? 1 : 0)
        | (c.glyph == KittyGraphics.placeholder ? 1 : 0)
    }
    // Groups of four test without a branch per cell; most rows have none.
    var x = 0
    let n = cells.count
    while x + 4 <= n {
      if candidate(x) | candidate(x + 1) | candidate(x + 2) | candidate(x + 3)
        != 0
      {
        break
      }
      x += 4
    }
    while x < n {
      if candidate(x) != 0 { return x }
      x += 1
    }
    return nil
  }

  /// Changes whenever `kittyPlacements()` may return something different
  /// for the same viewport.
  public var kittyGraphicsRevision: UInt64 {
    // The same hash as `kittySnapshotKey`.
    let s = kittyImages
    return s.generation &+ s.dirty &* 0x9E37_79B9_7F4A_7C15
  }
}
