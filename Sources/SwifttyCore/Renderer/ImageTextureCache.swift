import Metal
import SwifttyEngine

/// GPU textures for kitty graphics pixels (spec.graphics.md §13.2).
///
/// Keyed by pixel-buffer identity: `KittyImagePixels` is immutable and a
/// content change always produces a new buffer, so a texture is uploaded
/// once per displayed image or animation frame. Entries retain their
/// pixels so an identity cannot be reused while cached. Textures not used
/// by the latest frames are evicted least recently used first once the
/// budget is exceeded.
final class ImageTextureCache {
  private struct Entry {
    let pixels: KittyImagePixels
    let texture: MTLTexture
    var lastUsed: UInt64
  }

  private let device: MTLDevice
  private var entries: [ObjectIdentifier: Entry] = [:]
  private var bytes = 0
  private var frame: UInt64 = 0
  let budget: Int

  static var defaultBudget: Int {
    #if os(macOS)
    256 << 20
    #else
    128 << 20
    #endif
  }

  init(device: MTLDevice, budget: Int = ImageTextureCache.defaultBudget) {
    self.device = device
    self.budget = budget
  }

  var count: Int { entries.count }
  var residentBytes: Int { bytes }

  func beginFrame() { frame &+= 1 }

  /// The texture for `pixels`, uploading it on first use.
  func texture(for pixels: KittyImagePixels) -> MTLTexture? {
    let key = ObjectIdentifier(pixels)
    if var entry = entries[key] {
      entry.lastUsed = frame
      entries[key] = entry
      return entry.texture
    }
    guard pixels.width > 0, pixels.height > 0, pixels.width <= 16384,
      pixels.height <= 16384
    else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: pixels.width,
      height: pixels.height,
      mipmapped: false
    )
    d.usage = .shaderRead
    d.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: d) else { return nil }
    let rgba = pixels.rgba()
    rgba.withUnsafeBytes { raw in
      texture.replace(
        region: MTLRegionMake2D(0, 0, pixels.width, pixels.height),
        mipmapLevel: 0,
        withBytes: raw.baseAddress!,
        bytesPerRow: pixels.width * 4
      )
    }
    entries[key] = Entry(pixels: pixels, texture: texture, lastUsed: frame)
    bytes += pixels.width * pixels.height * 4
    evict()
    return texture
  }

  /// Drops least recently used textures not used this frame until within
  /// budget.
  private func evict() {
    guard bytes > budget else { return }
    let candidates = entries.filter { $0.value.lastUsed != frame }
      .sorted { $0.value.lastUsed < $1.value.lastUsed }
    for (key, entry) in candidates {
      guard bytes > budget else { break }
      entries[key] = nil
      bytes -= entry.pixels.width * entry.pixels.height * 4
      _ = entry
    }
  }

  /// Drops every texture not used by the latest frame (memory warning,
  /// backgrounding, detaching).
  func trim() {
    for (key, entry) in entries where entry.lastUsed != frame {
      entries[key] = nil
      bytes -= entry.pixels.width * entry.pixels.height * 4
    }
  }

  func removeAll() {
    entries = [:]
    bytes = 0
  }
}
