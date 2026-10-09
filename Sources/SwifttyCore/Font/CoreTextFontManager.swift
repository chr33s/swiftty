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
    /// OpenType feature settings, e.g. `tag`, `-tag`, `tag=2` (Ghostty's `font-feature`).
    /// Any enabled feature turns on shaping (ligatures, alternates).
    public var features: [String] = []
    /// Families for the other styles (Ghostty's `font-family-bold` etc.);
    /// nil derives the style from `family`.
    public var boldFamily: String?
    public var italicFamily: String?
    public var boldItalicFamily: String?
    /// Variable-font axes by four-letter tag (Ghostty's `font-variation`).
    /// Nonfinite values are ignored.
    public var variations: [String: Double] = [:]
    /// Draw a missing bold face by stroking the regular one, and a missing
    /// italic by slanting it (Ghostty's `font-synthetic-style`).
    public var synthesizeBold = true
    public var synthesizeItalic = true
    /// Bold italic is controlled independently of the single styles.
    public var synthesizeBoldItalic = true

    public init(family: String = "Menlo", size: CGFloat = 13, scale: CGFloat = 2) {
        self.family = family
        self.size = size
        self.scale = scale
    }

    /// CoreText propagates nonfinite dimensions and variation values.
    /// Normalize before creation and cache lookup, including product overflow.
    var normalized: FontDescriptor {
        var result = self
        if !size.isFinite || size <= 0 {
            result.size = 13
        }
        if !scale.isFinite || scale <= 0 {
            result.scale = 2
        }
        let pixels = result.size * result.scale
        if !pixels.isFinite || pixels <= 0 {
            result.size = 13
            result.scale = 2
        }
        if variations.values.contains(where: { !$0.isFinite }) {
            result.variations = variations.filter(\.value.isFinite)
        }
        return result
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
    /// Configured fallback families resolved independently for each style.
    private let fallbackFaces: [[CTFont]]
    private let fallbackEmboldened: [[Bool]]
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
        let descriptor = descriptor.normalized
        self.descriptor = descriptor
        let pixelSize = descriptor.size * descriptor.scale
        func named(_ family: String) -> CTFont? {
            let font = CTFontCreateWithName(family as CFString, pixelSize, nil)
            // CoreText also accepts PostScript and full face names. Check
            // those names to distinguish a match from its default font.
            let names = [CTFontCopyFamilyName(font), CTFontCopyPostScriptName(font), CTFontCopyFullName(font), CTFontCopyDisplayName(font)]
            return names.contains { ($0 as String).caseInsensitiveCompare(family) == .orderedSame } ? font : nil
        }
        let regular = named(descriptor.family) ?? CTFontCreateUIFontForLanguage(.userFixedPitch, pixelSize, nil)
            ?? CTFontCreateWithName(descriptor.family as CFString, pixelSize, nil)
        func styled(_ regular: CTFont, _ traits: CTFontSymbolicTraits, family: String? = nil) -> (CTFont, Bool) {
            if let family, let font = named(family) {
                return (font, false)
            }
            if let font = CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, traits, traits) {
                return (font, false)
            }
            // No such face: synthesize from the closest one.
            let bold = traits.contains(.traitBold)
            let italic = traits.contains(.traitItalic)
            let synthesize = bold && italic ? descriptor.synthesizeBoldItalic
                : bold ? descriptor.synthesizeBold : descriptor.synthesizeItalic
            guard synthesize else { return (regular, false) }
            let boldFace = bold ? CTFontCreateCopyWithSymbolicTraits(regular, pixelSize, nil, .traitBold, .traitBold) : nil
            let embolden = bold && boldFace == nil
            let base = boldFace ?? regular
            guard italic else { return (base, embolden) }
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            return (CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(base), pixelSize, &skew), embolden)
        }
        let fallbackFonts = descriptor.fallbackFamilies.compactMap(named)
        var features: [FontFeature] = []
        var featureIndices: [String: Int] = [:]
        for raw in descriptor.features {
            guard let feature = FontFeature(raw) else { continue }
            if let index = featureIndices[feature.tag] {
                features[index] = feature
            } else {
                featureIndices[feature.tag] = features.count
                features.append(feature)
            }
        }
        let settings: [[CFString: Any]] = features.map {
            [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value]
        }
        let shapes = features.contains { $0.value != 0 }
        let variations = descriptor.variations.reduce(into: [NSNumber: Double]()) { out, axis in
            // Axis identifiers are the tag's four bytes as a big-endian integer.
            guard axis.key.utf8.count == 4 else { return }
            out[NSNumber(value: axis.key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })] = axis.value
        }
        func featured(_ font: CTFont, cascade: [CTFontDescriptor] = []) -> CTFont {
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
        let fallbackStyles = fallbackFonts.map { regular in
            [(regular, false), styled(regular, .traitBold), styled(regular, .traitItalic), styled(regular, [.traitBold, .traitItalic])]
        }
        let styledFallbacks = (0 ..< 4).map { style in fallbackStyles.map { featured($0[style].0) } }
        fallbackFaces = styledFallbacks
        fallbackEmboldened = (0 ..< 4).map { style in fallbackStyles.map { $0[style].1 } }
        fallbacks = fallbackFaces[0]
        let primaryStyles = [
            (regular, false),
            styled(regular, .traitBold, family: descriptor.boldFamily),
            styled(regular, .traitItalic, family: descriptor.italicFamily),
            styled(regular, [.traitBold, .traitItalic], family: descriptor.boldItalicFamily),
        ]
        // Shaped rows and grapheme clusters need the same styled cascade
        // as scalar lookup, including when no features enable row shaping.
        faces = primaryStyles.enumerated().map { style, face in
            featured(face.0, cascade: styledFallbacks[style].map { CTFontCopyFontDescriptor($0) })
        }
        emboldened = primaryStyles.map(\.1)
        self.shapes = shapes
        emoji = CTFontCreateWithName("Apple Color Emoji" as CFString, pixelSize, nil)

        // Variations can change advances and vertical metrics. Measure the
        // configured face that will actually be used to render regular text.
        let metrics = faces[0]
        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(metrics, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(metrics, .horizontal, &glyph, &advance, 1)
        let baseAscent = ceil(CTFontGetAscent(metrics))
        descent = ceil(CTFontGetDescent(metrics))
        let leading = ceil(CTFontGetLeading(metrics))
        func adjusted(_ base: CGFloat, fraction: CGFloat, offset: CGFloat) -> CGFloat {
            let fraction = fraction.isFinite ? fraction : 0
            let offset = offset.isFinite ? offset : 0
            let result = ceil(base * (1 + fraction) + offset * descriptor.scale)
            if result.isNaN {
                return max(1, ceil(base))
            }
            return max(1, min(result, .greatestFiniteMagnitude))
        }
        cellWidth = adjusted(advance.width, fraction: descriptor.cellWidthAdjust, offset: descriptor.cellWidthOffset)
        let baseHeight = min(.greatestFiniteMagnitude, baseAscent + descent + leading)
        cellHeight = adjusted(baseHeight, fraction: descriptor.cellHeightAdjust, offset: descriptor.cellHeightOffset)
        // Extra height is split above and below the glyphs.
        ascent = min(.greatestFiniteMagnitude, baseAscent + floor((cellHeight - baseHeight) / 2))
        let underline = ascent - CTFontGetUnderlinePosition(metrics)
        underlinePosition = min(.greatestFiniteMagnitude, max(-.greatestFiniteMagnitude, underline))
        underlineThickness = max(1, round(CTFontGetUnderlineThickness(metrics)))
    }

    public func face(_ style: FontStyle) -> CTFont {
        faces[Int(style.rawValue & 3)]
    }

    func fallbackFaces(_ style: FontStyle) -> [CTFont] {
        fallbackFaces[Int(style.rawValue & 3)]
    }

    /// Synthetic weight belongs to the font drawing a glyph, rather than
    /// the primary face that happened to request its fallback.
    func shouldEmbolden(_ glyphFont: CTFont, style: FontStyle) -> Bool {
        guard !CTFontGetSymbolicTraits(glyphFont).contains(.traitColorGlyphs) else { return false }
        let index = Int(style.rawValue & 3)
        if CFEqual(glyphFont, faces[index]) {
            return emboldened[index]
        }
        for (family, fallback) in fallbackFaces[index].enumerated() where CFEqual(glyphFont, fallback) {
            return fallbackEmboldened[index][family]
        }
        guard style.contains(.bold), !CTFontGetSymbolicTraits(glyphFont).contains(.traitBold) else { return false }
        return style.contains(.italic) ? descriptor.synthesizeBoldItalic : descriptor.synthesizeBold
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
    /// The 16 most recently resolved bundles, oldest first. Zoom and
    /// configuration reloads must not retain every past family and size.
    private var fonts: [ResolvedFont] = []
    private static let fontCacheLimit = 16
    private var lookups: [UInt64: GlyphLookup?] = [:]
    static let glyphCacheLimit = 16384
    var cachedGlyphCount: Int {
        lookups.count
    }

    /// Retain the glyph cache's owner so eviction cannot recycle its identity.
    private var lookupFont: ResolvedFont?

    public init() {}

    /// Invalid sizes and scales use their defaults (13 points and 2).
    /// If their product overflows or underflows to zero, both use defaults.
    /// Nonfinite variation values are ignored, preserving other configured axes.
    public func resolve(_ descriptor: FontDescriptor) -> ResolvedFont {
        let descriptor = descriptor.normalized
        if let index = fonts.lastIndex(where: { $0.descriptor == descriptor }) {
            let font = fonts[index]
            if index != fonts.count - 1 {
                fonts.remove(at: index)
                fonts.append(font)
            }
            return font
        }
        let font = ResolvedFont(descriptor: descriptor)
        if fonts.count == Self.fontCacheLimit {
            fonts.removeFirst()
        }
        fonts.append(font)
        return font
    }

    /// Glyph for `scalar` in the primary (regular) face, without fallback.
    public func glyph(for scalar: Unicode.Scalar, in font: ResolvedFont) -> CGGlyph? {
        Self.glyph(scalar, in: font.faces[0])
    }

    /// Glyph for `scalar` in `style`, falling back to emoji and system
    /// cascade fonts. Results are cached per font in a bounded working set.
    public func lookup(_ scalar: Unicode.Scalar, style: FontStyle, in font: ResolvedFont) -> GlyphLookup? {
        if lookupFont !== font {
            lookups.removeAll(keepingCapacity: true)
            lookupFont = font
        }
        let key = UInt64(scalar.value) | UInt64(style.rawValue) << 32
        if let cached = lookups[key] {
            return cached
        }
        let result = resolveGlyph(scalar, style: style, font: font)
        if lookups.count >= Self.glyphCacheLimit {
            lookups.removeAll(keepingCapacity: true)
        }
        lookups[key] = result
        return result
    }

    private func resolveGlyph(_ scalar: Unicode.Scalar, style: FontStyle, font: ResolvedFont) -> GlyphLookup? {
        let face = font.face(style)
        let emojiPresentation = scalar.properties.isEmojiPresentation
        if !emojiPresentation, let glyph = Self.glyph(scalar, in: face) {
            return GlyphLookup(font: face, glyph: glyph, isColor: CTFontGetSymbolicTraits(face).contains(.traitColorGlyphs))
        }
        if scalar.properties.isEmoji, let glyph = Self.glyph(scalar, in: font.emoji) {
            return GlyphLookup(font: font.emoji, glyph: glyph, isColor: true)
        }
        for fallback in font.fallbackFaces(style) {
            if let glyph = Self.glyph(scalar, in: fallback) {
                return GlyphLookup(font: fallback, glyph: glyph, isColor: CTFontGetSymbolicTraits(fallback).contains(.traitColorGlyphs))
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
        // Every scalar occupies at most two UTF-16 code units.
        var utf16 = InlineArray<2, UniChar>(repeating: 0)
        let value = scalar.value
        let count: Int
        if value < 0x10000 {
            utf16[0] = UniChar(value)
            count = 1
        } else {
            let supplementary = value - 0x10000
            utf16[0] = 0xD800 | UniChar(supplementary >> 10)
            utf16[1] = 0xDC00 | UniChar(supplementary & 0x3FF)
            count = 2
        }
        var glyphs = InlineArray<2, CGGlyph>(repeating: 0)
        return utf16.span.withUnsafeBufferPointer { characters in
            var span = glyphs.mutableSpan
            return span.withUnsafeMutableBufferPointer { output in
                guard CTFontGetGlyphsForCharacters(font, characters.baseAddress!, output.baseAddress!, count),
                      output[0] != 0 else { return nil }
                return output[0]
            }
        }
    }
}
