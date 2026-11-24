import Foundation
import ScreenProtocol
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization

/// Kitty graphics pixels a roaming client holds (spec.graphics.md §16.4):
/// keyed by the host's content digest so images survive attachment epochs
/// and outages, with a per-session key-to-digest map. Memory only, least
/// recently used first out within a byte budget.
public final class RoamingImageCache: Sendable {
  struct Entry {
    var pixels: KittyImagePixels
    var sourceWidth: Int
    var sourceHeight: Int
    var lastUse: UInt64
    /// `full` or `reduced`: a later `reduced` blob never replaces `full`.
    var variant: ImageVariant = .full
  }

  private struct State {
    var entries: [String: Entry] = [:]
    var keys: [UInt64: String] = [:]
    var bytes = 0
    var tick: UInt64 = 0
  }

  private let state = Mutex(State())
  public let budget: Int

  private let boxes = Mutex(false)

  /// Images are off on this client's path: placements without pixels draw
  /// as neutral boxes (spec.graphics.md §16.4).
  public var drawsBoxes: Bool {
    get { boxes.withLock { $0 } }
    set { boxes.withLock { $0 = newValue } }
  }

  /// A translucent grey tile with a lighter frame and a picture glyph (a
  /// sun and a hill), scaled over the image's cells.
  static let boxPixels: KittyImagePixels = {
    let n = 32
    var px = [UInt8](repeating: 0, count: n * n * 4)
    func set(_ x: Int, _ y: Int, _ v: UInt8, _ a: UInt8) {
      let i = (y * n + x) * 4
      (px[i], px[i + 1], px[i + 2], px[i + 3]) = (v, v, v, a)
    }
    for y in 0 ..< n {
      for x in 0 ..< n {
        let edge = x < 1 || y < 1 || x >= n - 1 || y >= n - 1
        set(x, y, edge ? 200 : 128, edge ? 200 : 96)
        let sun = (x - 21) * (x - 21) + (y - 10) * (y - 10) <= 9
        let hill = y >= 16 + abs(x - 12) / 2 && y < 26 && x > 4 && x < 28
        if sun || hill { set(x, y, 220, 200) }
      }
    }
    return KittyImagePixels(
      receivedWidth: n,
      height: n,
      bytesPerPixel: 4,
      bytes: px
    )!
  }()

  public static var defaultBudget: Int {
    #if os(macOS)
    256 << 20
    #else
    128 << 20
    #endif
  }

  public init(budget: Int = RoamingImageCache.defaultBudget) {
    self.budget = budget
  }

  /// Digests to list in `Attach`, most recently used first.
  public var inventory: [String] {
    state.withLock { s in
      s.entries.sorted { $0.value.lastUse > $1.value.lastUse }
        .prefix(ControlMessage.Attach.maxImageInventory).map(\.key)
    }
  }

  public var residentBytes: Int { state.withLock { $0.bytes } }

  /// Stores a decoded blob's pixels.
  public func insert(_ blob: ImageBlob, rgba: [UInt8]) -> Bool {
    guard
      let pixels = KittyImagePixels(
        receivedWidth: Int(blob.width),
        height: Int(blob.height),
        bytesPerPixel: 4,
        bytes: rgba
      )
    else { return false }
    state.withLock { s in
      s.tick &+= 1
      let digest = blob.digestHex
      // Full pixels are kept over a reduced copy of the same image.
      if let old = s.entries[digest], old.variant == .full,
        blob.variant != .full
      {
        s.keys[blob.key] = digest
        s.entries[digest]?.lastUse = s.tick
        return
      }
      if let old = s.entries[digest] { s.bytes -= old.pixels.bytes.count }
      s.entries[digest] = Entry(
        pixels: pixels,
        sourceWidth: Int(blob.sourceWidth),
        sourceHeight: Int(blob.sourceHeight),
        lastUse: s.tick,
        variant: blob.variant == .full ? .full : .reduced
      )
      s.keys[blob.key] = digest
      s.bytes += pixels.bytes.count
      evict(&s, keeping: digest)
    }
    return true
  }

  /// Maps `key` to `digest`; false when the digest is not cached.
  /// Drops the key-to-digest map, keeping pixels (a new client starts).
  public func forgetKeys() { state.withLock { $0.keys.removeAll() } }

  public func alias(_ key: UInt64, digest: String) -> Bool {
    state.withLock { s in
      guard s.entries[digest] != nil else { return false }
      s.keys[key] = digest
      return true
    }
  }

  func entry(_ key: UInt64) -> Entry? {
    state.withLock { s in
      guard let digest = s.keys[key], var entry = s.entries[digest] else {
        return nil
      }
      s.tick &+= 1
      entry.lastUse = s.tick
      s.entries[digest] = entry
      return entry
    }
  }

