import CoreGraphics
import CoreText
import Foundation

public struct FontDescriptor: Hashable, Sendable {
    public var family: String
    /// Point size; multiplied by `scale` for pixel rendering.
    public var size: CGFloat
    /// Backing scale factor (2 on Retina).
    public var scale: CGFloat
    /// Cell size adjustments as fractions (0.1 = 10% larger).
    public var cellWidthAdjust: CGFloat = 0
    public var cellHeightAdjust: CGFloat = 0
    /// Further cell size adjustments in points (Ghostty's `adjust-cell-*`
    /// given as a number rather than a percentage).
    public var cellWidthOffset: CGFloat = 0
    public var cellHeightOffset: CGFloat = 0
    /// Families tried, in order, before the system cascade (e.g. a symbols font).
    public var fallbackFamilies: [String] = []
    /// OpenType feature tags, `-tag` to disable (Ghostty's `font-feature`).
    /// Any enabled feature turns on shaping (ligatures, alternates).
    public var features: [String] = []
    /// Families for the other styles (Ghostty's `font-family-bold` etc.);
    /// nil derives the style from `family`.
    public var boldFamily: String?
    public var italicFamily: String?
    public var boldItalicFamily: String?
    /// Variable-font axes by four-letter tag (Ghostty's `font-variation`).
    public var variations: [String: Double] = [:]
    /// Draw a missing bold face by stroking the regular one, and a missing
    /// italic by slanting it (Ghostty's `font-synthetic-style`).
    public var synthesizeBold = true
    public var synthesizeItalic = true

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
    public let fallbacks: [CTFont]
    /// Rows are shaped with CoreText (an enabled OpenType feature).
    public let shapes: Bool
    /// Per style: no bold face exists, so glyphs are stroked to embolden them.
    public let emboldened: [Bool]

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
        func named(_ family: String) -> CTFont? {
            let font = CTFontCreateWithName(family as CFString, pixelSize, nil)
            return (CTFontCopyFamilyName(font) as String).localizedCaseInsensitiveContains(family) ? font : nil
        }
        let regular = named(descriptor.family) ?? CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil)
            ?? CTFontCreateWithName(descriptor.family as CFString, pixelSize, nil)
        var emboldened = [false, false, false, false]
        func styled(_ traits: CTFontSymbolicTraits, family: String?) -> CTFont {
            if let family, let font = named(family) {
                return font
            }
            if let font = CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) {
                return font
            }
            // No such face: synthesize from the closest one.
            let bold = traits.contains(.traitBold)
            let boldFace = bold ? CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, .traitBold, .traitBold) : nil
            if bold, boldFace == nil, descriptor.synthesizeBold {
                emboldened[Int(traits.contains(.traitItalic) ? 3 : 1)] = true
            }
            let base = boldFace ?? regular
            guard traits.contains(.traitItalic), descriptor.synthesizeItalic else { return base }
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            return CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(base), pixelSize, &skew)
        }
        fallbacks = descriptor.fallbackFamilies.compactMap { family in
            let font = CTFontCreateWithName(family as CFString, pixelSize, nil)
            return (CTFontCopyFamilyName(font) as String).localizedCaseInsensitiveContains(family) ? font : nil
        }
        let settings = descriptor.features.compactMap { raw -> [CFString: Any]? in
            let off = raw.hasPrefix("-")
            let tag = off ? String(raw.dropFirst()) : raw
            guard tag.utf8.count == 4 else { return nil }
            return [kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: off ? 0 : 1]
        }
        let shapes = descriptor.features.contains { !$0.hasPrefix("-") }
        // Shaped runs resolve missing glyphs through CoreText's cascade, so
        // the fallback families go there too.
        let cascade = shapes ? fallbacks.map { CTFontCopyFontDescriptor($0) } : []
        let variations = descriptor.variations.reduce(into: [NSNumber: Double]()) { out, axis in
            // Axis identifiers are the tag's four bytes as a big-endian integer.
            guard axis.key.utf8.count == 4 else { return }
            out[NSNumber(value: axis.key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })] = axis.value
        }
        func featured(_ font: CTFont) -> CTFont {
            guard !settings.isEmpty || !cascade.isEmpty || !variations.isEmpty else { return font }
            var attributes: [CFString: Any] = [:]
            if !settings.isEmpty {
                attributes[kCTFontFeatureSettingsAttribute] = settings
            }
            if !variations.isEmpty {
                attributes[kCTFontVariationAttribute] = variations
            }
            if !cascade.isEmpty {
                attributes[kCTFontCascadeListAttribute] = cascade
            }
            let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), attributes as CFDictionary)
            var matrix = CTFontGetMatrix(font) // keeps a synthetic italic's slant
            return CTFontCreateWithFontDescriptor(d, CTFontGetSize(font), &matrix)
        }
        faces = [
            regular,
            styled(.traitBold, family: descriptor.boldFamily),
            styled(.traitItalic, family: descriptor.italicFamily),
            styled([.traitBold, .traitItalic], family: descriptor.boldItalicFamily),
        ].map(featured)
        self.emboldened = emboldened
        self.shapes = shapes
        emoji = CTFontCreateWithName("Apple Color Emoji" as CFString, pixelSize, nil)

        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let baseAscent = ceil(CTFontGetAscent(regular))
        descent = ceil(CTFontGetDescent(regular))
        let leading = ceil(CTFontGetLeading(regular))
        cellWidth = max(1, ceil(advance.width * (1 + descriptor.cellWidthAdjust) + descriptor.cellWidthOffset * descriptor.scale))
        let baseHeight = baseAscent + descent + leading
        cellHeight = max(1, ceil(baseHeight * (1 + descriptor.cellHeightAdjust) + descriptor.cellHeightOffset * descriptor.scale))
        // Extra height is split above and below the glyphs.
        ascent = baseAscent + floor((cellHeight - baseHeight) / 2)
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
        for fallback in font.fallbacks {
            if let glyph = Self.glyph(scalar, in: fallback) {
                return GlyphLookup(font: fallback, glyph: glyph, isColor: false)
            }
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
