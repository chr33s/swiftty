import CoreText
import Foundation

/// Shapes runs of single-width cells with CoreText so OpenType features
/// (ligatures, contextual alternates, stylistic sets) apply. Glyphs stay on
/// the cell grid: each is drawn at the origin of the first cell it covers,
/// and the other cells of a ligature draw nothing.
final class Shaper {
    struct Glyph {
        var cell: Int // offset within the run
        var glyph: CGGlyph
        var font: CTFont
        var isColor: Bool
    }

    private struct Key: Hashable {
        var scalars: [UInt32]
        var style: UInt8
    }

    private var cache: [Key: [Glyph]] = [:]
    static let cacheLimit = 4096

    /// Shapes `scalars` (one per cell) in `style`.
    func shape(_ scalars: [UInt32], style: FontStyle, font: ResolvedFont) -> [Glyph] {
        let key = Key(scalars: scalars, style: style.rawValue)
        if let hit = cache[key] {
            return hit
        }
        var text = String.UnicodeScalarView()
        var cellForUTF16: [Int] = []
        cellForUTF16.reserveCapacity(scalars.count)
        for (i, v) in scalars.enumerated() {
            let s = Unicode.Scalar(v) ?? " "
            text.append(s)
            for _ in 0 ..< s.utf16.count {
                cellForUTF16.append(i)
            }
        }
        let attributed = NSAttributedString(string: String(text), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font.face(style),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var glyphs: [Glyph] = []
        var taken = Set<Int>()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            var ids = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for k in 0 ..< count where indices[k] < cellForUTF16.count {
                let cell = cellForUTF16[indices[k]]
                // One glyph per cell: the first wins (decompositions are rare).
                guard ids[k] != 0, taken.insert(cell).inserted else { continue }
                glyphs.append(Glyph(cell: cell, glyph: ids[k], font: runFont, isColor: isColor))
            }
        }
        if cache.count >= Self.cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = glyphs
        return glyphs
    }
}
