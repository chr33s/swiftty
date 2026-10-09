@testable import SwifttyCore
import Testing

struct GlyphClusterCacheTests {
    @Test func `hash collisions preserve complete scalar and style keys`() {
        let fixtures: [([UInt32], UInt8)] = [
            ([0x65, 0x301], 0), ([0x65, 0x300], 0), ([0x65, 0x301], 1),
            ([0x65, 0x301, 0x301], 0), ([0x65] + Array(repeating: 0x301, count: 32), 0),
        ]
        var cache = GlyphClusterCache()
        for (index, fixture) in fixtures.enumerated() {
            let values = fixture.0
            let span = values.span
            let entry = GlyphAtlas.Entry(
                position: SIMD2(UInt16(index + 1), 0), size: SIMD2(1, 1), offset: .zero, isColor: false,
            )
            let record = GlyphClusterCache.Record(scalars: span, style: fixture.1, value: entry)
            cache.insert(record, hash: 0)
        }
        for (index, fixture) in fixtures.enumerated() {
            let values = fixture.0
            let span = values.span
            let entry = cache.entry(for: span, style: fixture.1, hash: 0)
            #expect(entry?.position.x == UInt16(index + 1))
        }
        let absent: [UInt32] = [0x65, 0x302]
        let span = absent.span
        let missing = cache.entry(for: span, style: 0, hash: 0)
        #expect(missing == nil)
        cache.removeAll(keepingCapacity: true)
        let cached = fixtures[0].0
        let cachedSpan = cached.span
        let cleared = cache.entry(for: cachedSpan, style: 0, hash: 0)
        #expect(cleared == nil)
    }

    @Test func `cached keys own their scalars independently of their source`() {
        var cache = GlyphClusterCache()
        var source: [UInt32] = [0x65, 0x301]
        do {
            let values = source
            let span = values.span
            let hash = GlyphClusterCache.hash(span, style: 0)
            let entry = GlyphAtlas.Entry(position: SIMD2(7, 9), size: SIMD2(1, 1), offset: .zero, isColor: false)
            cache.insert(GlyphClusterCache.Record(scalars: span, style: 0, value: entry), hash: hash)
        }
        source[1] = 0x300
        let original: [UInt32] = [0x65, 0x301]
        let span = original.span
        let hash = GlyphClusterCache.hash(span, style: 0)
        let entry = cache.entry(for: span, style: 0, hash: hash)
        #expect(entry?.position == SIMD2(7, 9))
        let changed = source
        let changedSpan = changed.span
        let absent = cache.entry(for: changedSpan, style: 0, hash: hash)
        #expect(absent == nil)
    }
}
