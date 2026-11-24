import Foundation
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization

/// Client-side kitty graphics pixels for one connection (spec.graphics.md
/// §14.4): frames reference images by key; missing pixels are fetched in
/// `imageChunk` replies and cached, least recently used first out, within
/// a byte budget. Memory only: images are never written to disk.
public final class MuxImageStore: Sendable {
  public typealias Execute = @Sendable (MuxCommand) async throws -> MuxReply

  private struct Entry {
    var pixels: KittyImagePixels
    var lastUse: UInt64
    /// Uptime nanoseconds of the last use.
    var usedAt: UInt64
  }

  /// Entries used this recently are on screen: evicting them would only
  /// have the next frame fetch them again, so the budget yields to them
  /// (it covers every pane of the connection, which can show more).
  private static let inUseNanoseconds: UInt64 = 5_000_000_000

  private struct State {
    var entries: [UInt64: Entry] = [:]
    var bytes = 0
    var tick: UInt64 = 0
    var inFlight: Set<UInt64> = []
    /// Advances on `removeAll`; downloads from before it are dropped.
    var epoch: UInt64 = 0
  }

  private let state = Mutex(State())
  public let budget: Int

  public static var defaultBudget: Int {
    #if os(macOS)
    256 << 20
    #else
    128 << 20
    #endif
  }

  public init(budget: Int = MuxImageStore.defaultBudget) {
    self.budget = budget
  }

  /// Cached pixels matching `image`'s key and shape.
  public func pixels(_ image: FrameImage) -> KittyImagePixels? {
    state.withLock { s in
      guard var entry = s.entries[image.key], Self.matches(entry, image) else {
        return nil
      }
      s.tick &+= 1
      entry.lastUse = s.tick
      entry.usedAt = DispatchTime.now().uptimeNanoseconds
      s.entries[image.key] = entry
      return entry.pixels
    }
  }

  public var residentBytes: Int { state.withLock { $0.bytes } }

  private static func matches(_ entry: Entry, _ image: FrameImage) -> Bool {
    entry.pixels.width == Int(image.width)
      && entry.pixels.height == Int(image.height)
      && entry.pixels.bytesPerPixel == Int(image.bytesPerPixel)
  }

  /// Drops everything (memory warning, disconnect, a new connection
  /// whose keys come from another process).
  public func removeAll() {
    state.withLock { $0 = State(epoch: $0.epoch &+ 1) }
  }

  /// Fetches each image not cached or already in flight, then calls
  /// `loaded` once per image that arrived.
  public func fetch(
    _ images: [FrameImage],
    pane: PaneID,
    execute: @escaping Execute,
    loaded: @escaping @Sendable (UInt64) -> Void
  ) {
    let (wanted, epoch) = state.withLock { s in
      // An entry of another shape is a stale key: fetch over it.
      let wanted = images.filter { image in
        !(s.entries[image.key].map { Self.matches($0, image) } ?? false)
          && s.inFlight.insert(image.key).inserted
      }
      return (wanted, s.epoch)
    }
    for image in wanted {
      Task.detached { [self] in
        let pixels = await Self.download(image, pane: pane, execute: execute)
        let stored = state.withLock { s -> Bool in
          guard s.epoch == epoch else { return false }
          s.inFlight.remove(image.key)
          guard let pixels else { return false }
          s.tick &+= 1
          s.bytes -= s.entries[image.key]?.pixels.bytes.count ?? 0
          s.entries[image.key] = Entry(
            pixels: pixels,
            lastUse: s.tick,
            usedAt: DispatchTime.now().uptimeNanoseconds
          )
          s.bytes += pixels.bytes.count
          evict(&s, keeping: image.key)
          return true
        }
        if stored { loaded(image.key) }
      }
    }
  }

  private func evict(_ s: inout State, keeping key: UInt64) {
    guard s.bytes > budget else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    for (k, e) in s.entries.sorted(by: { $0.value.lastUse < $1.value.lastUse })
    {
      guard s.bytes > budget else { break }
      guard k != key, now &- e.usedAt > Self.inUseNanoseconds else { continue }
      s.entries[k] = nil
      s.bytes -= e.pixels.bytes.count
    }
  }

  /// Placements of `images` with cached pixels; the rest are pending.
  public func placements(_ images: FrameImages) -> [KittyGraphics.Placement] {
    let resolved = images.images.map { pixels($0) }
    return images.placements.compactMap { p in
      guard Int(p.image) < resolved.count, let px = resolved[Int(p.image)]
      else { return nil }
      return KittyGraphics.Placement(
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
        sourceX: Int(p.sourceX),
        sourceY: Int(p.sourceY),
        sourceWidth: Int(p.sourceWidth),
        sourceHeight: Int(p.sourceHeight),
        isPlaceholder: p.placeholder
      )
    }
  }

  private static func download(
    _ image: FrameImage,
    pane: PaneID,
    execute: Execute
  ) async -> KittyImagePixels? {
    let total = image.byteCount
    guard total > 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(total)
    while bytes.count < total {
      guard
        let reply = try? await execute(
          .imageChunk(pane: pane, key: image.key, offset: bytes.count)
        ), case let .imageChunk(chunk) = reply,
        (try? chunk.validate(requestedOffset: bytes.count, key: image.key))
          != nil, chunk.image == image, !chunk.bytes.isEmpty
      else { return nil }
      bytes.append(contentsOf: chunk.bytes)
    }
    return KittyImagePixels(
      receivedWidth: Int(image.width),
      height: Int(image.height),
      bytesPerPixel: Int(image.bytesPerPixel),
      bytes: bytes
    )
  }
}
