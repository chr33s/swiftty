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
        /// Position relative to the first glyph assigned to this cell.
        var offset: CGPoint
    }

    private struct Key: Hashable {
        var scalars: [UInt32]
        var style: UInt8
    }

    private var cache: [Key: [Glyph]] = [:]
    static let cacheLimit = 4096
    private let memoryLimit: Int
    private(set) var cachedMemoryCost = 0

    init(memoryLimit: Int = 8 * 1024 * 1024) {
        precondition(memoryLimit >= 128)
        self.memoryLimit = memoryLimit
    }

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
        var origins = [CGPoint?](repeating: nil, count: scalars.count)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let range = CFRange(location: 0, length: count)
            let glyphBase = CTRunGetGlyphsPtr(run)
            let indexBase = CTRunGetStringIndicesPtr(run)
            let positionBase = CTRunGetPositionsPtr(run)
            Self.withRunBuffer(glyphBase, count: count) {
                CTRunGetGlyphs(run, range, $0)
            } body: { ids in
                Self.withRunBuffer(indexBase, count: count) {
                    CTRunGetStringIndices(run, range, $0)
                } body: { indices in
                    Self.withRunBuffer(positionBase, count: count) {
                        CTRunGetPositions(run, range, $0)
                    } body: { positions in
                        for k in 0 ..< count where indices[k] >= 0 && indices[k] < cellForUTF16.count && ids[k] != 0 {
                            let cell = cellForUTF16[indices[k]]
                            let origin = origins[cell] ?? positions[k]
                            origins[cell] = origin
                            glyphs.append(Glyph(
                                cell: cell, glyph: ids[k], font: runFont, isColor: isColor,
                                offset: CGPoint(x: positions[k].x - origin.x, y: positions[k].y - origin.y),
                            ))
                        }
                    }
                }
            }
        }
        // Keep all components of a cell together, preserving their drawing
        // order, including when CoreText splits the cell across font runs.
        glyphs.sort { $0.cell < $1.cell }
        // Account for retained array storage as well as dictionary entries.
        // An oversized run still renders, without evicting useful small runs.
        let overhead = 128
        guard scalars.capacity <= (memoryLimit - overhead) / MemoryLayout<UInt32>.stride else {
            return glyphs
        }
        let scalarCost = scalars.capacity * MemoryLayout<UInt32>.stride
        guard glyphs.capacity <= (memoryLimit - overhead - scalarCost) / MemoryLayout<Glyph>.stride else {
            return glyphs
        }
        let cost = overhead + scalarCost + glyphs.capacity * MemoryLayout<Glyph>.stride
        if cache.count >= Self.cacheLimit || cost > memoryLimit - cachedMemoryCost {
            cache.removeAll(keepingCapacity: true)
            cachedMemoryCost = 0
        }
        cache[key] = glyphs
        cachedMemoryCost += cost
        return glyphs
    }

    /// CoreText may expose its storage directly; otherwise copy into scoped scratch.
    @inline(__always)
    private static func withRunBuffer<Element: BitwiseCopyable>(
        _ pointer: UnsafePointer<Element>?, count: Int,
        copy: (UnsafeMutablePointer<Element>) -> Void,
        body: (borrowing Span<Element>) -> Void,
    ) {
        if let pointer {
            body(Span(_unsafeStart: pointer, count: count))
            return
        }
        withTemporaryAllocation(of: Element.self, capacity: count) { output in
            output.withUnsafeMutableBufferPointer { buffer, initializedCount in
                copy(buffer.baseAddress!)
                initializedCount = count
            }
            body(output.span)
        }
    }
}
