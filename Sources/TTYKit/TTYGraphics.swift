import Foundation
import SwifttyEngine

/// Kitty graphics for terminal clients drawing into another terminal
/// (`swroam`, `swmux`; spec.graphics.md §16.5).
///
/// In kitty mode each image is transmitted once to the outer terminal with
/// a virtual placement, and placements are drawn as Unicode placeholder
/// cells in the composed screen, so pane clipping, overlap, scrolling and
/// redraws stay ordinary cell diffing (the technique that makes kitty
/// images work inside tmux). Without kitty support images become
/// half-block cells. CPU only: no renderer or Metal.
public final class TTYGraphics {
  public enum Mode: String, Sendable {
    /// Unicode placeholders over the kitty protocol.
    case kitty
    /// `▀` cells: top and bottom half colours.
    case halfBlocks = "halfblocks"
    case off
  }

  public var mode: Mode
  /// Wrap kitty commands in tmux passthrough (`$TMUX` set).
  public let tmux: Bool
  /// 24-bit colour for half-blocks; otherwise the 256-colour palette.
  public let truecolor: Bool

  /// Outer image ids by (pixels, source rect, grid size).
  private struct ImageKey: Hashable {
    var serial: UInt64
    var source: [Int]
    var columns: Int
    var rows: Int
  }

  private var outerIDs: [ImageKey: UInt32] = [:]
  private var transmitted: Set<UInt32> = []
  private var nextID: UInt32 = 1
  /// Bytes sent since the last full redraw, to resend after the outer
  /// terminal may have evicted images.
  private var sentSinceRedraw = 0
  /// Samples for the visible window of a placement's grid.
  private struct HalfBlockKey: Hashable {
    var image: ImageKey
    var rows: Range<Int>
    var columns: Range<Int>
  }
  private var halfBlockCache: [HalfBlockKey: [(UInt32?, UInt32?)]] = [:]

  /// Most image bytes transmitted between two full redraws before images
  /// are sent again.
  public static let resendThreshold = 64 << 20

  public init(mode: Mode, tmux: Bool = false, truecolor: Bool = true) {
    self.mode = mode
    self.tmux = tmux
    self.truecolor = truecolor
  }

