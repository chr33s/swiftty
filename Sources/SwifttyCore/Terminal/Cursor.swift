public struct Cursor: Sendable, Equatable {
    public enum Charset: UInt8, Sendable { case ascii, decSpecialGraphics, british }

    public var x = 0
    public var y = 0
    /// Set after printing in the last column; the next print wraps first.
    public var pendingWrap = false
    public var pen = CellAttributes.default
    public var g0 = Charset.ascii
    public var g1 = Charset.ascii
    public var g2 = Charset.ascii
    public var g3 = Charset.ascii
    /// Slot (0...3) invoked into GL by SI/SO/LS2/LS3.
    public var gl: UInt8 = 0
    /// Slot used for the next printed cell only (SS2/SS3).
    public var singleShift: UInt8?

    /// SO selects G1 into GL.
    public var shiftedOut: Bool {
        get { gl == 1 }
        set { gl = newValue ? 1 : 0 }
    }

    /// DECSCA / SPA: printed cells are protected from selective erase.
    public var isProtected: Bool {
        get { pen.flags.contains(.protected) }
        set {
            if newValue {
                pen.flags.insert(.protected)
            } else {
                pen.flags.remove(.protected)
            }
        }
    }

    func charset(_ slot: UInt8) -> Charset {
        switch slot {
        case 0: g0
        case 1: g1
        case 2: g2
        default: g3
        }
    }

    mutating func setCharset(_ slot: UInt8, _ set: Charset) {
        switch slot {
        case 0: g0 = set
        case 1: g1 = set
        case 2: g2 = set
        default: g3 = set
        }
    }

    @inline(__always) var activeCharset: Charset {
        charset(singleShift ?? gl)
    }

    /// No translation applies to the next printed cell.
    @inline(__always) var printsPlain: Bool {
        singleShift == nil && charset(gl) == .ascii
    }
}