  /// Whether pixels for `key` arrived at some point this session.
  public func wasDelivered(_ key: UInt64) -> Bool {
    state.withLock { $0.keys[key] != nil }
  }

  /// Keys a frame references whose pixels here are poorer than `variant`:
  /// held `reduced` when `full` is wanted. Missing keys are not listed; the
  /// host sends those.
  public func needingUpgrade(
    _ images: FrameImages?,
    to variant: ImageVariant
  ) -> [UInt64] {
    guard let images, variant == .full else { return [] }
    return state.withLock { s in
      images.images.map(\.key)
        .filter { s.keys[$0].flatMap { s.entries[$0] }?.variant == .reduced }
    }
  }

  /// Keys a frame references that have no pixels here.
  public func missing(_ images: FrameImages?) -> [UInt64] {
    guard let images else { return [] }
    return state.withLock { s in
      images.images.map(\.key)
        .filter { s.keys[$0].flatMap { s.entries[$0] } == nil }
    }
  }

  /// Trims to `bytes` (backgrounding) or empties the cache.
  public func trim(to bytes: Int = 0) {
    state.withLock { s in
      for (digest, e) in s.entries.sorted(by: {
        $0.value.lastUse < $1.value.lastUse
      }) {
        guard s.bytes > bytes else { break }
        s.entries[digest] = nil
        s.bytes -= e.pixels.bytes.count
      }
    }
  }

  private func evict(_ s: inout State, keeping digest: String) {
    guard s.bytes > budget else { return }
    for (d, e) in s.entries.sorted(by: { $0.value.lastUse < $1.value.lastUse })
    {
      guard s.bytes > budget else { break }
      guard d != digest else { continue }
      s.entries[d] = nil
      s.bytes -= e.pixels.bytes.count
    }
  }

  /// Placements a frame's `images` section draws with cached pixels;
  /// pixels received at a smaller variant scale the source rects.
  public func placements(_ images: FrameImages?) -> [KittyGraphics.Placement] {
    guard let images else { return [] }
    var resolved: [(KittyImagePixels, Double, Double)?] = []
    for image in images.images {
      guard let e = entry(image.key), e.sourceWidth == Int(image.width),
        e.sourceHeight == Int(image.height)
      else {
        resolved.append(nil)
        continue
      }
      resolved.append(
        (
          e.pixels, Double(e.pixels.width) / Double(image.width),
          Double(e.pixels.height) / Double(image.height)
        )
      )
    }
    var out: [KittyGraphics.Placement] = []
    let boxes = drawsBoxes
    for p in images.placements {
      guard Int(p.image) < resolved.count else { continue }
      guard let (px, sx, sy) = resolved[Int(p.image)] else {
        // Images off: a neutral box stands in, and a tap loads it.
        if boxes {
          let box = Self.boxPixels
          out.append(
            KittyGraphics.Placement(
              imageID: 0,
              generation: box.serial,
              pixels: box,
              layer: .aboveText,
              z: 0,
              row: Int(p.row),
              column: Int(p.column),
              columns: Int(p.columns),
              rows: Int(p.rows),
              offsetX: Int(p.offsetX),
              offsetY: Int(p.offsetY),
              width: Int(p.width),
              height: Int(p.height),
              sourceX: 0,
              sourceY: 0,
              sourceWidth: box.width,
              sourceHeight: box.height,
              isPlaceholder: false
            )
          )
        }
        continue
      }
      func x(_ v: UInt32) -> Int { Int((Double(v) * sx).rounded()) }
      func y(_ v: UInt32) -> Int { Int((Double(v) * sy).rounded()) }
      let sourceX = min(x(p.sourceX), px.width - 1)
      let sourceY = min(y(p.sourceY), px.height - 1)
      out.append(
        KittyGraphics.Placement(
          imageID: 0,
          generation: px.serial,
          pixels: px,
          layer: KittyGraphics.Layer(rawValue: p.layer) ?? .aboveText,
          z: p.z,
          row: Int(p.row),
          column: Int(p.column),
          columns: Int(p.columns),
          rows: Int(p.rows),
          offsetX: Int(p.offsetX),
          offsetY: Int(p.offsetY),
          width: Int(p.width),
          height: Int(p.height),
          sourceX: sourceX,
          sourceY: sourceY,
          sourceWidth: max(1, min(x(p.sourceWidth), px.width - sourceX)),
          sourceHeight: max(1, min(y(p.sourceHeight), px.height - sourceY)),
          isPlaceholder: p.placeholder
        )
      )
    }
    return out
  }
}
