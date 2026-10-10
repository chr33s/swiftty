import CoreGraphics

/// Box drawing (U+2500–257F), block elements (U+2580–259F), Braille
/// (U+2800–28FF), sextants (U+1FB00–1FB3B) and Powerline separators
/// (U+E0B0–E0B7), drawn to the cell's exact size so they join across cells
/// whatever the font.
enum BoxDrawing {
  /// Per scalar from U+2500: 2-bit weights for up, right, down, left
  /// (0 none, 1 light, 2 heavy, 3 double); bit 8 marks a rounded corner.
  /// 0 marks the diagonals, which are drawn separately.
  static let segments: [UInt16] = [
    0x044, 0x088, 0x011, 0x022, 0x044, 0x088, 0x011, 0x022, 0x044, 0x088, 0x011,
    0x022, 0x014, 0x018, 0x024, 0x028, 0x050, 0x090, 0x060, 0x0A0, 0x005, 0x009,
    0x006, 0x00A, 0x041, 0x081, 0x042, 0x082, 0x015, 0x019, 0x016, 0x025, 0x026,
    0x01A, 0x029, 0x02A, 0x051, 0x091, 0x052, 0x061, 0x062, 0x092, 0x0A1, 0x0A2,
    0x054, 0x094, 0x058, 0x098, 0x064, 0x0A4, 0x068, 0x0A8, 0x045, 0x085, 0x049,
    0x089, 0x046, 0x086, 0x04A, 0x08A, 0x055, 0x095, 0x059, 0x099, 0x056, 0x065,
    0x066, 0x096, 0x05A, 0x0A5, 0x069, 0x09A, 0x0A9, 0x0A6, 0x06A, 0x0AA, 0x044,
    0x088, 0x011, 0x022, 0x0CC, 0x033, 0x01C, 0x034, 0x03C, 0x0D0, 0x070, 0x0F0,
    0x00D, 0x007, 0x00F, 0x0C1, 0x043, 0x0C3, 0x01D, 0x037, 0x03F, 0x0D1, 0x073,
    0x0F3, 0x0DC, 0x074, 0x0FC, 0x0CD, 0x047, 0x0CF, 0x0DD, 0x077, 0x0FF, 0x114,
    0x150, 0x141, 0x105, 0x000, 0x000, 0x000, 0x040, 0x001, 0x004, 0x010, 0x080,
    0x002, 0x008, 0x020, 0x048, 0x021, 0x084, 0x012,
  ]

  static func covers(_ cp: UInt32) -> Bool {
    switch cp {
    case 0x2500 ... 0x259F, 0x2800 ... 0x28FF, 0x1FB00 ... 0x1FB3B,
      0xE0B0 ... 0xE0B7:
      true
    default: false
    }
  }

