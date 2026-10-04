import CoreGraphics

/// Box-drawing (U+2500–257F) and block-element (U+2580–259F) glyphs drawn
/// to the cell's exact size, so lines join across cells whatever the font.
enum BoxDrawing {
    /// Per scalar from U+2500: 2-bit weights for up, right, down, left
    /// (0 none, 1 light, 2 heavy, 3 double); bit 8 marks a rounded corner.
    /// Dashed lines draw solid; 0 (diagonals) falls back to the font.
    static let segments: [UInt16] = [
        0x044, 0x088, 0x011, 0x022, 0x044, 0x088, 0x011, 0x022,
        0x044, 0x088, 0x011, 0x022, 0x014, 0x018, 0x024, 0x028,
        0x050, 0x090, 0x060, 0x0A0, 0x005, 0x009, 0x006, 0x00A,
        0x041, 0x081, 0x042, 0x082, 0x015, 0x019, 0x016, 0x025,
        0x026, 0x01A, 0x029, 0x02A, 0x051, 0x091, 0x052, 0x061,
        0x062, 0x092, 0x0A1, 0x0A2, 0x054, 0x094, 0x058, 0x098,
        0x064, 0x0A4, 0x068, 0x0A8, 0x045, 0x085, 0x049, 0x089,
        0x046, 0x086, 0x04A, 0x08A, 0x055, 0x095, 0x059, 0x099,
        0x056, 0x065, 0x066, 0x096, 0x05A, 0x0A5, 0x069, 0x09A,
        0x0A9, 0x0A6, 0x06A, 0x0AA, 0x044, 0x088, 0x011, 0x022,
        0x0CC, 0x033, 0x01C, 0x034, 0x03C, 0x0D0, 0x070, 0x0F0,
        0x00D, 0x007, 0x00F, 0x0C1, 0x043, 0x0C3, 0x01D, 0x037,
        0x03F, 0x0D1, 0x073, 0x0F3, 0x0DC, 0x074, 0x0FC, 0x0CD,
        0x047, 0x0CF, 0x0DD, 0x077, 0x0FF, 0x114, 0x150, 0x141,
        0x105, 0x000, 0x000, 0x000, 0x040, 0x001, 0x004, 0x010,
        0x080, 0x002, 0x008, 0x020, 0x048, 0x021, 0x084, 0x012,
    ]

    static func covers(_ cp: UInt32) -> Bool {
        if (0x2500 ... 0x257F).contains(cp) {
            return segments[Int(cp - 0x2500)] != 0
        }
        return (0x2580 ... 0x259F).contains(cp)
    }

    /// Draws white coverage into a context sized to one cell (origin bottom-left).
    static func draw(_ cp: UInt32, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        if cp >= 0x2580 {
            block(cp, ctx, w, h)
            return
        }
        let s = segments[Int(cp - 0x2500)]
        let light = max(1, (min(w, h) / 8).rounded())
        let cx = (w / 2).rounded(.down), cy = (h / 2).rounded(.down)
        let weights = [s & 3, s >> 2 & 3, s >> 4 & 3, s >> 6 & 3].map(Int.init) // up right down left
        if s & 0x100 != 0 {
            arc(weights, ctx, w, h, light)
            return
        }
        func thickness(_ k: Int) -> CGFloat {
            k == 2 ? light * 2 : light
        }
        let vertical = max(weights[0], weights[2]), horizontal = max(weights[1], weights[3])
        // Half-width of the perpendicular stroke, so segments meet in the centre.
        let hReach = vertical == 3 ? light * 1.5 : thickness(vertical) / 2
        let vReach = horizontal == 3 ? light * 1.5 : thickness(horizontal) / 2
        for (i, k) in weights.enumerated() where k != 0 {
            let offsets: [CGFloat] = k == 3 ? [-light, light] : [0]
            let t = thickness(k)
            for o in offsets {
                switch i {
                case 0: ctx.fill(CGRect(x: cx - t / 2 + o, y: cy - vReach, width: t, height: h - cy + vReach)) // up (top is high y)
                case 2: ctx.fill(CGRect(x: cx - t / 2 + o, y: 0, width: t, height: cy + vReach))
                case 1: ctx.fill(CGRect(x: cx - hReach, y: cy - t / 2 + o, width: w - cx + hReach, height: t))
                default: ctx.fill(CGRect(x: 0, y: cy - t / 2 + o, width: cx + hReach, height: t))
                }
            }
        }
    }

    private static func arc(_ weights: [Int], _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: CGFloat) {
        let cx = (w / 2).rounded(.down), cy = (h / 2).rounded(.down)
        let up = weights[0] != 0, right = weights[1] != 0
        let path = CGMutablePath()
        let start = CGPoint(x: cx, y: up ? h : 0)
        let end = CGPoint(x: right ? w : 0, y: cy)
        path.move(to: start)
        path.addLine(to: CGPoint(x: cx, y: up ? cy + min(cx, cy) : cy - min(cx, cy)))
        path.addQuadCurve(to: CGPoint(x: right ? cx + min(cx, cy) : cx - min(cx, cy), y: cy), control: CGPoint(x: cx, y: cy))
        path.addLine(to: end)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(t)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func block(_ cp: UInt32, _ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            // Fractions of the cell, y measured from the top.
            ctx.fill(CGRect(
                x: (x0 * w).rounded(),
                y: ((1 - y1) * h).rounded(),
                width: ((x1 - x0) * w).rounded(),
                height: ((y1 - y0) * h).rounded(),
            ))
        }
        switch cp {
        case 0x2580: rect(0, 0, 1, 0.5)
        case 0x2581 ... 0x2588: rect(0, 1 - CGFloat(cp - 0x2580) / 8, 1, 1)
        case 0x2589 ... 0x258F: rect(0, 0, CGFloat(0x2590 - cp) / 8, 1)
        case 0x2590: rect(0.5, 0, 1, 1)
        case 0x2591 ... 0x2593:
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(cp - 0x2590) / 4))
            rect(0, 0, 1, 1)
        case 0x2594: rect(0, 0, 1, 0.125)
        case 0x2595: rect(0.875, 0, 1, 1)
        default:
            // Quadrants U+2596–259F: bits upper-left, upper-right, lower-left, lower-right.
            let quads: [UInt8] = [0b0010, 0b0001, 0b1000, 0b1011, 0b1001, 0b1110, 0b1101, 0b0100, 0b0110, 0b0111]
            let q = quads[Int(cp - 0x2596)]
            if q & 0b1000 != 0 {
                rect(0, 0, 0.5, 0.5)
            }
            if q & 0b0100 != 0 {
                rect(0.5, 0, 1, 0.5)
            }
            if q & 0b0010 != 0 {
                rect(0, 0.5, 0.5, 1)
            }
            if q & 0b0001 != 0 {
                rect(0.5, 0.5, 1, 1)
            }
        }
    }
}