  /// `$TMUX` and `$COLORTERM`, with `--graphics` deciding the mode when
  /// given; otherwise detection (`probe`) starts in `.off`.
  public convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    requested: Mode? = nil
  ) {
    let colorterm = environment["COLORTERM"]?.lowercased() ?? ""
    self.init(
      mode: requested ?? .off,
      tmux: environment["TMUX"] != nil,
      truecolor: colorterm == "truecolor" || colorterm == "24bit"
    )
  }

  // MARK: Detection

  /// The query image id; replies naming it decide detection.
  public static let probeID: UInt32 = 31

  /// A kitty graphics query fenced by DA1: a `G` reply before DA1's means
  /// the outer terminal draws kitty images.
  public var probe: [UInt8] {
    wrap(
      Array("\u{1B}_Gi=\(Self.probeID),s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\".utf8)
    ) + Array("\u{1B}[c".utf8)
  }

  /// Applies an outer-terminal reply during detection; true once decided.
  @discardableResult
  public func detect(_ reply: TerminalReply) -> Bool {
    switch reply {
    case let .graphics(body):
      guard body.hasPrefix("Gi=\(Self.probeID)") else { return false }
      mode = body.hasSuffix(";OK") ? .kitty : .halfBlocks
      return true
    case .deviceAttributes:
      if mode == .off { mode = .halfBlocks }
      return true
    }
  }

  /// A full redraw follows: images are sent again with it.
  public func invalidate() {
    transmitted = []
    sentSinceRedraw = 0
  }

  // MARK: Composition

  /// Draws `placements` (relative to a pane whose top-left cell is
  /// `origin`, clipped to `size` cells) into `screen`; returns bytes to
  /// write before the screen's diff.
  public func compose(
    _ placements: [KittyGraphics.Placement],
    hostCell: SIMD2<Int>,
    into screen: inout ScreenBuffer,
    origin: (x: Int, y: Int) = (0, 0),
    size: (columns: Int, rows: Int)? = nil
  ) -> [UInt8] {
    guard mode != .off, !placements.isEmpty else { return [] }
    let clip = size ?? (screen.columns, screen.rows)
    var out: [UInt8] = []
    if sentSinceRedraw > Self.resendThreshold { invalidate() }
    for p in placements where p.columns > 0 && p.rows > 0 {
      let key = ImageKey(
        serial: p.pixels.serial,
        source: [p.sourceX, p.sourceY, p.sourceWidth, p.sourceHeight],
        columns: p.columns,
        rows: p.rows
      )
      switch mode {
      case .kitty:
        let id = outerID(key)
        if !transmitted.contains(id) {
          out += transmit(p, id: id, columns: p.columns, rows: p.rows)
          transmitted.insert(id)
        }
        placeholders(p, id: id, into: &screen, origin: origin, clip: clip)
      case .halfBlocks:
        halfBlocks(p, key: key, into: &screen, origin: origin, clip: clip)
      case .off: break
      }
    }
    if !out.isEmpty { screen.unkeyAll() }
    sentSinceRedraw += out.count
    return out
  }

  private func outerID(_ key: ImageKey) -> UInt32 {
    if let id = outerIDs[key] { return id }
    let id = nextID
    // 24-bit ids encode as an RGB foreground with no third diacritic.
    nextID = nextID >= 0xFF_FFFF ? 1 : nextID + 1
    if let stale = outerIDs.first(where: { $0.value == id })?.key {
      outerIDs[stale] = nil
    }
    outerIDs[key] = id
    if outerIDs.count > 4096 { outerIDs.removeAll() }
    return id
  }

  private func wrap(_ sequence: [UInt8]) -> [UInt8] {
    guard tmux else { return sequence }
    var out = Array("\u{1B}Ptmux;".utf8)
    for b in sequence {
      if b == 0x1B { out.append(0x1B) }
      out.append(b)
    }
    return out + Array("\u{1B}\\".utf8)
  }

  /// The placement's source rect as RGBA, chunked 4096 base64 bytes per
  /// command, then one virtual placement.
  private func transmit(
    _ p: KittyGraphics.Placement,
    id: UInt32,
    columns: Int,
    rows: Int
  ) -> [UInt8] {
    let rgba = Self.crop(p)
    let encoded = Array(Data(rgba).base64EncodedString().utf8)
    var out: [UInt8] = []
    var i = 0
    var first = true
    repeat {
      let end = min(encoded.count, i + 4096)
      let more = end < encoded.count ? 1 : 0
      let keys =
        first
        ? "a=t,f=32,s=\(p.sourceWidth),v=\(p.sourceHeight),i=\(id),q=2,m=\(more)"
        : "m=\(more),q=2"
      out += wrap(
        Array("\u{1B}_G\(keys);".utf8) + encoded[i ..< end]
          + Array("\u{1B}\\".utf8)
      )
      first = false
      i = end
    } while i < encoded.count
    out += wrap(
      Array("\u{1B}_Ga=p,U=1,i=\(id),c=\(columns),r=\(rows),q=2\u{1B}\\".utf8)
    )
    return out
  }

  static func crop(_ p: KittyGraphics.Placement) -> [UInt8] {
    let px = p.pixels
    let rgba = px.rgba()
    let x0 = max(0, min(p.sourceX, px.width - 1))
    let y0 = max(0, min(p.sourceY, px.height - 1))
    let w = max(1, min(p.sourceWidth, px.width - x0))
    let h = max(1, min(p.sourceHeight, px.height - y0))
    if x0 == 0, y0 == 0, w == px.width, h == px.height { return rgba }
    var out: [UInt8] = []
    out.reserveCapacity(w * h * 4)
    for y in y0 ..< y0 + h {
      let start = (y * px.width + x0) * 4
      out += rgba[start ..< start + w * 4]
    }
    return out
  }

  private func visible(
    _ x: Int,
    _ y: Int,
    _ clip: (columns: Int, rows: Int)
  ) -> Bool { x >= 0 && y >= 0 && x < clip.columns && y < clip.rows }

  /// Only above-text placements replace text; others fill blank cells.
  private static func drawsOver(
    _ cell: ScreenCell,
    _ p: KittyGraphics.Placement
  ) -> Bool {
    p.layer == .aboveText && !p.isPlaceholder || cell.text == " "
      || cell.text.isEmpty || cell.text == "\u{10EEEE}"
      || cell.text.unicodeScalars.first?.value == KittyGraphics.placeholder
  }

  private func placeholders(
    _ p: KittyGraphics.Placement,
    id: UInt32,
    into screen: inout ScreenBuffer,
    origin: (x: Int, y: Int),
    clip: (columns: Int, rows: Int)
  ) {
    let d = KittyGraphics.diacritics
    for dy in 0 ..< p.rows where dy < d.count {
      for dx in 0 ..< p.columns where dx < d.count {
        let x = p.column + dx
        let y = p.row + dy
        guard visible(x, y, clip) else { continue }
        let sx = origin.x + x
        let sy = origin.y + y
        guard sx < screen.columns, sy < screen.rows else { continue }
        let existing = screen[sx, sy]
        guard Self.drawsOver(existing, p), existing.width == 1 else { continue }
        var style = existing.style
        style.foreground = .rgb(id & 0xFF_FFFF)
        style.underlineColor = .default
        var text = String(Character(Unicode.Scalar(KittyGraphics.placeholder)!))
        text.unicodeScalars.append(Unicode.Scalar(d[dy])!)
        text.unicodeScalars.append(Unicode.Scalar(d[dx])!)
        screen[sx, sy] = ScreenCell(text: text, width: 1, style: style)
      }
    }
  }

  // MARK: Half-blocks

  private func halfBlocks(
    _ p: KittyGraphics.Placement,
    key: ImageKey,
    into screen: inout ScreenBuffer,
    origin: (x: Int, y: Int),
    clip: (columns: Int, rows: Int)
  ) {
    // Only the cells inside the clip: a placement's grid is program
    // controlled and can be far larger than any screen.
    let rows = max(0, -p.row) ..< max(0, min(p.rows, clip.rows - p.row))
    let columns =
      max(0, -p.column) ..< max(0, min(p.columns, clip.columns - p.column))
    guard !rows.isEmpty, !columns.isEmpty else { return }
    let key = HalfBlockKey(image: key, rows: rows, columns: columns)
    let colors =
      halfBlockCache[key] ?? Self.sample(p, rows: rows, columns: columns)
    if halfBlockCache[key] == nil {
      if halfBlockCache.count > 256 { halfBlockCache.removeAll() }
      halfBlockCache[key] = colors
    }
    for dy in rows {
      for dx in columns {
        let x = p.column + dx
        let y = p.row + dy
        guard visible(x, y, clip) else { continue }
        let sx = origin.x + x
        let sy = origin.y + y
        guard sx < screen.columns, sy < screen.rows else { continue }
        let existing = screen[sx, sy]
        guard Self.drawsOver(existing, p), existing.width == 1 else { continue }
        let (top, bottom) = colors[
          (dy - rows.lowerBound) * columns.count + dx - columns.lowerBound
        ]
        guard top != nil || bottom != nil else { continue }
        var style = existing.style
        style.flags = 0
        style.foreground = top.map(color) ?? existing.style.background
        style.background = bottom.map(color) ?? existing.style.background
        screen[sx, sy] = ScreenCell(text: "\u{2580}", width: 1, style: style)
      }
    }
  }

  private func color(_ rgb: UInt32) -> OuterColor {
    truecolor ? .rgb(rgb) : .palette(Self.palette256(rgb))
  }

  /// Box-filtered top and bottom halves of the cells in `rows` ×
  /// `columns` of the placement's grid; nil where the image is mostly
  /// transparent.
  static func sample(
    _ p: KittyGraphics.Placement,
    rows: Range<Int>,
    columns: Range<Int>
  ) -> [(UInt32?, UInt32?)] {
    let px = p.pixels
    let rgba = px.rgba()
    var out: [(UInt32?, UInt32?)] = []
    out.reserveCapacity(rows.count * columns.count)
    let sw = Double(max(1, p.sourceWidth)) / Double(p.columns)
    let sh = Double(max(1, p.sourceHeight)) / Double(p.rows * 2)
    func average(_ x0: Double, _ y0: Double) -> UInt32? {
      let xa = Int(x0)
      let xb = max(xa + 1, Int(x0 + sw))
      let ya = Int(y0)
      let yb = max(ya + 1, Int(y0 + sh))
      var r = 0
      var g = 0
      var b = 0
      var a = 0
      var n = 0
      for y in ya ..< yb {
        let yy = min(max(p.sourceY + y, 0), px.height - 1)
        for x in xa ..< xb {
          let xx = min(max(p.sourceX + x, 0), px.width - 1)
          let i = (yy * px.width + xx) * 4
          let alpha = Int(rgba[i + 3])
          r += Int(rgba[i]) * alpha
          g += Int(rgba[i + 1]) * alpha
          b += Int(rgba[i + 2]) * alpha
          a += alpha
          n += 1
        }
      }
      guard n > 0, a * 2 >= n * 255 else { return nil }
      return UInt32(r / a) << 16 | UInt32(g / a) << 8 | UInt32(b / a)
    }
    for row in rows {
      for column in columns {
        let x = Double(column) * sw
        let y = Double(row * 2) * sh
        out.append((average(x, y), average(x, y + sh)))
      }
    }
    return out
  }

  /// The nearest xterm 256-colour cube or grey entry.
  static func palette256(_ rgb: UInt32) -> UInt8 {
    let r = Int(rgb >> 16 & 0xFF)
    let g = Int(rgb >> 8 & 0xFF)
    let b = Int(rgb & 0xFF)
    func level(_ v: Int) -> Int { v < 48 ? 0 : v < 115 ? 1 : (v - 35) / 40 }
    let steps = [0, 95, 135, 175, 215, 255]
    let (cr, cg, cb) = (level(r), level(g), level(b))
    let cube = 16 + 36 * cr + 6 * cg + cb
    let cubeError =
      (steps[cr] - r) * (steps[cr] - r) + (steps[cg] - g) * (steps[cg] - g)
      + (steps[cb] - b) * (steps[cb] - b)
    let grey = (r + g + b) / 3
    let gi = max(0, min(23, (grey - 3) / 10))
    let gv = 8 + gi * 10
    let greyError =
      (gv - r) * (gv - r) + (gv - g) * (gv - g) + (gv - b) * (gv - b)
    return UInt8(greyError < cubeError ? 232 + gi : cube)
  }
}

/// A reply from the outer terminal, never forwarded to the remote program.
public enum TerminalReply: Equatable, Sendable {
  /// `ESC _ <body> ESC \`, body starting with `G`.
  case graphics(String)
  /// DA1, `ESC [ ? … c`.
  case deviceAttributes(String)
}