  /// Draws white coverage into a context sized to one cell (origin bottom-left).
  static func draw(
    _ cp: UInt32,
    in ctx: CGContext,
    width w: CGFloat,
    height h: CGFloat
  ) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let light = max(1, (min(w, h) / 8).rounded())
    switch cp {
    case 0x2580 ... 0x259F: block(cp, ctx, w, h)
    case 0x2800 ... 0x28FF: braille(cp, ctx, w, h)
    case 0x1FB00 ... 0x1FB3B: sextant(cp, ctx, w, h)
    case 0xE0B0 ... 0xE0B7: powerline(cp, ctx, w, h, light)
    case 0x2571 ... 0x2573: diagonal(cp, ctx, w, h, light)
    default: lines(cp, ctx, w, h, light)
    }
  }

  /// Dash count for the dashed lines (drawn with `segments`' weights).
  static func dashes(_ cp: UInt32) -> Int? {
    switch cp {
    case 0x2504 ... 0x2507: 3
    case 0x2508 ... 0x250B: 4
    case 0x254C ... 0x254F: 2
    default: nil
    }
  }

  private static func lines(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat,
    _ light: CGFloat
  ) {
    let s = segments[Int(cp - 0x2500)]
    let cx = (w / 2).rounded(.down)
    let cy = (h / 2).rounded(.down)
    // up right down left
    let weights = [s & 3, s >> 2 & 3, s >> 4 & 3, s >> 6 & 3].map(Int.init)
    if s & 0x100 != 0 {
      arc(weights, ctx, w, h, light)
      return
    }
    if let n = dashes(cp) {
      // Equal slots with the gap split across both ends, so dashes
      // stay evenly spaced from one cell into the next.
      let t = weights[1] == 2 || weights[0] == 2 ? light * 2 : light
      let gap = max(1, light)
      let horizontal = weights[1] != 0
      let length = horizontal ? w : h
      for i in 0 ..< n {
        let a = (CGFloat(i) * length / CGFloat(n) + gap / 2).rounded()
        let b = (CGFloat(i + 1) * length / CGFloat(n) - gap / 2).rounded()
        ctx.fill(
          horizontal
            ? CGRect(x: a, y: cy - t / 2, width: b - a, height: t)
            : CGRect(x: cx - t / 2, y: a, width: t, height: b - a)
        )
      }
      return
    }
    func thickness(_ k: Int) -> CGFloat { k == 2 ? light * 2 : light }
    let vertical = max(weights[0], weights[2])
    let horizontal = max(weights[1], weights[3])
    // Half-width of the perpendicular stroke, so segments meet in the centre.
    let hReach = vertical == 3 ? light * 1.5 : thickness(vertical) / 2
    let vReach = horizontal == 3 ? light * 1.5 : thickness(horizontal) / 2
    for (i, k) in weights.enumerated() where k != 0 {
      let offsets: [CGFloat] = k == 3 ? [-light, light] : [0]
      let t = thickness(k)
      for o in offsets {
        switch i {
        case 0:
          ctx.fill(
            CGRect(
              x: cx - t / 2 + o,
              y: cy - vReach,
              width: t,
              height: h - cy + vReach
            )
          )  // up (top is high y)
        case 2:
          ctx.fill(
            CGRect(x: cx - t / 2 + o, y: 0, width: t, height: cy + vReach)
          )
        case 1:
          ctx.fill(
            CGRect(
              x: cx - hReach,
              y: cy - t / 2 + o,
              width: w - cx + hReach,
              height: t
            )
          )
        default:
          ctx.fill(
            CGRect(x: 0, y: cy - t / 2 + o, width: cx + hReach, height: t)
          )
        }
      }
    }
  }

  private static func arc(
    _ weights: [Int],
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat,
    _ t: CGFloat
  ) {
    let cx = (w / 2).rounded(.down)
    let cy = (h / 2).rounded(.down)
    let up = weights[0] != 0
    let right = weights[1] != 0
    let path = CGMutablePath()
    let start = CGPoint(x: cx, y: up ? h : 0)
    let end = CGPoint(x: right ? w : 0, y: cy)
    path.move(to: start)
    path.addLine(
      to: CGPoint(x: cx, y: up ? cy + min(cx, cy) : cy - min(cx, cy))
    )
    path.addQuadCurve(
      to: CGPoint(x: right ? cx + min(cx, cy) : cx - min(cx, cy), y: cy),
      control: CGPoint(x: cx, y: cy)
    )
    path.addLine(to: end)
    ctx.setLineWidth(t)
    ctx.addPath(path)
    ctx.strokePath()
  }

  /// U+2571 ╱, U+2572 ╲, U+2573 ╳: corner to corner, overshooting so
  /// neighbouring cells join.
  private static func diagonal(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat,
    _ t: CGFloat
  ) {
    let dx = w / h * t
    let dy = t
    ctx.setLineWidth(t)
    ctx.setLineCap(.square)
    if cp != 0x2572 {  // lower-left to upper-right
      ctx.move(to: CGPoint(x: -dx, y: -dy))
      ctx.addLine(to: CGPoint(x: w + dx, y: h + dy))
    }
    if cp != 0x2571 {  // upper-left to lower-right
      ctx.move(to: CGPoint(x: -dx, y: h + dy))
      ctx.addLine(to: CGPoint(x: w + dx, y: -dy))
    }
    ctx.strokePath()
  }

  /// Dots in a 2×4 grid; bits 0–2 and 6 are the left column top to bottom,
  /// 3–5 and 7 the right.
  private static func braille(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat
  ) {
    let bits = cp - 0x2800
    let positions: [(column: Int, row: Int)] = [
      (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3),
    ]
    let d = max(1, (min(w / 2, h / 4) * 0.6).rounded())
    for (bit, p) in positions.enumerated() where bits & 1 << bit != 0 {
      let x = ((CGFloat(p.column) + 0.5) * w / 2 - d / 2).rounded()
      let y = h - ((CGFloat(p.row) + 0.5) * h / 4 + d / 2).rounded()
      ctx.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
    }
  }

  /// 2×3 blocks. Sextant n is the n-th mask from 1 to 62, skipping the
  /// two half blocks (21 and 42) that exist as U+258C and U+2590.
  private static func sextant(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat
  ) {
    var mask = Int(cp - 0x1FB00) + 1
    if mask >= 21 { mask += 1 }
    if mask >= 42 { mask += 1 }
    for bit in 0 ..< 6 where mask & 1 << bit != 0 {
      let column = CGFloat(bit % 2)
      let row = CGFloat(bit / 2)
      let x0 = (column * w / 2).rounded()
      let x1 = ((column + 1) * w / 2).rounded()
      let y0 = (row * h / 3).rounded()
      let y1 = ((row + 1) * h / 3).rounded()
      ctx.fill(CGRect(x: x0, y: h - y1, width: x1 - x0, height: y1 - y0))
    }
  }

  /// Powerline separators: solid and outline triangles (E0B0–E0B3) and
  /// half circles (E0B4–E0B7): solid then outline, pointing right then left.
  private static func powerline(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat,
    _ t: CGFloat
  ) {
    let right = cp & 2 == 0
    let solid = cp & 1 == 0
    let base: CGFloat = right ? 0 : w
    let tip: CGFloat = right ? w : 0
    let path = CGMutablePath()
    if cp < 0xE0B4 {
      path.move(to: CGPoint(x: base, y: h))
      path.addLine(to: CGPoint(x: tip, y: h / 2))
      path.addLine(to: CGPoint(x: base, y: 0))
    } else {
      path.move(to: CGPoint(x: base, y: h))
      path.addCurve(
        to: CGPoint(x: base, y: 0),
        control1: CGPoint(x: base + (tip - base) * 4 / 3, y: h),
        control2: CGPoint(x: base + (tip - base) * 4 / 3, y: 0),
      )
    }
    if solid {
      path.closeSubpath()
      ctx.addPath(path)
      ctx.fillPath()
    } else {
      ctx.setLineWidth(t)
      ctx.addPath(path)
      ctx.strokePath()
    }
  }

  private static func block(
    _ cp: UInt32,
    _ ctx: CGContext,
    _ w: CGFloat,
    _ h: CGFloat
  ) {
    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
      // Fractions of the cell, y measured from the top.
      ctx.fill(
        CGRect(
          x: (x0 * w).rounded(),
          y: ((1 - y1) * h).rounded(),
          width: ((x1 - x0) * w).rounded(),
          height: ((y1 - y0) * h).rounded(),
        )
      )
    }
    switch cp {
    case 0x2580: rect(0, 0, 1, 0.5)
    case 0x2581 ... 0x2588: rect(0, 1 - CGFloat(cp - 0x2580) / 8, 1, 1)
    case 0x2589 ... 0x258F: rect(0, 0, CGFloat(0x2590 - cp) / 8, 1)
    case 0x2590: rect(0.5, 0, 1, 1)
    case 0x2591 ... 0x2593:
      ctx.setFillColor(
        CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(cp - 0x2590) / 4)
      )
      rect(0, 0, 1, 1)
    case 0x2594: rect(0, 0, 1, 0.125)
    case 0x2595: rect(0.875, 0, 1, 1)
    default:
      // Quadrants U+2596–259F: bits upper-left, upper-right, lower-left, lower-right.
      let quads: [UInt8] = [
        0b0010, 0b0001, 0b1000, 0b1011, 0b1001, 0b1110, 0b1101, 0b0100, 0b0110,
        0b0111,
      ]
      let q = quads[Int(cp - 0x2596)]
      if q & 0b1000 != 0 { rect(0, 0, 0.5, 0.5) }
      if q & 0b0100 != 0 { rect(0.5, 0, 1, 0.5) }
      if q & 0b0010 != 0 { rect(0, 0.5, 0.5, 1) }
      if q & 0b0001 != 0 { rect(0.5, 0.5, 1, 1) }
    }
  }
}
