import Foundation
@testable import RoamingKit
import ScreenProtocol
import SwiftMuxProtocol
import SwifttyEngine
import Testing

/// The roaming client's image cache (spec.graphics.md §16.4): digests,
/// aliases, reduced variants scaling source rects, boxes while off, and
/// the byte budget.
struct RoamingImageCacheTests {
  private func section(
    key: UInt64,
    width: UInt32 = 16,
    height: UInt32 = 16
  ) -> FrameImages {
    FrameImages(
      cellWidth: 8,
      cellHeight: 16,
      images: [
        FrameImage(key: key, width: width, height: height, bytesPerPixel: 4)
      ],
      placements: [
        FramePlacement(
          image: 0,
          layer: 2,
          z: 0,
          placeholder: false,
          row: 0,
          column: 0,
          columns: 2,
          rows: 1,
          offsetX: 0,
          offsetY: 0,
          width: 16,
          height: 16,
          sourceX: 8,
          sourceY: 0,
          sourceWidth: 8,
          sourceHeight: 16
        )
      ]
    )
  }

  private func blob(
    key: UInt64,
    side: UInt32,
    source: UInt32 = 16,
    digest: UInt8 = 1
  ) -> ImageBlob {
    ImageBlob(
      key: key,
      digest: [UInt8](repeating: digest, count: 32),
      sourceWidth: source,
      sourceHeight: source,
      width: side,
      height: side,
      variant: side < source ? .reduced : .full,
      codec: .png,
      data: []
    )
  }

  @Test
  func `pixels resolve by key and digest and aliases reuse them`() {
    let cache = RoamingImageCache()
    #expect(cache.missing(section(key: 1)) == [1])
    #expect(
      cache.insert(
        blob(key: 1, side: 16),
        rgba: [UInt8](repeating: 9, count: 16 * 16 * 4)
      )
    )
    #expect(cache.missing(section(key: 1)).isEmpty)
    #expect(cache.placements(section(key: 1)).first?.sourceX == 8)
    let digest = blob(key: 1, side: 16).digestHex
    #expect(cache.inventory == [digest])
    #expect(cache.alias(2, digest: digest))
    #expect(cache.placements(section(key: 2)).count == 1)
    #expect(!cache.alias(3, digest: String(repeating: "f", count: 64)))
  }

  @Test
  func `reduced pixels scale source rects`() {
    let cache = RoamingImageCache()
    _ = cache.insert(
      blob(key: 1, side: 8),
      rgba: [UInt8](repeating: 9, count: 8 * 8 * 4)
    )
    let p = cache.placements(section(key: 1)).first
    #expect(p?.sourceX == 4)
    #expect(p?.sourceWidth == 4)
    #expect(p?.sourceHeight == 8)
  }

  @Test
  func `images off draw boxes for placements without pixels`() {
    let cache = RoamingImageCache()
    #expect(cache.placements(section(key: 1)).isEmpty)
    cache.drawsBoxes = true
    let box = cache.placements(section(key: 1))
    #expect(box.count == 1)
    #expect(box.first?.pixels === RoamingImageCache.boxPixels)
    #expect(box.first?.columns == 2)
  }

  /// Network changes switch the variant: only reduced pixels are asked
  /// for again when full is wanted, and a reduced copy never replaces full.
  @Test
  func `only reduced pixels need an upgrade and full is never downgraded`() {
    let cache = RoamingImageCache()
    _ = cache.insert(
      blob(key: 1, side: 8),
      rgba: [UInt8](repeating: 9, count: 8 * 8 * 4)
    )
    #expect(cache.needingUpgrade(section(key: 1), to: .full) == [1])
    #expect(cache.needingUpgrade(section(key: 1), to: .reduced).isEmpty)
    _ = cache.insert(
      blob(key: 1, side: 16),
      rgba: [UInt8](repeating: 9, count: 16 * 16 * 4)
    )
    #expect(cache.needingUpgrade(section(key: 1), to: .full).isEmpty)
    _ = cache.insert(
      blob(key: 1, side: 8),
      rgba: [UInt8](repeating: 9, count: 8 * 8 * 4)
    )
    #expect(cache.needingUpgrade(section(key: 1), to: .full).isEmpty)
    #expect(cache.placements(section(key: 1)).first?.pixels.width == 16)
  }

  /// A new client sharing the cache still offers its pixels after a
  /// reconnect, but forgets the old client's keys (KG28).
  @Test
  func `a shared cache keeps pixels and forgets keys for a new client`() {
    let cache = RoamingImageCache()
    _ = cache.insert(
      blob(key: 1, side: 16),
      rgba: [UInt8](repeating: 9, count: 16 * 16 * 4)
    )
    let digest = blob(key: 1, side: 16).digestHex
    cache.forgetKeys()
    #expect(cache.inventory == [digest])
    #expect(cache.missing(section(key: 1)) == [1])
    #expect(cache.alias(5, digest: digest))
  }

  @Test
  func `the budget evicts least recently used images`() {
    let cache = RoamingImageCache(budget: 16 * 16 * 4 * 2)
    for key in UInt64(1) ... 3 {
      _ = cache.insert(
        blob(key: key, side: 16, digest: UInt8(key)),
        rgba: [UInt8](repeating: 1, count: 1024)
      )
    }
    #expect(cache.residentBytes <= 16 * 16 * 4 * 2)
    #expect(cache.missing(section(key: 1)) == [1])
    #expect(cache.wasDelivered(1))
    cache.trim()
    #expect(cache.residentBytes == 0)
  }
}
