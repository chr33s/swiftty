/// A terminal color: default, a palette index, or direct RGB.
///
/// Packed as `0xTTRRGGBB` where `TT` is the tag so a cell stays 16 bytes.
public struct TerminalColor: Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt32

    @inlinable public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let `default` = TerminalColor(rawValue: 0)
    @inlinable public static func palette(_ index: UInt8) -> TerminalColor {
        TerminalColor(rawValue: 0x0100_0000 | UInt32(index))
    }

    @inlinable public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> TerminalColor {
        TerminalColor(rawValue: 0x0200_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    public enum Kind: Sendable, Equatable { case `default`, palette(UInt8), rgb(UInt32) }

    @inlinable public var kind: Kind {
        switch rawValue >> 24 {
        case 1: .palette(UInt8(truncatingIfNeeded: rawValue))
        case 2: .rgb(rawValue & 0xFFFFFF)
        default: .default
        }
    }
}

public struct CellFlags: OptionSet, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt16
    @inlinable public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = CellFlags(rawValue: 1 << 0)
    public static let faint = CellFlags(rawValue: 1 << 1)
    public static let italic = CellFlags(rawValue: 1 << 2)
    public static let underline = CellFlags(rawValue: 1 << 3)
    public static let doubleUnderline = CellFlags(rawValue: 1 << 4)
    public static let blink = CellFlags(rawValue: 1 << 5)
    public static let inverse = CellFlags(rawValue: 1 << 6)
    public static let invisible = CellFlags(rawValue: 1 << 7)
    public static let strikethrough = CellFlags(rawValue: 1 << 8)
    public static let overline = CellFlags(rawValue: 1 << 9)

    /// Right half of a wide character; renders nothing.
    public static let spacerTail = CellFlags(rawValue: 1 << 12)
    /// Padding at the end of a row where a wide character did not fit.
    public static let spacerHead = CellFlags(rawValue: 1 << 13)
    /// `glyph` is an id into the grapheme table instead of a scalar.
    public static let grapheme = CellFlags(rawValue: 1 << 14)

    /// Flags owned by the cell content rather than the pen.
    public static let structural: CellFlags = [.spacerTail, .spacerHead, .grapheme]
}

public struct CellAttributes: Hashable, Sendable, BitwiseCopyable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var flags: CellFlags

    @inlinable public init(
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        flags: CellFlags = [],
    ) {
        self.foreground = foreground
        self.background = background
        self.flags = flags
    }

    public static let `default` = CellAttributes()
}

/// One grid cell. 16 bytes, trivially copyable, never heap allocated.
/// `glyph` must stay at offset 0: `TerminalState.storeASCII` relies on it.
public struct Cell: Hashable, Sendable, BitwiseCopyable {
    /// Unicode scalar value, `0` for an empty cell, or a grapheme id when
    /// `attributes.flags` contains `.grapheme`.
    public var glyph: UInt32
    public var attributes: CellAttributes
    /// Columns occupied: 1, 2 for a wide lead, 0 for a spacer.
    public var width: UInt8

    @inlinable public init(glyph: UInt32, attributes: CellAttributes, width: UInt8) {
        self.glyph = glyph
        self.attributes = attributes
        self.width = width
    }

    public static let blank = Cell(glyph: 0, attributes: .default, width: 1)

    /// An erased cell keeps only the pen background (BCE).
    @inlinable public static func erased(background: TerminalColor) -> Cell {
        Cell(glyph: 0, attributes: CellAttributes(background: background), width: 1)
    }

    @inlinable public var isBlank: Bool {
        glyph == 0 && width == 1 && attributes.foreground.rawValue == 0
            && attributes.background.rawValue == 0 && attributes.flags.rawValue == 0
    }

    @inlinable public var flags: CellFlags {
        attributes.flags
    }

    @inlinable public var isGrapheme: Bool {
        attributes.flags.contains(.grapheme)
    }

    @inlinable public var isSpacer: Bool {
        !attributes.flags.isDisjoint(with: [.spacerTail, .spacerHead])
    }
}

/// 256-color palette plus the special default colors, as `0xRRGGBB`.
public struct Palette: Sendable, Equatable {
    public var colors: InlineArray<256, UInt32>
    public var foreground: UInt32
    public var background: UInt32
    public var cursor: UInt32

    public static let standard: Palette = {
        let base: [UInt32] = [
            0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
            0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA,
        ]
        var colors = InlineArray<256, UInt32>(repeating: 0)
        for i in 0 ..< 16 {
            colors[i] = base[i]
        }
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for i in 0 ..< 216 {
            colors[16 + i] = steps[i / 36] << 16 | steps[(i / 6) % 6] << 8 | steps[i % 6]
        }
        for i in 0 ..< 24 {
            let v = UInt32(8 + i * 10)
            colors[232 + i] = v << 16 | v << 8 | v
        }
        return Palette(colors: colors, foreground: 0xFFFFFF, background: 0x282C34, cursor: 0xFFFFFF)
    }()

    /// Resolves a cell color to RGB; `isForeground` picks the default.
    @inlinable
    public func resolve(_ color: TerminalColor, isForeground: Bool) -> UInt32 {
        switch color.rawValue >> 24 {
        case 1: colors[Int(color.rawValue & 0xFF)]
        case 2: color.rawValue & 0xFFFFFF
        default: isForeground ? foreground : background
        }
    }

    public static func == (lhs: Palette, rhs: Palette) -> Bool {
        guard lhs.foreground == rhs.foreground, lhs.background == rhs.background,
              lhs.cursor == rhs.cursor else { return false }
        for i in 0 ..< 256 where lhs.colors[i] != rhs.colors[i] {
            return false
        }
        return true
    }
}
