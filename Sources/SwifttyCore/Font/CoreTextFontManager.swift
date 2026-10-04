import CoreGraphics
import CoreText
import Foundation

public struct FontDescriptor: Hashable, Sendable {
    public var family: String
    /// Point size; multiplied by `scale` for pixel rendering.
    public var size: CGFloat
    /// Backing scale factor (2 on Retina).
    public var scale: CGFloat

    public init(family: String = "Menlo", size: CGFloat = 13, scale: CGFloat = 2) {
        self.family = family
        self.size = size
        self.scale = scale
    }
}

public struct FontStyle: OptionSet, Hashable, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold = FontStyle(rawValue: 1)
    public static let italic = FontStyle(rawValue: 2)

    public init(_ flags: CellFlags) {
        self = []
        if flags.contains(.bold) {
            insert(.bold)
        }
        if flags.contains(.italic) {
            insert(.italic)
        }
    }
}

/// A primary font in its four styles plus pixel cell metrics.
public final class ResolvedFont: @unchecked Sendable {
    public let descriptor: FontDescriptor
    /// Indexed by `FontStyle.rawValue`: regular, bold, italic, bold italic.
    public let faces: [CTFont]
    public let emoji: CTFont

    // Metrics in pixels.
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let underlinePosition: CGFloat
    public let underlineThickness: CGFloat

    init(descriptor: FontDescriptor) {
        self.descriptor = descriptor
        let pixelSize = descriptor.size * descriptor.scale
        var regular = CTFontCreateWithName(descriptor.family as CFString, pixelSize, nil)
        if !(CTFontCopyFamilyName(regular) as String).localizedCaseInsensitiveContains(descriptor.family) {
            regular = CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil) ?? regular
        }
        func styled(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) ?? regular
        }
        faces = [regular, styled(.traitBold), styled(.traitItalic), styled([.traitBold, .traitItalic])]
        emoji = CTFontCreateWithName("Apple Color Emoji" as CFString, pixelSize, nil)

        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        ascent = ceil(CTFontGetAscent(regular))
        descent = ceil(CTFontGetDescent(regular))
        let leading = ceil(CTFontGetLeading(regular))
        cellWidth = ceil(advance.width)
        cellHeight = ascent + descent + leading
        underlinePosition = ascent - CTFontGetUnderlinePosition(regular)
        underlineThickness = max(1, round(CTFontGetUnderlineThickness(regular)))
    }

    public func face(_ style: FontStyle) -> CTFont {
        faces[Int(style.rawValue & 3)]
    }
}

/// A glyph in a specific (possibly fallback) font.
public struct GlyphLookup: @unchecked Sendable {
    public let font: CTFont
    public let glyph: CGGlyph
    public let isColor: Bool
}

/// Resolves fonts and per-scalar glyphs with fallback, using CoreText directly.
public final class CoreTextFontManager {
    private var fonts: [FontDescriptor: ResolvedFont] = [:]
    private var lookups: [UInt64: GlyphLookup?] = [:]
    private var lookupFont: ObjectIdentifier?

    public init() {}

    public func resolve(_ descriptor: FontDescriptor) -> ResolvedFont {
        if let font = fonts[descriptor] {
            return font
        }
        let font = ResolvedFont(descriptor: descriptor)
        fonts[descriptor] = font
        return font
    }

    /// Glyph for `scalar` in the primary (regular) face, without fallback.
    public func glyph(for scalar: Unicode.Scalar, in font: ResolvedFont) -> CGGlyph? {
        Self.glyph(scalar, in: font.faces[0])
    }

    /// Glyph for `scalar` in `style`, falling back to emoji and system
    /// cascade fonts. Results are cached per font.
    public func lookup(_ scalar: Unicode.Scalar, style: FontStyle, in font: ResolvedFont) -> GlyphLookup? {
        if lookupFont != ObjectIdentifier(font) {
            lookups.removeAll(keepingCapacity: true)
            lookupFont = ObjectIdentifier(font)
        }
        let key = UInt64(scalar.value) | UInt64(style.rawValue) << 32
        if let cached = lookups[key] {
            return cached
        }
        let result = resolveGlyph(scalar, style: style, font: font)
        lookups[key] = result
        return result
    }

    private func resolveGlyph(_ scalar: Unicode.Scalar, style: FontStyle, font: ResolvedFont) -> GlyphLookup? {
        let face = font.face(style)
        let emojiPresentation = scalar.properties.isEmojiPresentation
        if !emojiPresentation, let glyph = Self.glyph(scalar, in: face) {
            return GlyphLookup(font: face, glyph: glyph, isColor: false)
        }
        if scalar.properties.isEmoji, let glyph = Self.glyph(scalar, in: font.emoji) {
            return GlyphLookup(font: font.emoji, glyph: glyph, isColor: true)
        }
        let string = String(scalar) as CFString
        let fallback = CTFontCreateForString(face, string, CFRange(location: 0, length: CFStringGetLength(string)))
        if let glyph = Self.glyph(scalar, in: fallback) {
            let isColor = CTFontGetSymbolicTraits(fallback).contains(.traitColorGlyphs)
            return GlyphLookup(font: fallback, glyph: glyph, isColor: isColor)
        }
        return nil
    }

    static func glyph(_ scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph? {
        var utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }
}
